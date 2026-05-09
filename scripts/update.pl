#!/usr/bin/perl
# Incremental updater: fetches new episodes from kzradio.net and appends them to episodes.json
use strict;
use warnings;
use utf8;
binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use JSON::PP;
use Encode qw(decode);

my $base_url  = "https://www.kzradio.net/shows/migdalor";
my $json_file = "episodes.json";
my $ASSUMED_S = 7200;

# Patterns that mark a guest/special episode — skip these
my @exclude_patterns = (
    qr/\x{05D1}\x{05DE}\x{05D2}\x{05D3}\x{05DC}\x{05D5}\x{05E8}/,  # במגדלור
    qr/\x{05D1}\x{05D0}\x{05D5}\x{05DC}\x{05E4}\x{05DF}/,           # באולפן
    qr/presents:/i,
    qr/in the [Ss]tudio/,
    qr/ AKA .+ [Ss]tudio/,
);

# ── Load existing episodes ────────────────────────────────────────────────────
open my $fh, "<:utf8", $json_file or die "Cannot read $json_file: $!";
my $raw = do { local $/; <$fh> };
close $fh;

my $existing_eps = decode_json($raw);
my %known_ids = map { $_->{id} => 1 } @$existing_eps;
print STDERR "Known episodes: " . scalar(keys %known_ids) . "\n";

# ── Scan listing pages for new IDs (stop when we hit only known IDs) ─────────
my @new_urls;
for my $page (1..5) {
    my $url = $page == 1 ? $base_url : "$base_url/page/$page";
    my $html = fetch($url);
    my $found_new = 0;

    while ($html =~ m{href="(https://www\.kzradio\.net/shows/migdalor/(\d+))"}g) {
        my ($ep_url, $id) = ($1, $2);
        next if $known_ids{$id};
        push @new_urls, $ep_url;
        $found_new = 1;
    }

    last unless $found_new;
    select(undef, undef, undef, 0.5);
}

if (!@new_urls) {
    print STDERR "No new episodes found.\n";
    exit 0;
}

print STDERR "New episodes to fetch: " . scalar(@new_urls) . "\n";

# Sort ascending by ID (oldest first within new batch)
@new_urls = sort { ($a =~ /(\d+)$/)[0] <=> ($b =~ /(\d+)$/)[0] } @new_urls;

# ── Fetch each new episode page and its tracklist ─────────────────────────────
my @new_eps;
for my $url (@new_urls) {
    my ($id) = $url =~ /(\d+)$/;
    print STDERR "  Fetching $id...\n";
    my $html = fetch($url);

    if ($html =~ m{loadmp3\('([^']+)',\s*'([^']+)'}) {
        my ($mp3, $title) = ($1, $2);
        $title = decode_html_basic($title);

        my $exclude = 0;
        for my $pat (@exclude_patterns) {
            if ($title =~ $pat) { $exclude = 1; last; }
        }

        if ($exclude) {
            print STDERR "    EXCLUDED: $title\n";
        } else {
            my $date = ($html =~ /(\d{1,2}\.\d{1,2}\.\d{4})/)[0] // "";
            my $tracks = fetch_tracks_from_html($html);
            push @new_eps, {
                id     => $id,
                title  => $title,
                mp3    => $mp3,
                url    => $url,
                date   => $date,
                tracks => $tracks,
            };
        }
    }
    select(undef, undef, undef, 0.4);
}

if (!@new_eps) {
    print STDERR "All new episodes were filtered out.\n";
    exit 0;
}

# ── Merge and save ────────────────────────────────────────────────────────────
my @all = (@$existing_eps, @new_eps);

open my $out, ">", $json_file or die "Cannot write $json_file: $!";
print $out encode_json(\@all);   # encode_json outputs UTF-8 bytes — no :utf8 layer needed
close $out;

print STDERR "Done. Added " . scalar(@new_eps) . " episode(s). Total: " . scalar(@all) . "\n";

# ── Subroutines ───────────────────────────────────────────────────────────────

sub fetch {
    my ($url) = @_;
    my $bytes = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;
    return decode('UTF-8', $bytes, Encode::FB_DEFAULT);
}

sub fetch_tracks_from_html {
    my ($html) = @_;
    my @raw_tracks;
    if ($html =~ m{<div class="playlist">(.*?)</div>}s) {
        my $block = $1;
        while ($block =~ m{<p>([^<]+)</p>}g) {
            my $entry = decode_html_entity($1);
            push @raw_tracks, $entry;
        }
    }
    return [] unless @raw_tracks;

    print STDERR "    Found " . scalar(@raw_tracks) . " tracks\n";

    my @tracks;
    for my $entry (@raw_tracks) {
        my ($artist, $title);
        if ($entry =~ /^(.+?)\s+[\x{2013}\x{2014}-]\s+(.+)$/) {
            $artist = $1;
            $title  = $2;
        } else {
            $artist = "";
            $title  = $entry;
        }
        $title =~ s/\s*\(Remix\)$//i;

        my $ms = itunes_duration($artist, $title);
        push @tracks, { a => $artist, t => $title, ms => $ms };
        select(undef, undef, undef, 0.3);
    }

    estimate_missing(\@tracks, $ASSUMED_S * 1000);
    return \@tracks;
}

sub itunes_duration {
    my ($artist, $title) = @_;

    # Medley: "Part A / Part B / Part C" — look up each component and sum
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
            return int($total_ms * scalar(@parts) / $found);
        }
    }

    return _itunes_lookup($artist, $title);
}

