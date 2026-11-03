# qemu-monitor.pl SOCKET COMMAND... -- ask a running QEMU's monitor, for
# tests/smoke.sh, which must not take the harness's word for what QEMU says.
# Prints what the monitor answers, escape sequences and all. Exits 1 when it
# cannot be reached or does not answer within the limit.
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;

my ($path, @commands) = @ARGV;
local $SIG{ALRM} = sub { exit 1 };
alarm 30;
my $monitor = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path) or exit 1;
$monitor->autoflush(1);
my $ready = IO::Select->new($monitor);

# Everything up to the next prompt. A prompt only ends an answer at the very end
# of what has arrived: the monitor echoes each typed character by redrawing it.
sub answer {
    my $text = '';
    until ($text =~ /\(qemu\) $/) {
        $ready->can_read(1) or next;
        sysread($monitor, my $chunk, 65536) or exit 1;
        $text .= $chunk;
    }
    return $text;
}

answer();
foreach my $command (@commands) {
    print {$monitor} "$command\n";
    print answer();
}
