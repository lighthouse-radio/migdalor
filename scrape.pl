#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(floor);

my $base_url = "https://www.kzradio.net/shows/migdalor";
my @episode_urls;
my %seen_urls;

# Step 1: collect all episode URLs from all listing pages
for my $page (1..19) {
    my $url = $page == 1 ? $base_url : "$base_url/page/$page/";
    print STDERR "Listing page $page/19...\n";

    my $html = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;

    my $count_before = scalar @episode_urls;
    while ($html =~ m{href="(https://www\.kzradio\.net/shows/migdalor/(\d+))"}g) {
        my $ep_url = $1;
        unless ($seen_urls{$ep_url}++) {
            push @episode_urls, $ep_url;
        }
    }
    print STDERR "  Found " . (scalar(@episode_urls) - $count_before) . " new episodes (total: " . scalar(@episode_urls) . ")\n";

    select(undef, undef, undef, 0.5);
}

# Sort by episode ID ascending (oldest first)
@episode_urls = sort { ($a =~ /(\d+)$/)[0] <=> ($b =~ /(\d+)$/)[0] } @episode_urls;

print STDERR "Found " . scalar(@episode_urls) . " unique episodes\n";
print STDERR "Fetching each episode page...\n";

my @results;

for my $i (0..$#episode_urls) {
    my $url = $episode_urls[$i];
    my ($id) = $url =~ /(\d+)$/;
    print STDERR "  [${\($i+1)}/" . scalar(@episode_urls) . "] $id\n";

    my $html = `curl -sL --compressed -A "Mozilla/5.0" "$url"`;

    # Extract loadmp3('mp3_url', 'title', ...)
    if ($html =~ m{loadmp3\('([^']+)',\s*'([^']+)'}) {
        my $mp3 = $1;
        my $title = $2;

        # Extract date (DD.MM.YYYY format from page)
        my $date = "";
        if ($html =~ m{(\d{1,2}\.\d{1,2}\.\d{4})}) {
            $date = $1;
        }

        push @results, { id => $id, title => $title, mp3 => $mp3, url => $url, date => $date };
    } else {
        print STDERR "    WARNING: no loadmp3 found for $url\n";
    }

    select(undef, undef, undef, 0.4);
}

print STDERR "Done. Writing JSON (" . scalar(@results) . " episodes).\n";

# Output JSON
open(my $fh, '>', 'episodes.json') or die "Cannot write episodes.json: $!";
print $fh "[\n";
for my $i (0..$#results) {
    my $ep = $results[$i];
    my $title = json_escape($ep->{title});
    my $mp3   = json_escape($ep->{mp3});
    my $url   = json_escape($ep->{url});
    my $date  = json_escape($ep->{date});
    print $fh "  {\n";
    print $fh "    \"id\": \"$ep->{id}\",\n";
    print $fh "    \"title\": \"$title\",\n";
    print $fh "    \"mp3\": \"$mp3\",\n";
    print $fh "    \"url\": \"$url\",\n";
    print $fh "    \"date\": \"$date\"\n";
    print $fh "  }" . ($i < $#results ? "," : "") . "\n";
}
print $fh "]\n";
close $fh;

print STDERR "episodes.json written.\n";

sub json_escape {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r//g;
    return $s;
}
