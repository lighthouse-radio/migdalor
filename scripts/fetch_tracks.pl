#!/usr/bin/perl
# Fetches tracklists from episode pages and looks up durations via iTunes Search API.
# Adds "tracks" array to each episode in episodes.json.
# Safe to re-run: skips episodes that already have tracks.
use strict;
use warnings;
use utf8;
binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use JSON::PP;
use Encode qw(decode);

my $ASSUMED_S = 7200;  # assumed 2h per episode for gap estimation

# ── Load episodes.json ────────────────────────────────────────────────────────
open my $fh, "<", "episodes.json" or die "Cannot read episodes.json: $!";
my $raw = do { local $/; <$fh> };
close $fh;

my $episodes = decode_json($raw);
my $total    = scalar @$episodes;
my $done     = 0;
my $skipped  = 0;

print STDERR "Processing $total episodes...\n";

for my $i (0..$#$episodes) {
    my $ep = $episodes->[$i];

    # Skip if already has tracks
    if ($ep->{tracks} && ref $ep->{tracks} eq 'ARRAY' && @{$ep->{tracks}}) {
        $skipped++;
        next;
    }

    print STDERR "[${\($i+1)}/$total] $ep->{title}\n";

    # Fetch episode page
    my $html = fetch_url($ep->{url});
    unless ($html) {
        print STDERR "  WARN: empty response, skipping\n";
        next;
    }

    # Extract playlist
    my @raw_tracks;
    if ($html =~ m{<div class="playlist">(.*?)</div>}s) {
        my $block = $1;
        while ($block =~ m{<p>([^<]+)</p>}g) {
            push @raw_tracks, decode_html($1);
        }
    }

    unless (@raw_tracks) {
        print STDERR "  WARN: no tracklist found\n";
        $ep->{tracks} = [];
        next;
    }

    print STDERR "  Found " . scalar(@raw_tracks) . " tracks\n";

    # Parse and look up durations
    my @tracks;
    for my $entry (@raw_tracks) {
        my ($artist, $title);

        # Split on first " – " (en dash) or " - " (hyphen)
        if ($entry =~ /^(.+?)\s+[\x{2013}\x{2014}-]\s+(.+)$/) {
            $artist = $1;
            $title  = $2;
        } else {
            $artist = "";
            $title  = $entry;
        }

        # Sanitise title for display (remove junk suffixes)
        $title =~ s/\s*\(Remix\)$//i;

        my $ms = itunes_duration($artist, $title);
        push @tracks, {
            a  => $artist,
            t  => $title,
            ms => $ms,      # may be undef/0
        };

        select(undef, undef, undef, 0.3);  # rate limit
    }

    # Estimate missing durations
    estimate_missing(\@tracks, $ASSUMED_S * 1000);

    $ep->{tracks} = \@tracks;
    $done++;

    # Save after every 10 episodes in case of interruption
    save_json($episodes) if $done % 10 == 0;

    select(undef, undef, undef, 0.2);
}

save_json($episodes);
print STDERR "Done. Processed $done episodes, skipped $skipped already-indexed.\n";

# ── Subroutines ───────────────────────────────────────────────────────────────

sub fetch_url {
    my ($url) = @_;
    my $bytes = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;
    return decode('UTF-8', $bytes, Encode::FB_DEFAULT);
}

sub itunes_duration {
    my ($artist, $title) = @_;

    # Medley: "Part A / Part B / Part C" — look up each component separately and sum
    if ($title =~ m{/}) {
        my @parts = split m{\s*/\s*}, $title;
        my ($total_ms, $found) = (0, 0);
        for my $part (@parts) {
            $part =~ s/^\s+|\s+$//g;
            next unless length($part) > 2;
            my $ms = _itunes_lookup($artist, $part);
            if ($ms > 0) { $total_ms += $ms; $found++; }
            select(undef, undef, undef, 0.2);
        }
        if ($found > 0 && $total_ms > 30_000) {
            # Scale up to account for any parts not found on iTunes
            return int($total_ms * scalar(@parts) / $found);
        }
        # Fall through to whole-title lookup if nothing found
    }

    return _itunes_lookup($artist, $title);
}

sub _itunes_lookup {
    my ($artist, $title) = @_;

    # Build ASCII-only query
    my $query = "$artist $title";
    $query =~ s/[^\x00-\x7F]//g;
    $query =~ s/[^a-zA-Z0-9 ]/ /g;
    $query =~ s/ +/ /g;
    $query =~ s/^ | $//g;
    return 0 unless length($query) > 2;

    $query =~ s/ /+/g;
    my $url = "https://itunes.apple.com/search?term=$query&media=music&entity=song&limit=5&country=US";
    my $resp = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;

    if ($resp =~ /"resultCount"\s*:\s*[1-9]/ && $resp =~ /"trackTimeMillis"\s*:\s*(\d+)/) {
        return $1 if $1 > 30_000;
    }

    # Retry with title only if artist+title failed
    if ($artist) {
        my $q2 = $title;
        $q2 =~ s/[^\x00-\x7F]//g;
        $q2 =~ s/[^a-zA-Z0-9 ]/ /g;
        $q2 =~ s/ +/ /g; $q2 =~ s/^ | $//g;
        if (length($q2) > 2) {
            $q2 =~ s/ /+/g;
            $url = "https://itunes.apple.com/search?term=$q2&media=music&entity=song&limit=5&country=US";
            $resp = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;
            select(undef, undef, undef, 0.2);
            if ($resp =~ /"resultCount"\s*:\s*[1-9]/ && $resp =~ /"trackTimeMillis"\s*:\s*(\d+)/) {
                return $1 if $1 > 30_000;
            }
        }
    }
    return 0;
}

sub estimate_missing {
    my ($tracks, $total_ms) = @_;
    my $known_ms  = 0;
    my $unknown_n = 0;

    for my $t (@$tracks) {
        if ($t->{ms} && $t->{ms} > 0) {
            $known_ms += $t->{ms};
        } else {
            $unknown_n++;
        }
    }

    return unless $unknown_n > 0;

    my $remaining = $total_ms - $known_ms;
    my $est = $unknown_n > 0 ? int($remaining / $unknown_n) : 0;
    $est = 180_000 if $est < 180_000;   # floor: 3 minutes

    for my $t (@$tracks) {
        $t->{ms} = $est unless $t->{ms} && $t->{ms} > 0;
    }
}

sub decode_html {
    my ($s) = @_;
    # decode multiple levels of &amp; encoding
    1 while $s =~ s/&amp;/&/g;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&#(\d+);/chr($1)/ge;
    $s =~ s/\s+/ /g;
    $s =~ s/^ | $//g;
    return $s;
}

sub save_json {
    my ($data) = @_;
    my $out = encode_json($data);
    # encode_json returns bytes; write directly
    open my $fh, ">", "episodes.json" or die "Cannot write episodes.json: $!";
    print $fh $out;
    close $fh;
}
