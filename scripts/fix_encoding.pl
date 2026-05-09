#!/usr/bin/perl
# One-shot repair: reverses up to 4 levels of UTF-8-as-Latin-1 double-encoding.
# Root cause: save_json used ">:utf8" while encode_json already outputs UTF-8 bytes.
# Each run of refresh_tracks.pl added another level (3 runs = 3 levels).
use strict;
use warnings;
use utf8;
binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use JSON::PP;
use Encode;

open my $fh, "<", "episodes.json" or die "Cannot read episodes.json: $!";
my $eps = decode_json(do { local $/; <$fh> });
close $fh;

# Reverse one level of double-encoding:
#   chars that were UTF-8 bytes misread as Latin-1 → encode back to Latin-1 bytes
#   → decode those bytes as UTF-8 → one step closer to original
# Repeat until the string can no longer be round-tripped through Latin-1 as valid UTF-8.
sub fix_str {
    my ($s) = @_;
    return $s unless defined $s && $s ne '';
    for (1..4) {
        my $bytes   = eval { Encode::encode('Latin-1', $s, Encode::FB_CROAK) };
        return $s if $@;          # contains chars > U+00FF — already unicode, done
        my $decoded = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
        return $s if $@;          # bytes not valid UTF-8 — at original level, done
        return $s if $decoded eq $s;   # no change — stable, done
        $s = $decoded;
    }
    return $s;
}

my $fixed = 0;
for my $ep (@$eps) {
    if (defined $ep->{title}) {
        my $f = fix_str($ep->{title});
        if ($f ne $ep->{title}) {
            printf STDERR "title: %s → %s\n", $ep->{title}, $f;
            $ep->{title} = $f; $fixed++;
        }
    }
    for my $t (@{$ep->{tracks} // []}) {
        for my $field ('t', 'a') {
            my $v = $t->{$field} // ''; next unless $v ne '';
            my $f = fix_str($v);
            if ($f ne $v) {
                printf STDERR "  [%s] %s → %s\n", $field, $v, $f;
                $t->{$field} = $f; $fixed++;
            }
        }
    }
}

# Save WITHOUT :utf8 layer — encode_json outputs UTF-8 bytes already
open my $out, ">", "episodes.json" or die "Cannot write episodes.json: $!";
print $out encode_json($eps);
close $out;

print STDERR "Done. Fixed $fixed strings.\n";
