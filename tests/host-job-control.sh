#!/usr/bin/env bash
#
# host-job-control.sh -- the host side starts its background jobs without job
# control (#209).
#
# With job control on (`set -m`), Bash makes a background job's process group from
# both sides at once: the shell calls setpgid for the child and the child calls it
# for itself, as POSIX asks. On macOS the two calls race, the child's fails with
# EPERM although the group is made, and Bash prints
#
#     child setpgid (8962 to 8962): Operation not permitted
#
# into the caller's stderr. Measured on arm64 macOS: 5 of 8,000 session launches,
# four loops in parallel. Linux has no such race, and on macOS it is too rare for a
# test to wait for, so what is held here is its cause, on every platform: no
# statement of vm.sh or vm-session.sh runs with job control on, while a session
# runs a command, passes a signal on to it, while `up` boots and while it passes a
# signal on to the boot. A Bash started for either script reads BASH_ENV, which
# traces every statement, functions included, and records any that runs with `m`
# in $-.
#
# What job control gave them is held too: the command and the boot each run in a
# process group of their own, and the signal still stops them.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
STUB="$FLTH_TEST_STUB"
make_consumer "$SANDBOX/consumer" host-job-control
export FLTH_CONFIG="$SANDBOX/consumer/fs-linux-test-harness.toml"

export JOB_CONTROL_LOG="$SANDBOX/job-control"
: > "$JOB_CONTROL_LOG"
cat > "$SANDBOX/trace.sh" <<'TRACE'
set -o functrace
flth_test_trace() {
    case "${0##*/}" in vm.sh | vm-session.sh) ;; *) return 0 ;; esac
    case "$-" in *m*) printf '%s: %s\n' "${0##*/}" "$1" >> "$JOB_CONTROL_LOG" ;; esac
    return 0
}
trap 'flth_test_trace "$BASH_COMMAND"' DEBUG
TRACE
export BASH_ENV="$SANDBOX/trace.sh"

# What a command or a boot reports about itself: its pid and its process group.
GROUP='echo "$$ $(ps -o pgid= -p "$$" | tr -d " ")"'

# A session runs a command.
out="$("$VM" session "$BASH" -c "$GROUP" 2>"$SANDBOX/session.err")"
status=$?
check_eq "$status" 0 "a session runs its command"
read -r pid pgid <<< "$out"
check_eq "${pgid:-none}" "${pid:-unknown}" "the session's command leads a process group of its own"
check_eq "$(cat "$SANDBOX/session.err")" "" "and the session prints nothing of its own"

# A session passes a signal on: the command signals the session, which runs it.
"$VM" session "$BASH" -c 'echo started; kill -TERM "$PPID"; exec /bin/sleep 30' \
    > "$SANDBOX/signalled.out" 2> "$SANDBOX/signalled.err"
status=$?
check_eq "$status" 143 "a signalled session exits 143"
check_eq "$(cat "$SANDBOX/signalled.out")" started "its command ran until the signal"
check_eq "$(cat "$SANDBOX/signalled.err")" "" "and the session prints nothing of its own"

# `up` boots.
"$VM" up > "$SANDBOX/up.out" 2>&1
check_eq "$?" 0 "up boots"
check_lacks "$(cat "$SANDBOX/up.out")" setpgid "and prints nothing about process groups"
"$VM" down > /dev/null 2>&1

# `up` passes a signal on to the boot, held at the stub engine's gate, which is a
# process group of its own: up's one child.
: > "$STUB/gate_up"
"$VM" up > "$SANDBOX/up-signalled.out" 2>&1 &
up_pid=$!
waits=0
while [ ! -f "$STUB/gate_up.reached" ] && [ "$waits" -lt 1200 ]; do
    /bin/sleep 0.05
    waits=$((waits + 1))
done
check_eq "$([ -f "$STUB/gate_up.reached" ] && echo reached)" reached "a boot reaches the stub engine's gate"
boot="$(ps -A -o pid=,ppid=,pgid= | awk -v up="$up_pid" '$2 == up { print $1, $3 }')"
read -r pid pgid <<< "$boot"
check_eq "${pgid:-none}" "${pid:-unknown}" "the boot leads a process group of its own"
kill -TERM "$up_pid"
wait "$up_pid"
check_eq "$?" 143 "a signalled up exits 143"
rm -f "$STUB/gate_up"
check_eq "$(ps -A -o pgid= | tr -d ' ' | grep -cx "${pgid:-none}")" 0 "and nothing is left in the boot's group"
check_lacks "$(cat "$SANDBOX/up-signalled.out")" setpgid "and prints nothing about process groups"

check_eq "$(cat "$JOB_CONTROL_LOG")" "" "no statement of vm.sh or vm-session.sh ran with job control on"

finish host-job-control
