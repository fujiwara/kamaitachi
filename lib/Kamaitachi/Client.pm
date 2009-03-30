package Kamaitachi::Client;

use Moose;
with "MooseX::LogDispatch";
use bytes;
use Data::Dumper;
use Data::Hexdumper qw/ hexdump /;
use IO::Handle;
use IO::Socket::INET;
use Socket qw/ SOCK_STREAM /;
use Danga::Socket::Callback;
use Kamaitachi::IOStream;
use Scalar::Util qw/ blessed /;

our $VERSION = "0.2";
our $FH;

has "fh" => (
    is => "rw",
);

has "url" => (
    is  => "rw",
    isa => "Str",
);

has "socket" => (
    is  => "rw",
    isa => "Object",
);

has "app" => (
    is  => "rw",
    isa => "Str",
);

has "callback" => (
    is      => "rw",
    isa     => "HashRef",
    default => sub { +{} },
);

has "parser" => (
    is      => "rw",
    isa     => "Object",
    default => sub {
        Data::AMF->new( version => 0 ),
    },
);

has "io" => (
    is  => "rw",
    isa => "Object",
);

has "server_token" => (
    is  => "rw",
    isa => "Str",
);

has "client_token" => (
    is  => "rw",
    isa => "Str",
);

has "packets" => (
    is  => "rw",
    isa => "ArrayRef",
);

has "packet_names" => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub {[
        undef,
        'packet_chunk_size',    # 0x01
        undef,                  # 0x02
        'packet_bytes_read',    # 0x03
        'packet_ping',          # 0x04
        'packet_server_bw',     # 0x05
        'packet_client_bw',     # 0x06
        undef,                  # 0x07
        'packet_audio',         # 0x08
        'packet_video',         # 0x09
        undef, undef, undef, undef, undef, # 0x0a - 0x0e
        'packet_flex_stream',   # 0x0f
        'packet_flex_shared_object', # 0x10
        'packet_flex_message',       # 0x11
        'packet_notify',             # 0x12
        'packet_shared_object',      # 0x13
        'packet_invoke',             # 0x14
        undef,                       # 0x15
        'packet_flv_data',           # 0x16
    ]},
);

has "timeout" => (
    is      => "rw",
    isa     => "Int",
    default => 10,
);

has "auto" => (
    is      => "rw",
    isa     => "Int",
    default => 1,
);

__PACKAGE__->meta->make_immutable;
no Moose;

