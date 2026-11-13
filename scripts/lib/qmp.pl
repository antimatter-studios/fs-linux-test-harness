#!/usr/bin/env perl
#
# lib/qmp.pl — send QMP commands to the shared guest's QEMU and print their answers.
#
#   qmp.pl <socket> <command json>...
#
# Each command's `return` is printed on a line of its own, as JSON. A command QEMU
# answers with an error stops the run: its class and description go to stderr and
# the status is 1. Status 2 means the socket could not be reached or the answer
# could not be read. Events QEMU sends between answers are not answers, and are
# skipped.
#
# Perl, because the harness already needs it on every host (vm.sh starts the boot
# and the watchdog through it), and JSON::PP and IO::Socket::UNIX are core modules.
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP;

my ($path, @commands) = @ARGV;
die "usage: qmp.pl <socket> <command json>...\n" unless defined $path;

my $json = JSON::PP->new->canonical;
my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path);
unless ($socket) {
    print STDERR "qmp: cannot connect to $path: $!\n";
    exit 2;
}
local $SIG{ALRM} = sub { print STDERR "qmp: no answer from $path in 30s\n"; exit 2; };
alarm 30;

sub answer {
    while (defined(my $line = <$socket>)) {
        my $message = eval { $json->decode($line) };
        unless ($message) {
            print STDERR "qmp: unreadable answer: $line";
            exit 2;
        }
        next if exists $message->{event};
        return $message;
    }
    print STDERR "qmp: $path closed the connection\n";
    exit 2;
}

sub execute {
    my ($command) = @_;
    print {$socket} $command, "\n";
    $socket->flush;
    my $message = answer();
    if (exists $message->{error}) {
        print STDERR "qmp: $message->{error}{class}: $message->{error}{desc}\n";
        exit 1;
    }
    return $message->{return};
}

answer();                                    # the greeting
execute('{"execute":"qmp_capabilities"}');
for my $command (@commands) {
    my $result = execute($command);
    print $json->allow_nonref->encode($result), "\n";
}
exit 0;
