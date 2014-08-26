use utf8;

package WTSI::NPG::RabbitMQ::Client;

use AnyEvent::RabbitMQ;
use AnyEvent::Strict;
use Moose;

with 'WTSI::NPG::Loggable';

our @HANDLED_BROKER_METHODS = qw(is_open server_properties verbose);

has 'broker' =>
  (is       => 'rw',
   isa      => 'Maybe[AnyEvent::RabbitMQ]',
   required => 1,
   lazy     => 1,
   default  => sub { return AnyEvent::RabbitMQ->new->load_xml_spec },
   handles  => [@HANDLED_BROKER_METHODS]);

has 'channels' =>
  (is       => 'ro',
   isa      => 'HashRef[AnyEvent::RabbitMQ::Channel]',
   required => 1,
   lazy     => 1,
   default  => sub { return {} },
   init_arg => undef);

has 'fully_asynchronous' =>
  (is       => 'rw',
   isa      => 'Bool',
   required => 1,
   default  => 0);

has 'connect_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

has 'connect_failure_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

has 'disconnect_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

has 'open_channel_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

has 'close_channel_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

has 'publish_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

has 'consume_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

has 'error_handler' =>
  (is       => 'rw',
   isa      => 'CodeRef',
   required => 1,
   lazy     => 1,
   builder  => '_make_default_handler');

=head2 channel

  Arg [1] : An channel name

  Example :    my $c = $client->channel('my_channel');
  Description: Return the named channel. Raise an error if the named channel
               does not exist.
  Returntype : AnyEvent::RabbitMQ::Channel

=cut

sub channel {
  my ($self, $name) = @_;

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");
  exists $self->channels->{$name} or
    $self->logconfess("No channel named '$name' exists");

  return $self->channels->{$name};
}

around 'connect' => sub { _maybe_sync('connect', @_) };

