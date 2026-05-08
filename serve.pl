#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;

my $port = $ARGV[0] || 3000;
my $root = $ARGV[1] || '.';

my %types = (
    html => 'text/html; charset=utf-8',
    js   => 'application/javascript',
    json => 'application/json; charset=utf-8',
    css  => 'text/css',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    ico  => 'image/x-icon',
);

my $server = IO::Socket::INET->new(
    LocalPort => $port,
    Type      => SOCK_STREAM,
    Reuse     => 1,
    Listen    => 5,
) or die "Cannot bind port $port: $!";

print "Serving $root on http://localhost:$port\n";
$| = 1;

while (my $client = $server->accept()) {
    my $request = '';
    while (my $line = <$client>) {
        $request .= $line;
        last if $line eq "\r\n";
    }

    my ($method, $path) = $request =~ /^(\w+)\s+(\S+)/;
    $path = '/' unless $path;
    $path = '/index.html' if $path eq '/';
    $path =~ s/\?.*//;
    $path =~ s/\.\.//g;

    my $file = "$root$path";
    $file =~ s{/}{\\}g if $^O eq 'MSWin32';

    if (-f $file) {
        open my $fh, '<:raw', $file or do {
            print $client "HTTP/1.1 500 Error\r\n\r\n";
            close $client; next;
        };
        my $data = do { local $/; <$fh> };
        close $fh;

        my ($ext) = $file =~ /\.(\w+)$/;
        my $ct = $types{lc($ext || '')} || 'application/octet-stream';
        my $len = length($data);

        print $client "HTTP/1.1 200 OK\r\n";
        print $client "Content-Type: $ct\r\n";
        print $client "Content-Length: $len\r\n";
        print $client "Access-Control-Allow-Origin: *\r\n";
        print $client "\r\n";
        print $client $data;
    } else {
        print $client "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    }

    close $client;
}
