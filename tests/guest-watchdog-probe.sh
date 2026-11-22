#!/usr/bin/env bash
#
# The script the watchdog runs in a guest, standalone against a made /proc: what it
# reports of memory, disk and uninterruptible sleep, and that it reads nothing that
# a process in that state can block on. The real one is read by tests/smoke.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
require_guest_bash || exit 1
PROBE="$REPO/vagrant/guest/watchdog-probe.sh"
PROC="$SANDBOX/proc"
RUNS="$SANDBOX/runs"
BIN="$SANDBOX/bin"
mkdir -p "$PROC" "$RUNS/ns" "$BIN"
printf 'MemTotal:       16000000 kB\nMemFree:          100 kB\nMemAvailable:    8000000 kB\n' > "$PROC/meminfo"
mkdir -p "$PROC/sys/kernel"
echo 17024 > "$PROC/sys/kernel/tainted"
# df and the namespace's inode, as the guest's GNU tools answer them.
printf '#!/bin/sh\necho Filesystem 1024-blocks Used Available Capacity Mounted\necho /dev/vda 64000000 24000000 40000000 38%% /\n' > "$BIN/df"
printf '#!/bin/sh\nfor last; do :; done\ncat "$last.inode"\n' > "$BIN/stat"
chmod +x "$BIN/df" "$BIN/stat"
# What each run's namespace mounts: its tree, tagged with its id, on its own device.
cat > "$BIN/nsenter" <<STUB
#!/bin/sh
case "\$1" in
    --mount=*/run-a) printf '0:52 run-a\\n0:53 other-tag\\n' ;;
    --mount=*/run-b) printf '0:53 run-b\\n' ;;
esac
STUB
chmod +x "$BIN/nsenter"
# The guest's control filesystem is mounted by the probe when it is not; here that
# would be this host's, so the stand-in only logs.
printf '#!/bin/sh\necho "mount $*" >> "%s/mounts"\n' "$SANDBOX" > "$BIN/mount"
chmod +x "$BIN/mount"
export PATH="$BIN:$PATH"

task() {
    # task <pid> <comm> <state> <utime> <stime> <start> <rchar> <wchar> [namespace]
    local dir="$PROC/$1"
    mkdir -p "$dir/ns"
    printf '%s (%s) %s 1 1 1 0 -1 0 0 0 0 0 %s %s 0 0 20 0 1 0 %s 0 0\n' "$1" "$2" "$3" "$4" "$5" "$6" > "$dir/stat"
    printf 'rchar: %s\nwchar: %s\nsyscr: 0\n' "$7" "$8" > "$dir/io"
    [ -z "${9:-}" ] || ln -sf "$9" "$dir/ns/mnt"
}
probe() {
    FLTH_WATCHDOG_PROC="$PROC" FLTH_GUEST_RUNS="$RUNS" FLTH_WATCHDOG_FUSECTL="${FUSECTL:-$SANDBOX/no-fusectl}" \
        "$FLTH_TEST_GUEST_BASH" "$PROBE"
}

task 10 init S 5 5 1 0 0
task 11 'cc1 plus' D 100 20 500 1000 2000 'mnt:[4026]'
task 12 sync D 3 4 600 7 8 'mnt:[4099]'
printf 'mnt:[4026]\n' > "$RUNS/ns/run-a.inode"
: > "$RUNS/ns/run-a"

out="$(probe)"
check_eq "$?" 0 "the probe answers"
check_contains "$out" "mem 8000000 16000000" "memory available and in all"
check_contains "$out" "disk 40000000 64000000" "disk available and in all"
check_contains "$out" "tainted 17024" "and the kernel's taint"
check_contains "$out" "d 11 500 120:3000 run-a cc1 plus" "a task in D: pid, start, what it has done so far, its run and name"
check_contains "$out" "d 12 600 7:15 - sync" "and one in no run"
check_lacks "$out" "d 10 " "a sleeping task is not listed"

task 11 'cc1 plus' D 100 21 500 1000 2000 'mnt:[4026]'
check_contains "$(probe)" "d 11 500 121:3000 " "time on the CPU moves what it has done"
task 11 'cc1 plus' D 100 21 500 1000 2500 'mnt:[4026]'
check_contains "$(probe)" "d 11 500 121:3500 " "and so does I/O"

# --- threads waiting on a FUSE reply, and each run's outstanding requests (#289) ---

