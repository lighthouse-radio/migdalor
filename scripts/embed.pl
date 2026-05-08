#!/usr/bin/perl
# Embeds episodes.json directly into index.html between EPISODES_START/END markers.
use strict;
use warnings;
use utf8;
binmode STDOUT, ":utf8";

open my $jf, "<:utf8", "episodes.json" or die "Cannot read episodes.json: $!";
my $json = do { local $/; <$jf> };
close $jf;
$json =~ s/\s+/ /g;
$json =~ s/^\s+|\s+$//g;

open my $hf, "<:utf8", "index.html" or die "Cannot read index.html: $!";
my $html = do { local $/; <$hf> };
close $hf;

my $replacement = "/* EPISODES_START */\nconst EPISODES_DATA = $json;\n/* EPISODES_END */";
my $count = ($html =~ s{/\* EPISODES_START \*/.*?/\* EPISODES_END \*/}{$replacement}s);

die "Markers not found in index.html\n" unless $count;

open my $out, ">:utf8", "index.html" or die "Cannot write index.html: $!";
print $out $html;
close $out;

my @eps = ($json =~ /"id"/g);
print STDERR "Embedded " . scalar(@eps) . " episodes into index.html\n";
