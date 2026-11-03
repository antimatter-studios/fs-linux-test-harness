#!/usr/bin/env bash
#
# lost-guest-engine.sh -- what the Vagrant engine asks about a lost guest (#105):
# QEMU's monitor, on a real Unix socket answered by a stand-in that talks as the
# monitor does, and the guest, over a stubbed `ssh`. The monitor's text is what
# QEMU 10.2.2 printed on an Apple Silicon host for a machine started by the
# provider; tests/smoke.sh reads a real one.
#
# What is pinned: the socket comes from QEMU's own command line; a monitor that
# is missing, dead or silent answers nothing rather than something, and within a
# limit, because the report runs under a call a consumer is waiting for; and the
# guest is asked on a connection of its own, since the shared one is what was lost.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMPDIR="${FLTH_TEST_SOCKET_ROOT:-/tmp}" new_sandbox

BIN="$SANDBOX/bin"
export STUBDIR="$SANDBOX/stubdir"
mkdir -p "$BIN" "$STUBDIR"
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
cat "$STUBDIR/ps" 2>/dev/null
STUB
printf '#!/bin/sh\nexit 1\n' > "$BIN/pgrep"
# ssh: logs its arguments; hangs when told to; otherwise exits as told.
cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUBDIR/ssh-log"
[ -f "$STUBDIR/ssh-hangs" ] && exec /bin/sleep 30
exit "$(cat "$STUBDIR/ssh-exit" 2>/dev/null || echo 0)"
STUB
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
[ "$1" = ssh-config ] && echo 'Host default'
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# The stand-in monitor: a banner and a prompt, then for each line it redraws the
# line one character at a time as QEMU's readline does, and answers from a file
# named for the command. `silent` accepts the connection and says nothing.
cat > "$SANDBOX/monitor.pl" <<'MONITOR'
use strict;
use warnings;
use IO::Socket::UNIX;
my ($path, $answers, $silent) = @ARGV;
my $server = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $path, Listen => 5) or die "listen: $!";
while (my $client = $server->accept) {
    $client->autoflush(1);
    if ($silent) { sleep 60; next; }
    print {$client} "QEMU 10.2.2 monitor - type 'help' for more information\r\n(qemu) ";
    while (my $line = <$client>) {
        $line =~ s/\r?\n$//;
        for my $n (1 .. length $line) {
            print {$client} substr($line, 0, $n), "\e[K", "\e[D" x $n;
        }
        print {$client} "\r\n";
        (my $file = $line) =~ s/[^a-z]+/-/g;
        if (open my $fh, '<', "$answers/$file") {
            while (<$fh>) { s/\n/\r\n/; print {$client} $_; }
        }
        print {$client} "(qemu) ";
    }
}
MONITOR

make_consumer "$SANDBOX/c" engine-test
export FLTH_CONFIG="$SANDBOX/c/fs-linux-test-harness.toml"
. "$REPO/scripts/lib/common.sh"
flth_load
engine_prepare
ID="$(engine_identity)"

SOCKET="$SANDBOX/mon"
ANSWERS="$SANDBOX/answers"
mkdir -p "$ANSWERS"
MONITOR_PID=""
start_monitor() {
    stop_monitor
    perl "$SANDBOX/monitor.pl" "$SOCKET" "$ANSWERS" "${1:-}" &
    MONITOR_PID=$!
    local tries=0
    until [ -S "$SOCKET" ] || [ "$tries" -ge 100 ]; do /bin/sleep 0.1; tries=$((tries + 1)); done
}
stop_monitor() {
    [ -z "$MONITOR_PID" ] || { kill "$MONITOR_PID" 2>/dev/null; wait "$MONITOR_PID" 2>/dev/null; }
    MONITOR_PID=""
    rm -f "$SOCKET"
}
trap 'stop_monitor; rm -rf "$SANDBOX"' EXIT

qemu_line() {
    printf '/opt/bin/qemu-system-aarch64 -machine virt -drive if=virtio,id=disk0,format=qcow2,file=%s/linked-box.img,snapshot=on,discard=unmap -chardev socket,id=mon0,%s,server=on,wait=off -mon chardev=mon0,mode=readline\n' \
        "$ID" "$1" > "$STUBDIR/ps"
}

