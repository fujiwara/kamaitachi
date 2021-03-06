#!/usr/bin/env perl

use strict;
use warnings;

use FindBin::libs;
use lib "$FindBin::Bin/lib";

use Kamaitachi;

my $kamaitachi = Kamaitachi->new;

# setup record output directory
use Service::LiveStreamingRecorder;

use Path::Class qw/dir/;
my $dir = dir($FindBin::Bin, 'streams');
$dir->mkpath unless -d $dir;

$kamaitachi->register_services(
    'rpc/echo'    => 'Service::Echo',
    'rpc/chat'    => 'Service::Chat',
    'stream/live' => 'Service::LiveStreaming',
    'stream/rec'  => Service::LiveStreamingRecorder->new( record_output_dir => $dir ),
);

$kamaitachi->run;

