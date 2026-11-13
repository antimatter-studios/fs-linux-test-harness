#!/usr/bin/env perl
#
# qmp-server.pl <socket> <slots> [<owner pid>] — a stand-in for QEMU's QMP, for the tests that
# drive the real engine with no QEMU (#222). It answers what engine-vagrant.sh asks:
# the root ports flth_rp1..<slots> and the devices added since, as
# /machine/peripheral's children; a device's parent_bus; chardev-add and -remove;
# device_add and device_del, which removes the device at once, as q35's ACPI unplug
# does in tens of milliseconds. Every command is appended to <socket>.log. It serves
# one connection at a time, and ends with its owner (the stand-in QEMU), or with the
# test (FLTH_TEST_PID), whichever goes first.
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;
use JSON::PP;

my ($path, $slots, $owner) = @ARGV;
unlink $path;
my $server = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 8) or die "qmp-server: $path: $!\n";
# The socket a later server made at the same path is not this one's to remove.
my $inode = (stat $path)[1];
sub leave { unlink $path if ((stat $path)[1] // -1) == $inode; exit 0; }
my $json = JSON::PP->new->canonical;
my (%devices, %chardevs);

sub reply { my ($c, $m) = @_; print {$c} $json->encode($m), "\n"; $c->flush; }

my $select = IO::Select->new($server);
sub alive { my ($pid) = @_; return 1 unless $pid; return kill(0, $pid) ? 1 : 0; }
while (1) {
    leave() unless alive($owner) && alive($ENV{FLTH_TEST_PID});
    next unless $select->can_read(1);
    my $client = $server->accept or next;
    reply($client, { QMP => { version => {}, capabilities => [] } });
    while (defined(my $line = <$client>)) {
        my $m = eval { $json->decode($line) } or last;
        open my $log, ">>", "$path.log"; print {$log} $line; close $log;
        my $cmd = $m->{execute} // "";
        my $a = $m->{arguments} // {};
        if ($cmd eq "qom-list") {
            my @kids = map { { name => "flth_rp$_", type => "child<pcie-root-port>" } } 1 .. $slots;
            push @kids, map { { name => $_, type => "child<vhost-user-fs-pci>" } } sort keys %devices;
            reply($client, { return => \@kids });
        } elsif ($cmd eq "qom-get") {
            my ($id) = $a->{path} =~ m{/([^/]+)$};
            if (exists $devices{$id}) { reply($client, { return => "/machine/peripheral/$devices{$id}/$devices{$id}" }) }
            else { reply($client, { error => { class => "DeviceNotFound", desc => "Device '$id' not found" } }) }
        } elsif ($cmd eq "chardev-add") {
            $chardevs{ $a->{id} } = 1;
            reply($client, { return => {} });
        } elsif ($cmd eq "chardev-remove") {
            delete $chardevs{ $a->{id} };
            reply($client, { return => {} });
        } elsif ($cmd eq "device_add") {
            if (!exists $chardevs{ $a->{chardev} // "" }) {
                reply($client, { error => { class => "GenericError", desc => "chardev not found" } });
            } else {
                $devices{ $a->{id} } = $a->{bus};
                reply($client, { return => {} });
            }
        } elsif ($cmd eq "device_del") {
            if (delete $devices{ $a->{id} }) { reply($client, { return => {} }) }
            else { reply($client, { error => { class => "DeviceNotFound", desc => "Device '$a->{id}' not found" } }) }
        } else {
            reply($client, { return => {} });
        }
    }
    close $client;
}