# `info block -v`, cut down to what is read. The machine's disk comes first with
# the overlay at the top of its chain, and a declared cache follows it.
block_answer() {
    cat > "$ANSWERS/info-block-v" <<ANSWER
disk0 (#block164): json:{"backing":{"driver":"qcow2"},"driver":"qcow2"} (qcow2)
    Attached to:      /machine/peripheral-anon/device[0]/virtio-backend
    Cache mode:       writeback, ignore flushes
    Backing file:     $ID/linked-box.img (chain depth: 2)
    I/O status:       $1

Images:
image: json:{"driver":"qcow2","file":{"driver":"file","filename":"$SANDBOX/tmp/vl.AXUYX3"}}
file format: qcow2
virtual size: 16 GiB (17179869184 bytes)
disk size: $2
cluster_size: 65536
image: $ID/linked-box.img
file format: qcow2
disk size: 13.7 MiB

flth_cache (#block512): $ID/../cache.img (raw)
    Attached to:      /machine/peripheral-anon/device[1]
    I/O status:       ok

Images:
image: $ID/../cache.img
file format: raw
disk size: 3 GiB

floppy0: [not inserted]
    Removable device: not locked, tray closed
ANSWER
}

# shellcheck disable=SC2034  # read by scripts/lib/engine-vagrant.sh
ENGINE_VAGRANT_MONITOR_LIMIT=5
qemu_line "path=$SOCKET"
start_monitor

echo 'VM status: paused (io-error)' > "$ANSWERS/info-status"
block_answer nospace '7.05 GiB'
got="$(engine_vm_status)"
check_eq "$?" 0 "a monitor that answers is an answer"
check_eq "$got" $'VM status: paused (io-error)\nI/O status: nospace\noverlay: 7.05 GiB' \
    "a guest paused on a full disk: its status, the disk's I/O status, and the overlay's size, not its backing disk's"

echo 'VM status: paused' > "$ANSWERS/info-status"
block_answer ok '9.7 MiB'
check_eq "$(engine_vm_status)" $'VM status: paused\noverlay: 9.7 MiB' "an I/O status of ok is not reported"

echo 'VM status: running' > "$ANSWERS/info-status"
check_eq "$(engine_vm_status)" $'VM status: running\noverlay: 9.7 MiB' "and a running guest is reported as running"

rm -f "$ANSWERS/info-block-v"
check_eq "$(engine_vm_status)" 'VM status: running' "a monitor with no block answer still gives the status"

# --- no answer is no answer -----------------------------------------------

qemu_line 'port=4444,host=localhost,ipv4=on'
got="$(engine_vm_status)"
check_eq "$?" 1 "a monitor with no socket on QEMU's command line is not asked"
check_eq "$got" "" "and no answer is made up"

qemu_line "path=$SOCKET"
: > "$STUBDIR/ps"
engine_vm_status >/dev/null
check_eq "$?" 1 "no QEMU in the process table has no monitor"

qemu_line "path=$SOCKET"
stop_monitor
got="$(engine_vm_status)"
check_eq "$?" 1 "a socket nothing listens on is no answer"
check_eq "$got" "" "and says nothing"

# shellcheck disable=SC2034  # read by scripts/lib/engine-vagrant.sh
ENGINE_VAGRANT_MONITOR_LIMIT=1
start_monitor silent
started="$(date +%s)"
got="$(engine_vm_status)"
rc=$?
took=$(($(date +%s) - started))
check_eq "$rc" 1 "a monitor that never answers is no answer"
check_eq "$got" "" "and says nothing"
check_true_took() { if [ "$took" -le 10 ]; then ok "$1"; else bad "$1 (took ${took}s)"; fi; }
check_true_took "and costs only its limit, because a consumer is waiting on the call"
stop_monitor

# --- the guest -----------------------------------------------------------

: > "$STUBDIR/ssh-log"
echo 0 > "$STUBDIR/ssh-exit"
engine_guest_answers
check_eq "$?" 0 "a guest ssh reaches answers"
check_contains "$(cat "$STUBDIR/ssh-log")" "ControlPath=none" "on a connection of its own: the shared one is what was lost"
echo 255 > "$STUBDIR/ssh-exit"
engine_guest_answers
check_eq "$?" 255 "a guest ssh cannot reach does not"

: > "$STUBDIR/ssh-hangs"
# shellcheck disable=SC2034  # read by scripts/lib/engine-vagrant.sh
ENGINE_VAGRANT_ANSWER_LIMIT=1
started="$(date +%s)"
engine_guest_answers
rc=$?
took=$(($(date +%s) - started))
check_true_status() { if [ "$rc" -ne 0 ]; then ok "$1"; else bad "$1 (status 0)"; fi; }
check_true_status "a guest that hangs the connection does not answer"
check_true_took "and costs only the limit"

check_eq "$(engine_overlay_dir)" "$FLTH_STATE_DIR/tmp" "the overlay lives where QEMU's TMPDIR says"

finish lost-guest-engine
