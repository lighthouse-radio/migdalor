#!/usr/bin/perl
use strict;
use warnings;
use utf8;
binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my @exclude_fragments = (
    "Michel Sellam",
    "Digital_Me presents",
    "\x{05D2}\x{05D9}\x{05D0} \x{05E8}\x{05D5}\x{05D3}\x{05D5}\x{05D1}\x{05D9}\x{05E5}",  # גיא רודוביץ
    "\x{05D1}\x{05E0}\x{05D9}\x{05DE}\x{05D9}\x{05DF} \x{05D0}\x{05E1}\x{05EA}\x{05E8}\x{05DC}\x{05D9}\x{05E1}",  # בנימין אסתרליס
    "\x{05E0}\x{05E2}\x{05DE}\x{05DF} \x{05E9}\x{05D3}\x{05DE}\x{05D9}",  # נעמן שדמי
    "\x{05D0}\x{05D9}\x{05D9}\x{05DC} \x{05EA}\x{05DC}\x{05DE}\x{05D5}\x{05D3}\x{05D9}",  # אייל תלמודי
);

open my $in, "<:utf8", "episodes.json" or die "Cannot open episodes.json: $!";
my $content = do { local $/; <$in> };
close $in;

# Decode common HTML entities in titles
sub decode_html {
    my ($s) = @_;
    $s =~ s/&#8211;/\x{2013}/g;   # en-dash
    $s =~ s/&#8212;/\x{2014}/g;   # em-dash
    $s =~ s/&#8216;/\x{2018}/g;   # left single quote
    $s =~ s/&#8217;/\x{2019}/g;   # right single quote
    $s =~ s/&#8220;/\x{201C}/g;   # left double quote
    $s =~ s/&#8221;/\x{201D}/g;   # right double quote
    $s =~ s/&amp;/&/g;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    # Remove zero-width spaces
    $s =~ s/\x{200B}//g;
    return $s;
}

# Parse episode blocks: each {...} block
my @episodes;
while ($content =~ /\{([^}]+)\}/gs) {
    my $block = $1;
    my %ep;
    while ($block =~ /"(\w+)":\s*"((?:[^"\\]|\\.)*)"/g) {
        $ep{$1} = $2;
    }
    next unless $ep{title} && $ep{mp3};

    # Decode HTML entities
    $ep{title} = decode_html($ep{title});

    # Check if should be excluded
    my $exclude = 0;
    for my $frag (@exclude_fragments) {
        if (index($ep{title}, $frag) >= 0) {
            $exclude = 1;
            last;
        }
    }

    if ($exclude) {
        print STDERR "EXCLUDED: $ep{title}\n";
    } else {
        push @episodes, \%ep;
    }
}

print STDERR "\nKept: " . scalar(@episodes) . " episodes\n";

# Write filtered JSON
open my $out, ">:utf8", "episodes.json" or die "Cannot write episodes.json: $!";
print $out "[\n";
for my $i (0..$#episodes) {
    my $ep = $episodes[$i];
    my $title = json_escape($ep->{title});
    my $mp3   = json_escape($ep->{mp3});
    my $url   = json_escape($ep->{url});
    my $date  = json_escape($ep->{date} // "");
    print $out "  {\n";
    print $out "    \"id\": \"$ep->{id}\",\n";
    print $out "    \"title\": \"$title\",\n";
    print $out "    \"mp3\": \"$mp3\",\n";
    print $out "    \"url\": \"$url\",\n";
    print $out "    \"date\": \"$date\"\n";
    print $out "  }" . ($i < $#episodes ? "," : "") . "\n";
}
print $out "]\n";
close $out;

print STDERR "episodes.json updated.\n";

sub json_escape {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r//g;
    return $s;
}
