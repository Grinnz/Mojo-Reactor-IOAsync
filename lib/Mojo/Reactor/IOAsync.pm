package Mojo::Reactor::IOAsync;
use Mojo::Base 'Mojo::Reactor';

use IO::Async::Loop;
use IO::Async::Handle;
use IO::Async::Timer::Countdown;
use Mojo::Reactor::Poll;
use Mojo::Util 'md5_sum';
use Scalar::Util 'weaken';

use constant DEBUG => $ENV{MOJO_REACTOR_IOASYNC_DEBUG} || 0;

our $VERSION = '0.001';

my $IOAsync;

sub DESTROY {
	shift->reset;
	undef $IOAsync;
}

sub again {
	my ($self, $id) = @_;
	$self->{timers}{$id}{watcher}->reset;
}

sub io {
	my ($self, $handle, $cb) = @_;
	my $fd = fileno $handle;
	$self->{io}{$fd} = {cb => $cb};
	warn "-- Set IO watcher for $fd\n" if DEBUG;
	return $self->watch($handle, 1, 1);
}

sub is_running { # TODO
}

# We have to fall back to Mojo::Reactor::Poll, since IO::Async::Loop is unique
sub new { $IOAsync++ ? Mojo::Reactor::Poll->new : shift->SUPER::new }

sub one_tick { shift->_loop->loop_once }

sub recurring { shift->_timer(1, @_) }

sub remove {
	my ($self, $remove) = @_;
	return unless defined $remove;
	if (ref $remove) {
		my $fd = fileno $remove;
		if (exists $self->{io}{$fd}) {
			warn "-- Removed IO watcher for $fd\n" if DEBUG;
			if (my $w = delete $self->{io}{$fd}{watcher}) {
				$w->remove_from_parent;
			}
		}
		return !!delete $self->{io}{$fd};
	} else {
		if (exists $self->{timers}{$remove}) {
			warn "-- Removed timer $remove\n" if DEBUG;
			if (my $w = delete $self->{timers}{$remove}{watcher}) {
				$w->remove_from_parent;
			}
		}
		return !!delete $self->{timers}{$remove};
	}
}

sub reset {
	my $self = shift;
	$_->{watcher}->remove_from_parent for
		grep { $_->{watcher} } (values %{$self->{io}}, values %{$self->{timers}});
	delete @{$self}{qw(io loop timers)};
}

sub start { shift->_loop->loop_forever }

sub stop { shift->_loop->loop_stop }

sub timer { shift->_timer(0, @_) }

sub watch {
	my ($self, $handle, $read, $write) = @_;
	
	my $fd = fileno $handle;
	my $io = $self->{io}{$fd};
	if (!$read and !$write) {
		if (my $w = delete $io->{watcher}) { $w->remove_from_parent }
	} elsif (my $w = $io->{watcher}) {
		$w->want_readready($read);
		$w->want_writeready($write);
	} else {
		weaken $self;
		my $w = $io->{watcher} = IO::Async::Handle->new(
			handle => $handle,
			on_read_ready => sub { $self->_sandbox('Read', $io->{cb}, 0) },
			on_write_ready => sub { $self->_sandbox('Write', $io->{cb}, 1) },
		);
		$self->_loop->add($w);
	}
	
	return $self;
}

sub _id {
	my $self = shift;
	my $id;
	do { $id = md5_sum 't' . $self->_loop->time . rand 999 } while $self->{timers}{$id};
	return $id;
}

sub _loop { shift->{loop} ||= IO::Async::Loop->new }

sub _sandbox {
	my ($self, $event, $cb) = (shift, shift, shift);
	eval { $self->$cb(@_); 1 } or $self->emit(error => "$event failed: $@");
}