sub _itunes_lookup {
    my ($artist, $title) = @_;
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
    # Retry with title only
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

    # Fallback: Deezer
    my $dz = _deezer_lookup($artist, $title);
    return $dz if $dz > 0;

    # Fallback: MusicBrainz
    return _musicbrainz_lookup($artist, $title);
}

sub _deezer_lookup {
    my ($artist, $title) = @_;
    my $query = "$artist $title";
    $query =~ s/[^\x00-\x7F]//g;
    $query =~ s/[^a-zA-Z0-9 ]/ /g;
    $query =~ s/ +/ /g;
    $query =~ s/^ | $//g;
    return 0 unless length($query) > 2;
    $query =~ s/ /+/g;
    my $url  = "https://api.deezer.com/search?q=$query&limit=5";
    my $resp = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;
    select(undef, undef, undef, 0.3);
    if ($resp =~ /"duration"\s*:\s*(\d+)/) {
        return $1 * 1000 if $1 > 30;
    }
    return 0;
}

sub _musicbrainz_lookup {
    my ($artist, $title) = @_;
    my $query = "$artist $title";
    $query =~ s/[^\x00-\x7F]//g;
    $query =~ s/[^a-zA-Z0-9 ]/ /g;
    $query =~ s/ +/ /g;
    $query =~ s/^ | $//g;
    return 0 unless length($query) > 2;
    $query =~ s/ /+/g;
    my $url = "https://musicbrainz.org/ws/2/recording/?query=$query&fmt=json&limit=5";
    my $resp = `curl -sL --compressed -A "MigdalorRadio/1.0 (https://lighthouse-radio.github.io)" "$url"`;
    select(undef, undef, undef, 1.1);
    if ($resp =~ /"length"\s*:\s*(\d+)/) {
        return $1 if $1 > 30_000;
    }
    return 0;
}

sub estimate_missing {
    my ($tracks, $total_ms) = @_;
    my ($known_ms, $unknown_n) = (0, 0);
    for my $t (@$tracks) {
        $t->{ms} > 0 ? ($known_ms += $t->{ms}) : $unknown_n++;
    }
    return unless $unknown_n > 0;
    my $est = int(($total_ms - $known_ms) / $unknown_n);
    $est = 180_000 if $est < 180_000;
    for my $t (@$tracks) { $t->{ms} = $est unless $t->{ms} > 0 }
}

sub decode_html_entity {
    my ($s) = @_;
    1 while $s =~ s/&amp;/&/g;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&#(\d+);/chr($1)/ge;
    $s =~ s/\s+/ /g;
    $s =~ s/^ | $//g;
    return $s;
}

sub decode_html_basic {
    my ($s) = @_;
    $s =~ s/&#8211;/\x{2013}/g;
    $s =~ s/&#8212;/\x{2014}/g;
    $s =~ s/&amp;/&/g;
    $s =~ s/\x{200B}//g;
    return $s;
}