sub connect {
  my ($self, %args) = @_;
  my $host    = $args{host};
  my $port    = $args{port};
  my $vhost   = $args{vhost};
  my $user    = $args{user};
  my $pass    = $args{pass};
  my $timeout = $args{timeout};
  my $tls     = $args{tls};
  my $tune    = $args{tune};
  my $cv      = $args{cond};

  defined $host or $self->logconfess("The host argument was undefined");
  $host or $self->logconfess("The host argument was empty");

  defined $port or $self->logconfess("The port argument was undefined");
  $port or $self->logconfess("The port argument was empty");

  defined $vhost or $self->logconfess("The vhost argument was undefined");
  $vhost or $self->logconfess("The vhost argument was empty");

  defined $user or $self->logconfess("The user argument was undefined");
  $user or $self->logconfess("The user argument was empty");

  defined $pass or $self->logconfess("The pass argument was undefined");

  $tune ||= {};

  unless ($self->fully_asynchronous) {
    _is_condvar($cv) or
      $self->logconfess("The cv argument was not an AnyEvent::CondVar");
  }

  $self->debug("Connecting to $host:$port$vhost as $user");

  $self->broker->connect
    (host       => $host,
     port       => $port,
     vhost      => $vhost,
     user       => $user,
     pass       => $pass,
     timeout    => $timeout,
     tls        => $tls,
     tune       => $tune,
     on_success      => sub { $self->call_connect_handler(@_, $cv) },
     on_failure      => sub { $self->call_connect_failure_handler(@_, $cv) },
     on_read_failure => sub { $self->call_error_handler(@_, $cv) },
     on_return       => sub { $self->call_error_handler(@_, $cv) },
     on_close        => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'disconnect' => sub { _maybe_sync('disconnect', @_) };

sub disconnect {
  my ($self, %args) = @_;
  my $cv = $args{cond};

  $self->broker->close
    (on_success => sub { $self->call_disconnect_handler($cv) },
     on_failure => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'open_channel' => sub { _maybe_sync('open_channel', @_) };

sub open_channel {
  my ($self, %args) = @_;
  my $name = $args{name};
  my $cv   = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");
  exists $self->channels->{$name} and
    $self->logconfess("A channel named '$name' exists already");

  $self->broker->open_channel
    (on_success => sub { $self->call_open_channel_handler(@_, $name, $cv) },
     on_failure => sub { $self->call_error_handler(@_, $cv) },
     on_close   => sub { $self->call_close_channel_handler($name, $cv) });

  return $self;
}

around 'close_channel' => sub { _maybe_sync('close_channel', @_) };

sub close_channel {
  my ($self, %args) = @_;
  my $name = $args{name};
  my $cv   = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");
  exists $self->channels->{$name} or
    $self->logconfess("No channel named '$name' exists");

  $self->channels->{$name}->close
    (on_success => sub { $self->call_close_channel_handler($name, $cv) },
     on_failure => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'declare_exchange' => sub { _maybe_sync('declare_exchange', @_) };

sub declare_exchange {
  my ($self, %args) = @_;
  my $name        = $args{name};
  my $cname       = $args{channel};
  my $type        = $args{type};
  my $durable     = $args{durable};
  my $auto_delete = $args{auto_delete};
  my $cv          = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  $type        ||= 'direct';
  $durable     ||= 0;
  $auto_delete ||= 0;

  my $channel = $self->channel($cname);
  $channel->declare_exchange
    (exchange    => $name,
     type        => $type,
     durable     => $durable,
     auto_delete => $auto_delete,
     on_success  => sub {
       $self->debug("Declared exchange '$name' on channel '$cname'");
       $cv->send;
     },
     on_failure  => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'delete_exchange' => sub { _maybe_sync('delete_exchange', @_) };

sub delete_exchange {
  my ($self, %args) = @_;
  my $name  = $args{name};
  my $cname = $args{channel};
  my $cv    = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  my $channel = $self->channel($cname);
  $channel->delete_exchange
    (exchange   => $name,
     on_success => sub {
       $self->debug("Deleted exchange '$name' on channel '$cname'");
       $cv->send;
     },
     on_failure => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'declare_queue' => sub { _maybe_sync('declare_queue', @_) };

sub declare_queue {
  my ($self, %args) = @_;
  my $name  = $args{name};
  my $cname = $args{channel};
  my $cv    = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  $self->channel($cname)->declare_queue
    (queue      => $name,
     on_success => sub {
       $self->debug("Declared queue '$name' on channel '$cname'");
       $cv->send;
     },
     on_failure => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'delete_queue' => sub { _maybe_sync('delete_queue', @_) };

sub delete_queue {
  my ($self, %args) = @_;
  my $name  = $args{name};
  my $cname = $args{channel};
  my $cv    = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  $self->channel($cname)->delete_queue
    (queue      => $name,
     on_success => sub {
       $self->debug("Deleted queue '$name' on channel '$cname'");
       $cv->send;
     },
     on_failure => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'bind_queue' => sub { _maybe_sync('bind_queue', @_) };

sub bind_queue {
  my ($self, %args) = @_;
  my $name  = $args{name};
  my $route = $args{route};
  my $ename = $args{exchange};
  my $cname = $args{channel};
  my $cv    = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");

  defined $route or $self->logconfess("The route argument was undefined");
  $route or $self->logconfess("The route argument was empty");

  defined $ename or $self->logconfess("The exchange argument was undefined");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  $self->channel($cname)->bind_queue
    (queue       => $name,
     exchange    => $ename,
     routing_key => $route,
     on_success => sub {
       $self->debug("Bound queue '$name' to exchange '$ename' with ",
                    "routing key '$route' on channel '$cname'");
       $cv->send;
     },
     on_failure => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'unbind_queue' => sub { _maybe_sync('unbind_queue', @_) };

sub unbind_queue {
  my ($self, %args) = @_;
  my $name  = $args{name};
  my $route = $args{route};
  my $ename = $args{exchange};
  my $cname = $args{channel};
  my $cv    = $args{cond};

  defined $name or $self->logconfess("The name argument was undefined");
  $name or $self->logconfess("The name argument was empty");

  defined $route or $self->logconfess("The route argument was undefined");
  $route or $self->logconfess("The route argument was empty");

  defined $ename or $self->logconfess("The exchange argument was undefined");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  $self->channel($cname)->unbind_queue
    (queue       => $name,
     exchange    => $ename,
     routing_key => $route,
     on_success => sub {
       $self->debug("Unbound queue '$name' from exchange '$ename' with ",
                    "routing key '$route' on channel '$cname'");
       $cv->send;
     },
     on_failure => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

around 'publish' => sub { _maybe_sync('publish', @_) };

sub publish {
  my ($self, %args) = @_;
  my $route     = $args{route};
  my $ename     = $args{exchange};
  my $cname     = $args{channel};
  my $body      = $args{body};
  my $immediate = $args{immediate};
  my $mandatory = $args{mandatory};
  my $cv        = $args{cond};

  defined $route or $self->logconfess("The route argument was undefined");
  $route or $self->logconfess("The route argument was empty");

  defined $ename or $self->logconfess("The exchange argument was undefined");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  defined $body or $self->logconfess("The body argument was undefined");
  $body or $self->logconfess("The body argument was empty");

  $self->channel($cname)->publish
    (exchange    => $ename,
     routing_key => $route,
     body        => $body,
     immediate   => $immediate,
     mandatory   => $mandatory);
  $self->call_publish_handler($body, $route, $cv);

  return $self;
}

around 'consume' => sub { _maybe_sync('consume', @_) };

sub consume {
  my ($self, %args) = @_;
  my $queue        = $args{queue};
  my $cname        = $args{channel};
  my $no_ack       = $args{no_ack};
  my $consumer_tag = $args{consumer_tag};
  my $cv           = $args{cond};

  defined $queue or $self->logconfess("The queue argument was undefined");
  $queue or $self->logconfess("The queue argument was empty");

  defined $cname or $self->logconfess("The channel argument was undefined");
  $cname or $self->logconfess("The channel argument was empty");

  $no_ack ||= 0;

  $self->channel($cname)->consume
    (queue        => $queue,
     no_ack       => $no_ack,
     consumer_tag => $consumer_tag,
     on_consume   => sub { $self->call_consume_handler(@_, $cname, $cv) },
     on_failure   => sub { $self->call_error_handler(@_, $cv) });

  return $self;
}

sub call_connect_handler {
  my ($self, $broker, $cv) = @_;

  $self->connect_handler->($self);
}

after 'call_connect_handler' => sub {
  my ($self, $broker, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");
  $cv->send;
  $self->debug("Called connect_handler");
};

sub call_connect_failure_handler {
  my ($self, $iohandle, $code, $message, $cv) = @_;

  $self->connect_failure_handler->($self, $iohandle, $code, $message);
}

after 'call_connect_failure_handler' => sub {
  my ($self, $iohandle, $code, $message, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");
  $cv->send;
  $self->debug("Called connect_failure_handler");
};

sub call_disconnect_handler {
  my ($self, $cv) = @_;

  $self->disconnect_handler->($self);
}

after 'call_disconnect_handler' => sub {
  my ($self, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");
  $self->broker(undef);
  $cv->send;
  $self->debug("Called disconnect_handler");
};

sub call_open_channel_handler {
  my ($self, $channel, $channel_name, $cv) = @_;

  $self->open_channel_handler->($self, $channel, $channel_name);
}

after 'call_open_channel_handler' => sub {
  my ($self, $channel, $channel_name, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");
  $self->channels->{$channel_name} = $channel;
  $cv->send;
  $self->debug("Called open_channel for '$channel_name'");
};

sub call_close_channel_handler {
  my ($self, $channel, $channel_name, $cv) = @_;

  $self->close_channel_handler->($self, $channel_name);
}

after 'call_close_channel_handler' => sub {
  my ($self, $channel_name, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");
  $cv->send;
  $self->debug("Handled close_channel for '$channel_name'");
};

sub call_publish_handler {
  my ($self, $message, $route, $cv) = @_;

  $self->publish_handler->($self, $message, $route);
}

after 'call_publish_handler' => sub {
  my ($self, $message, $route, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");
  $cv->send;
  $self->debug("Called publish_handler '$message' to '$route'");
};

sub call_consume_handler {
  my ($self, $response, $channel_name, $cv) = @_;

  my $payload = $response->{body}->to_raw_payload;
  $self->consume_handler->($payload);
}

after 'call_consume_handler' => sub {
  my ($self, $response, $channel_name, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");
  my $dtag = $response->{deliver}->method_frame->delivery_tag;
  $self->channel($channel_name)->ack(delivery_tag => $dtag);

  my $payload = $response->{body}->to_raw_payload;
  $self->debug("Received payload '$payload'");

  $cv->send;
  $self->debug("Called consume_handler from '$channel_name'");
};

sub call_error_handler {
  my ($self, $response, $cv) = @_;

  $self->error_handler->($response);
}

after 'call_error_handler' => sub {
  my ($self, $response, $cv) = @_;

  defined $cv or $self->logconfess("The cv argument was not defined");

  if (ref $response) {
    my $method_frame = $response->method_frame;
    $self->error($method_frame->reply_code, ": ", $method_frame->reply_text);
  }
  else {
    $self->error($response);
  }

  $cv->send;
  $self->debug("Called error_handler");
};

sub _make_default_handler {
  my ($self, @args) = @_;

  return sub { return 1 };
}

sub _is_condvar {
  my ($arg) = @_;

  return defined $arg && ref $arg && (ref $arg eq 'AnyEvent::CondVar');
}

sub _maybe_sync {
  my ($name, $orig, $self, %args) = @_;

  $self->debug("Calling wrapped method for $name");

  # If this flag is on, the API user has assumed responsibility for
  # wiring up all the callbacks before any methods have been
  # called. The flag indicates that we are fully event-driven.
  if ($self->fully_asynchronous) {
    $self->$orig(%args);
  }
  else {
    if (!defined $args{cond}) {
      $self->debug("Creating a new AnyEvent::CondVar for $name");
      $args{cond} = AnyEvent->condvar;
    }

    $self->$orig(%args);

    $args{cond}->recv;
  }

  return $self;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;
