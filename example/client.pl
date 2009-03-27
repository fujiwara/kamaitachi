#!/usr/bin/perl

package MyClient;

use strict;
use base qw/ Kamaitachi::Client /;

sub on_invoke_onStatus {
    my $self   = shift;
    my $packet = shift;
    my $args = $packet->args;
    $self->diag("onStatus.code=" . $args->[1]->{code});
    if ( $args->[1]->{code} eq 'NetStream.Publish.Start' ) {
        $self->diag("publish started successfuly.");
        $self->send_packet(
            Kamaitachi::Packet::Function->new(
                number => 3,
                type   => 0x14,
                id     => 5,
                method => "closeStream",
            ),
        );
    }
    else {
        $self->diag("publish started failed. exit");
    }
    $self->stop;
}

sub on_invoke_close {
    my $self = shift;
    $self->stop;
}

sub on_invoke__error {
    my $self = shift;
    $self->stop;
}

package main;

my @packets = (
    Kamaitachi::Packet::Function->new(
        number => 3,
        type   => 0x14,
        id     => 1,
        method => "connect",
        args   => [
            {
                'pageUrl'        => undef,
                'audioCodecs'    => '3191',
                'app'            => undef,
                'videoCodecs'    => '252',
                'tcUrl'          => undef,
                'swfUrl'         => undef,
                'videoFunction'  => '1',
                'flashVer'       => 'WIN 10,0,22,87',
                'fpad'           => 0,
                'capabilities'   => '15',
                'objectEncoding' => '0'
            },
        ],
    ),
    Kamaitachi::Packet::Function->new(
        number => 3,
        type   => 0x14,
        id     => 3,
        method => "createStream",
        args => [],
    ),
    Kamaitachi::Packet::Function->new(
        number => 3,
        type   => 0x14,
        id     => 4,
        obj    => 0x01000000,
        method => "publish",
        args   => [ undef, "test" . time  ],
    ),
);
my $client = MyClient->new({
    url => shift || "rtmp://localhost/stream/live",
    fh  => *STDOUT,
});
$client->run(@packets);
