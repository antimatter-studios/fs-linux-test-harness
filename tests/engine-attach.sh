#!/usr/bin/env bash
#
# engine-attach.sh — the Vagrant engine attaches a run's tree to the running guest
# and detaches it (#222), against a stand-in QMP (tests/stubs/qmp-server.pl) that
# keeps the devices it is given, and a stand-in virtiofsd that holds its socket.
#
# What is pinned is what QEMU and the daemon are told, and in which order: the
# daemon's flags, a free root port for each tree and the same port again once it is
# free, the device removed before its chardev and before its daemon is stopped, a
# dead daemon reported as such, slots that run out refused by name, and on macOS the
# slot powered off by the guest, with device_del only for a guest that did not.
# tests/smoke.sh holds a real guest to it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Short on purpose: the QMP and virtiofsd sockets are under FLTH_STATE_DIR.
TMPDIR="${FLTH_TEST_SOCKET_ROOT:-/tmp}" new_sandbox

BIN="$SANDBOX/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\ncase "$1" in -s) echo "${FLTH_TEST_UNAME:-Linux}" ;; -m) echo x86_64 ;; esac\n' > "$BIN/uname"
chmod +x "$BIN/uname"
export PATH="$BIN:$PATH"

make_consumer "$SANDBOX/c" engine-attach
export FLTH_CONFIG="$SANDBOX/c/fs-linux-test-harness.toml" FLTH_SHARED_SLOTS=3
. "$REPO/scripts/lib/common.sh"
flth_load
engine_prepare
QMP_LOG="$FLTH_VM_QMP.log"
RUNS="$SANDBOX/guest-runs"

# The guest is up while $SANDBOX/alive exists, and what is asked of it is logged.
: > "$SANDBOX/alive"
engine_alive() { [ -f "$SANDBOX/alive" ]; }
engine_run() { printf '%s\n' "$1" >> "$RUNS"; }

"$FLTH_TEST_QMP_START" ""
check_eq "$([ -S "$FLTH_VM_QMP" ] && echo up)" up "the stand-in QMP listens where the engine looks"