sub BUILD {
    my $self = shift;

    $FH = $self->fh;

    my $url  = $self->url;
    my ( $host, $port, $app ) = ( $url =~ m{^(?:rtmp://)?(.+?):?(\d+)?/(.+)} );
    $port ||= 1935;
    $self->logger->info("host: $host\nport: $port\napp: $app");
    $self->app($app);

    my $socket = IO::Socket::INET->new(
        PeerAddr => "$host:$port",
        Type     => SOCK_STREAM,
        Blocking => 0,
    ) or die "Can't create socket. $!";

    IO::Handle::blocking($socket, 0);
    $self->socket($socket);

    $self;
}

sub run {
    my $self    = shift;
    my @packets = @_;

    $self->io( Kamaitachi::IOStream->new( socket => $self->socket ) );
    $self->packets(\@packets);

    Danga::Socket::Callback->new(
        handle         => $self->socket,
        on_write_ready => sub { $self->connect(@_) },
        on_read_ready  => sub {},
    );
    Danga::Socket->SetLoopTimeout( $self->timeout * 1000 );
    Danga::Socket->EventLoop;
}

sub stop {
    Danga::Socket->SetPostLoopCallback( sub { 0 } );
}

sub connect {
    my $self   = shift;
    my $socket = shift;

    $self->logger->debug("on_write_ready");
    my $packet = $self->client_token( pack('C', 0) x 0x600 );
    $socket->watch_write(0);
    $socket->write(
        pack('C', 3) . $self->client_token
    );
    $socket->{on_read_ready} = sub { $self->handshake(@_) };
}

sub handshake {
    my $self   = shift;
    my $socket = shift;

    $self->logger->debug("on_read_ready handshake");
    my $io = $self->io;

    my $length = 0;
    my $bref;
    while ( $bref = $socket->read(8192) ) {
        my $data = $$bref;
        my $l    = bytes::length($data);
        next if $l == 0;
        $self->logger->debug("recieved packet length $l.");
        $length += $l;
        $io->push($data);
        last if $length >= 0x600 + 0x600 + 1; # handshake packet size
    }

    if ( not $self->server_token ) {
        $bref = $io->read(0x600 + 1) or do {
            $self->logger->error("read server token failed.");
            $self->stop;
            return;
        };
        $self->logger->debug("server token recieved.");
        $self->server_token( substr $$bref, 1 );
    }

    if ( $self->server_token ) {
        $bref = $io->read(0x600) or do {
            $self->logger->error("read client token failed.");
            $self->stop;
            return;
        };
        $self->logger->debug("client token recieved.");
        my $token = $$bref;
        if ( $token eq $self->client_token ) {
            $self->logger->debug("client token validate ok.");
        }
        else {
            die "client token mismatch.";
        }
    }
    $self->logger->debug("send handshake packet.");
    $socket->{on_read_ready} = sub { $self->recieve(@_) };
    $socket->write( $self->server_token );

    $self->send_next_packet($socket);
}

sub recieve {
    my $self   = shift;
    my $socket = shift;
    local $Data::Dumper::Indent = 1;

    my $io = $self->io;

    my $bref = $socket->read(8192);
    return unless defined $bref;
    $io->push($$bref);

    while ( my $packet = $io->get_packet ) {
        my $type = $self->packet_names->[ $packet->type ];
        $self->logger->debug("got packet from server. type: '$type'");
        $self->logger->debug( hexdump $packet->data ) if $packet->data;
        if ( $type eq 'packet_invoke' ) {
            $self->handle_packet_invoke($packet);
        }
        else {
            $self->handle_packet($packet, $type);
        }
    }
}

sub handle_packet {
    my $self   = shift;
    my $packet = shift;
    my $type   = shift;
    if ( my $sub = $self->can("on_${type}") ) {
        $self->logger->debug("callback 'on_${type}'");
        eval { $sub->( $self, $packet ) };
        if ($@) {
            $self->logger->error("Error callback on_${type}: $@");
        }
    }
}

sub handle_packet_invoke {
    my $self   = shift;
    my $packet = shift;

    $packet = Kamaitachi::Packet::Function->new_from_packet(
        packet => $packet,
    ) or return;
    $self->logger->debug( Dumper {
        id     => $packet->id,
        method => $packet->method,
        args   => $packet->args,
    });
    my $method = $packet->method;
    if ( my $sub = $self->can("on_invoke_${method}") ) {
        $self->logger->debug("callback 'on_invoke_${method}'");
        eval { $sub->( $self, $packet ) };
        if ($@) {
            $self->logger->error("Error callback on_invoke_{$method}: $@");
        }
    }
    if ($self->auto) {
        $self->send_next_packet();
    }
}

sub send_next_packet {
    my $self    = shift;
    my $packet = shift @{ $self->packets } or return;
    $self->send_packet($packet);
}

sub send_packet {
    my $self   = shift;
    my $packet = shift;

    my $data;
    if ( blessed $packet ) {
        my $type = $self->packet_names->[ $packet->type ];
        if ( $packet->can('method') ) {
            if ( $packet->method eq 'connect' ) {
                $packet->args->[0]->{app}   = $self->app;
                $packet->args->[0]->{tcUrl} = $self->url;
            }
            $self->logger->debug( sprintf("sending packet. type: '$type' method: '%s'",
                         $packet->method ) );
        }
        else {
            $self->logger->debug( "sending packet. type: '$type'" );
        }
        $data = $packet->serialize;
    }
    elsif ( ref $packet eq 'ARRAY' ) {
        $self->logger->debug("sending raw packet (from array).");
        $data = pack "C*", @$packet;
    }
    else {
        $self->logger->debug("sending raw packet.");
        $data = $packet;
    }

    $self->logger->debug( hexdump $data );

    $self->io->write($data);
}

1;