sub _timer {
	my ($self, $recurring, $after, $cb) = @_;
	
	my $id = $self->_id;
	weaken $self;
	my $w = $self->{timers}{$id}{watcher} = IO::Async::Timer::Countdown->new(
		delay => $after,
		on_expire => sub {
			my $w = shift;
			if ($recurring) {
				$w->start;
			} else {
				$w->remove_from_parent;
				delete $self->{timers}{$id};
			}
			$self->_sandbox("Timer $id", $cb);
		},
	)->start;
	$self->_loop->add($w);
	
	if (DEBUG) {
		my $is_recurring = $recurring ? ' (recurring)' : '';
		warn "-- Set timer $id after $after seconds$is_recurring\n";
	}
	
	return $id;
}

=head1 NAME

Mojo::Reactor::IOAsync - IO::Async backend for Mojo::Reactor

=head1 SYNOPSIS

  use Mojo::Reactor::IOAsync;

  # Watch if handle becomes readable or writable
  my $reactor = Mojo::Reactor::IOAsync->new;
  $reactor->io($handle => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Handle is writable' : 'Handle is readable';
  });

  # Change to watching only if handle becomes writable
  $reactor->watch($handle, 0, 1);

  # Add a timer
  $reactor->timer(15 => sub {
    my $reactor = shift;
    $reactor->remove($handle);
    say 'Timeout!';
  });

  # Start reactor if necessary
  $reactor->start unless $reactor->is_running;

  # Or in an application using Mojo::IOLoop
  BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::IOAsync' }
  use Mojo::IOLoop;

=head1 DESCRIPTION

L<Mojo::Reactor::IOAsync> is an event reactor for L<Mojo::IOLoop> that uses
L<IO::Async>. The usage is exactly the same as other L<Mojo::Reactor> backends
such as L<Mojo::Reactor::Poll>. To set it as the default backend for
L<Mojo::Reactor>, set the C<MOJO_REACTOR> environment variable to
C<Mojo::Reactor::IOAsync>. This must be set before L<Mojo::IOLoop> is loaded.

=head1 EVENTS

L<Mojo::Reactor::IOAsync> inherits all events from L<Mojo::Reactor>.

=head1 METHODS

L<Mojo::Reactor::IOAsync> inherits all methods from L<Mojo::Reactor> and
implements the following new ones.

=head2 again

  $reactor->again($id);

Restart active timer.

=head2 io

  $reactor = $reactor->io($handle => sub {...});

Watch handle for I/O events, invoking the callback whenever handle becomes
readable or writable.

=head2 is_running

  my $bool = $reactor->is_running;

Check if reactor is running.

=head2 new

  my $reactor = Mojo::Reactor::IOAsync->new;

Construct a new L<Mojo::Reactor::IOAsync> object.

=head2 one_tick

  $reactor->one_tick;

Run reactor until an event occurs or no events are being watched anymore. Note
that this method can recurse back into the reactor, so you need to be careful.

=head2 recurring

  my $id = $reactor->recurring(0.25 => sub {...});

Create a new recurring timer, invoking the callback repeatedly after a given
amount of time in seconds.

=head2 remove

  my $bool = $reactor->remove($handle);
  my $bool = $reactor->remove($id);

Remove handle or timer.

=head2 reset

  $reactor->reset;

Remove all handles and timers.

=head2 start

  $reactor->start;

Start watching for I/O and timer events, this will block until L</"stop"> is
called or no events are being watched anymore.

=head2 stop

  $reactor->stop;

Stop watching for I/O and timer events.

=head2 timer

  my $id = $reactor->timer(0.5 => sub {...});

Create a new timer, invoking the callback after a given amount of time in
seconds.

=head2 watch

  $reactor = $reactor->watch($handle, $readable, $writable);

Change I/O events to watch handle for with true and false values. Note that
this method requires an active I/O watcher.

=head1 BUGS

Report any issues on the public bugtracker.

=head1 AUTHOR

Dan Book, C<dbook@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2015, Dan Book.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::IOLoop>, L<IO::Async>

=cut

1;