mkdir -p "$SANDBOX/tree-one" "$SANDBOX/tree-two" "$SANDBOX/tree-three" "$SANDBOX/tree-four"
pid_of() { sed -n 's/^pid //p' "$FLTH_MACHINE_DIR/attached/$1" 2>/dev/null; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
attached() { local rc=0; engine_tree_attached "$1" || rc=$?; echo "$rc"; }
qmp_lines() { grep -c "$1" "$QMP_LOG" 2>/dev/null | tr -d ' '; }

# --- attach ----------------------------------------------------------------------

engine_attach_tree run-one "$SANDBOX/tree-one" 2>"$SANDBOX/err"
check_eq "$?" 0 "a tree is attached ($(cat "$SANDBOX/err"))"
check_eq "$(attached run-one)" 0 "and is on record with its daemon alive"
check_eq "$(engine_tree_slot run-one)" 1 "on the first free slot"
check_contains "$(cat "$QMP_LOG")" '"execute":"chardev-add","arguments":{"id":"c-run-one","backend":{"type":"socket","data":{"addr":{"type":"unix","data":{"path":"'"$(engine_vagrant_vfs_socket run-one)"'"}},"server":false}}}' \
    "QEMU connects a chardev to the run's own daemon socket"
check_contains "$(cat "$QMP_LOG")" '"driver":"vhost-user-fs-pci","id":"fs-run-one","chardev":"c-run-one","tag":"run-one","bus":"flth_rp1"' \
    "and adds the device on that slot's root port, tagged with the run id"
vfs_args="$(cat "$(engine_vagrant_vfs_socket run-one).args")"
check_contains "$vfs_args" "--shared-dir=$SANDBOX/tree-one" "the daemon serves the run's tree"
check_contains "$vfs_args" "--sandbox=none" "with no sandbox, as the host user"
check_contains "$vfs_args" "--inode-file-handles=never" "no file handles"
check_contains "$vfs_args" "--xattr" "and extended attributes"
check_lacks "$vfs_args" "--thread-pool-size" "and its own threads, on Linux"
one_pid="$(pid_of run-one)"
check_eq "$(ps -o pgid= -p "$one_pid" | tr -d ' ')" "$one_pid" "in a session of its own, which no signal to a suite reaches"

engine_attach_tree run-two "$SANDBOX/tree-two" 2>/dev/null
check_eq "$(engine_tree_slot run-two)" 2 "a second tree takes the next slot"
check_eq "$(engine_attached_runs | paste -sd, -)" "run-one,run-two" "the engine lists both"

# --- detach -----------------------------------------------------------------------

: > "$QMP_LOG"
engine_detach_tree run-one 2>"$SANDBOX/err"
check_eq "$?" 0 "a tree is detached ($(cat "$SANDBOX/err"))"
order="$(grep -oE '"execute":"(device_del|chardev-remove)"' "$QMP_LOG" | sed 's/"execute"://; s/"//g' | paste -sd, -)"
check_eq "$order" "device_del,chardev-remove" "the device goes first, then its chardev"
ticks=0
while alive "$one_pid" && [ "$ticks" -lt 100 ]; do /bin/sleep 0.1; ticks=$((ticks + 1)); done
check_eq "$(alive "$one_pid" && echo alive || echo gone)" gone "and only then its daemon"
check_eq "$(attached run-one)" 1 "and it is off the record"
engine_attach_tree run-three "$SANDBOX/tree-three" 2>/dev/null
check_eq "$(engine_tree_slot run-three)" 1 "a free slot is taken again"

# --- a device QEMU has and nobody recorded is not attached over --------------------

perl "$REPO/scripts/lib/qmp.pl" "$FLTH_VM_QMP" \
    '{"execute":"chardev-add","arguments":{"id":"c-orphan","backend":{"type":"socket","data":{"addr":{"type":"unix","data":{"path":"/nowhere"}},"server":false}}}}' \
    '{"execute":"device_add","arguments":{"driver":"vhost-user-fs-pci","id":"fs-orphan","chardev":"c-orphan","tag":"orphan","bus":"flth_rp3"}}' >/dev/null
out="$(engine_attach_tree run-four "$SANDBOX/tree-four" 2>&1)"
check_eq "$?" 1 "with every slot taken, by record or by QEMU's word, a tree is refused"
check_contains "$out" "all 3 slots for a run's tree are in use" "saying so"
check_contains "$out" "FLTH_SHARED_SLOTS" "and what reserves more"
check_eq "$(attached run-four)" 1 "and nothing is left on record"

# --- a daemon that has gone -------------------------------------------------------

two_pid="$(pid_of run-two)"
kill -KILL "$two_pid"
ticks=0
while alive "$two_pid" && [ "$ticks" -lt 50 ]; do /bin/sleep 0.1; ticks=$((ticks + 1)); done
check_eq "$(attached run-two)" 3 "a daemon that has gone is told apart from a tree that is not attached"
: > "$QMP_LOG"
engine_detach_tree run-two 2>/dev/null
check_eq "$(qmp_lines device_del)" 1 "and its device is still removed"
check_eq "$(attached run-two)" 1 "and its record goes"

# --- macOS: the guest powers the slot off ----------------------------------------

export FLTH_TEST_UNAME=Darwin
: > "$QMP_LOG"
: > "$RUNS"
t0=$SECONDS
engine_detach_tree run-three 2>/dev/null
check_contains "$(cat "$RUNS")" "echo 0 > /sys/bus/pci/slots/1/power" "on macOS the guest is asked to power the slot off"
check_eq "$(qmp_lines device_del)" 1 "and a guest that did not is asked with device_del, after a wait"
check_eq "$(( SECONDS - t0 >= 2 ))" 1 "of about three seconds"
engine_attach_tree run-mac "$SANDBOX/tree-one" 2>/dev/null
check_contains "$(cat "$(engine_vagrant_vfs_socket run-mac).args")" "--thread-pool-size=1" \
    "a macOS daemon has one thread: the port switches credentials process-wide"
unset FLTH_TEST_UNAME

# --- a guest that has gone ----------------------------------------------------------

mac_pid="$(pid_of run-mac)"
rm -f "$SANDBOX/alive"
engine_vagrant_forget_attached
ticks=0
while alive "$mac_pid" && [ "$ticks" -lt 50 ]; do /bin/sleep 0.1; ticks=$((ticks + 1)); done
check_eq "$(alive "$mac_pid" && echo alive || echo gone)" gone "once the guest has gone, every daemon is stopped"
check_eq "$(engine_attached_runs | grep -c . | tr -d ' ')" 0 "and nothing is left on record"

finish engine-attach
