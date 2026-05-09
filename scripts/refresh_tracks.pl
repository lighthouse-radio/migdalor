#!/usr/bin/perl
# Targeted re-lookup: medleys (titles with "/") and tracks that look estimated.
# Safe to re-run. Updates episodes.json in place.
use strict;
use warnings;
use utf8;
binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use JSON::PP;
use Encode qw(decode);

open my $fh, "<", "episodes.json" or die "Cannot read episodes.json: $!";
my $episodes = decode_json(do { local $/; <$fh> });
close $fh;

my ($updated_tracks, $updated_eps) = (0, 0);

for my $ep (@$episodes) {
    next unless $ep->{tracks} && @{$ep->{tracks}};

    # Detect the episode's fill-in estimate value: most common ms among tracks
    my %freq;
    for my $t (@{$ep->{tracks}}) { $freq{$t->{ms}}++ if $t->{ms} }
    my $fill_ms = (sort { $freq{$b} <=> $freq{$a} } keys %freq)[0] // 0;
    # Only treat as fill-estimate if it appears 3+ times
    $fill_ms = 0 if ($freq{$fill_ms} // 0) < 3;

    my $ep_changed = 0;
    for my $t (@{$ep->{tracks}}) {
        my $is_medley   = ($t->{t} =~ m{/});
        my $is_fill     = ($fill_ms && $t->{ms} == $fill_ms);
        next unless $is_medley || $is_fill;

        my $new_ms = itunes_duration($t->{a} // '', $t->{t});
        if ($new_ms > 0 && $new_ms != $t->{ms}) {
            printf STDERR "  %s – %s: %dms → %dms\n",
                $t->{a}//'?', $t->{t}, $t->{ms}//0, $new_ms;
            $t->{ms} = $new_ms;
            $ep_changed++;
            $updated_tracks++;
        }
        select(undef, undef, undef, 0.3);
    }

    if ($ep_changed) {
        print STDERR "[$ep->{title}] updated $ep_changed track(s)\n";
        $updated_eps++;
        save_json($episodes) if $updated_eps % 5 == 0;
    }
}

save_json($episodes);
print STDERR "Done. Improved $updated_tracks tracks across $updated_eps episodes.\n";

# ── Subroutines ───────────────────────────────────────────────────────────────

sub itunes_duration {
    my ($artist, $title) = @_;

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

    # Artist + title
    my $ms = _query("$artist $title");
    return $ms if $ms > 0;

    # Title only (fallback)
    if ($artist) {
        my $ms = _query($title);
        return $ms if $ms > 0;
    }

    # Deezer (strong on European/international catalogue)
    my $dz = _deezer_lookup($artist, $title);
    return $dz if $dz > 0;

    # MusicBrainz fallback (better for live, world music, non-US artists)
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

sub _query {
    my ($raw) = @_;
    my $q = $raw;
    $q =~ s/[^\x00-\x7F]//g;
    $q =~ s/[^a-zA-Z0-9 ]/ /g;
    $q =~ s/ +/ /g;
    $q =~ s/^ | $//g;
    return 0 unless length($q) > 2;
    $q =~ s/ /+/g;
    my $url = "https://itunes.apple.com/search?term=$q&media=music&entity=song&limit=5&country=US";
    my $resp = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;
    if ($resp =~ /"resultCount"\s*:\s*[1-9]/ && $resp =~ /"trackTimeMillis"\s*:\s*(\d+)/) {
        return $1 if $1 > 30_000;
    }
    return 0;
}

sub save_json {
    my ($data) = @_;
    open my $out, ">:utf8", "episodes.json" or die "Cannot write episodes.json: $!";
    print $out encode_json($data);
    close $out;
}