thread() {
    # thread <pid> <tid> <comm> <state> <utime> <stime> <start> <wchan> <times run>
    local dir="$PROC/$1/task/$2"
    mkdir -p "$dir"
    printf '%s (%s) %s 1 1 1 0 -1 0 0 0 0 0 %s %s 0 0 20 0 1 0 %s 0 0\n' "$2" "$3" "$4" "$5" "$6" "$7" > "$dir/stat"
    printf 'rchar: 10\nwchar: 20\nsyscr: 0\n' > "$dir/io"
    printf '%s\n' "$8" > "$dir/wchan"
    printf '100 200 %s\n' "$9" > "$dir/schedstat"
}
thread 11 11 'cc1 plus' D 100 20 500 folio_wait_bit_common 3
thread 11 14 'test worker' S 7 8 510 fuse_simple_request 42
thread 12 15 sync S 1 1 600 request_wait_answer 5
thread 10 16 fused S 1 1 700 fuse_dev_do_read 9
thread 10 17 idle S 1 1 700 hrtimer_nanosleep 9
out="$(probe)"
check_contains "$out" "f 14 510 15:30:42 run-a test worker" "a thread waiting on a FUSE reply: its id, start, what it has done, times run, run and name"
check_contains "$out" "f 15 600 2:30:5 - sync" "and one waiting where the kernel names the wait itself"
check_lacks "$out" "f 11 " "a thread waiting elsewhere is not listed"
check_lacks "$out" "f 16 " "nor a FUSE server waiting for its next request"
check_lacks "$out" "f 17 " "nor a sleeping one"
thread 11 14 'test worker' S 7 8 510 fuse_simple_request 43
check_contains "$(probe)" "f 14 510 15:30:43 " "running again moves what it has done"

FUSECTL="$SANDBOX/fusectl"
mkdir -p "$FUSECTL/52" "$FUSECTL/53"
echo 3 > "$FUSECTL/52/waiting"
: > "$RUNS/ns/run-b"
printf 'mnt:[4100]\n' > "$RUNS/ns/run-b.inode"
out="$(probe)"
check_contains "$out" "t run-a 3" "a run's requests outstanding on its own connection"
check_contains "$out" "t run-b ?" "and a count that cannot be read is said to be unknown"
check_lacks "$out" "t run-a.inode" "the namespace's record is no run"
check_eq "$(cat "$SANDBOX/mounts" 2>/dev/null)" "" "a control filesystem already mounted is not mounted again"
mkdir -p "$SANDBOX/empty-fusectl"
FUSECTL="$SANDBOX/empty-fusectl" probe >/dev/null
check_contains "$(cat "$SANDBOX/mounts" 2>/dev/null)" "-t fusectl fusectl $SANDBOX/empty-fusectl" "an empty one is mounted"

# A task that goes between the listing and the read is not an error.
mkdir -p "$PROC/13"
out="$(probe)"
check_eq "$?" 0 "a task with nothing left to read is passed over"

# What blocks on a process in D: its memory, so its command line and environment.
check_lacks "$(cat "$PROBE")" "/environ" "the probe does not read a task's environment"
check_lacks "$(cat "$PROBE")" "/cmdline" "or its command line"

# --- the question, through the real engine ----------------------------------------

export FLTH_HARNESS="$REPO" FLTH_MACHINE_DIR="$SANDBOX/machine" FLTH_GUEST_RUNS="$RUNS"
mkdir -p "$FLTH_MACHINE_DIR"
echo 'Host default' > "$FLTH_MACHINE_DIR/ssh-config"
. "$REPO/scripts/lib/engine-vagrant.sh"
cat > "$BIN/ssh" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$SSH_ARGS"
cat > "$SSH_SCRIPT"
[ ! -e "$SSH_HANG" ] || exec /bin/sleep 300
echo answered
STUB
chmod +x "$BIN/ssh"
export SSH_ARGS="$SANDBOX/ssh-args" SSH_SCRIPT="$SANDBOX/ssh-script" SSH_HANG="$SANDBOX/ssh-hang"
check_eq "$(engine_guest_report)" answered "it asks over ssh"
check_eq "$(cat "$SSH_SCRIPT")" "$(cat "$PROBE")" "sending the probe"
check_contains "$(cat "$SSH_ARGS")" "ControlPath=none" "on a connection of its own"
# shellcheck disable=SC2034  # read by engine_guest_report
ENGINE_VAGRANT_REPORT_LIMIT=1
: > "$SSH_HANG"
started=$SECONDS
if { engine_guest_report >/dev/null; } 2>/dev/null; then
    bad "a guest that does not answer in time fails it"
else
    ok "a guest that does not answer in time fails it"
fi
check_eq "$([ $((SECONDS - started)) -lt 30 ] && echo bounded)" bounded "within its limit"

finish guest-watchdog-probe
