#!/usr/bin/env bash
#
# stuck-run.sh — a process in one run that will not die does not hold up that run's
# end, nor another run's, and is named (#187).
#
# On a shared guest under memory pressure a suite's `umount` stuck in
# uninterruptible sleep, where no signal reaches it. The end of its run waited on
# it, so the run's /var/cache was never freed and its root never deleted, and the
# report said only that processes "would not stop". Here a zombie stands in for
# that process: it answers `kill -0` and no signal ends it, as a process in D state
# does. lib/guest-run.sh runs under the stub engine, with /proc redirected.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
RUNS="$FLTH_TEST_STUB/guest-runs"
ROOTS="$FLTH_TEST_STUB/guest-lib/runs"
make_consumer "$SANDBOX/one" stuck-one
mkdir -p "$FLTH_TEST_STUB/guest-repo" "$FLTH_TEST_STUB/guest-proc"
one() { (cd "$SANDBOX/one" && "$VM" "$@"); }

SUITES=""
begin_suite() {
    /bin/sleep 300 >/dev/null 2>&1 &
    SUITE=$!
    SUITES="$SUITES $SUITE"
    RUN="$(one run-id)"
    (FLTH_RUN_ID="$RUN" one session-begin "$SUITE") 2>/dev/null
}
# A zombie that is a process of run $1, named $2, in state $3: kill -0 finds it and
# no signal ends it, until its parent reaps it. Sets STUCK and its PARENT.
stuck_process() {
    local file="$SANDBOX/zombie.$RANDOM"
    perl -e 'my $c = fork; exit 0 unless defined $c; if (!$c) { exit 0 } open my $f, ">", $ARGV[0]; print {$f} "$c\n"; close $f; sleep 600' "$file" &
    PARENT=$!
    until [ -s "$file" ]; do /bin/sleep 0.05; done
    STUCK="$(cat "$file")"
    mkdir -p "$FLTH_TEST_STUB/guest-proc/$STUCK/ns"
    ln -s "mnt:[$1]" "$FLTH_TEST_STUB/guest-proc/$STUCK/ns/mnt"
    printf '%s\n' "$2" > "$FLTH_TEST_STUB/guest-proc/$STUCK/comm"
    printf '%s (%s) %s 1 1 1\n' "$STUCK" "$2" "$3" > "$FLTH_TEST_STUB/guest-proc/$STUCK/stat"
    printf '%s\n' folio_wait_bit_common > "$FLTH_TEST_STUB/guest-proc/$STUCK/wchan"
}
PARENTS=""
# shellcheck disable=SC2329  # the trap below calls it
cleanup() {
    local pid
    for pid in $SUITES $PARENTS; do kill -KILL "$pid" 2>/dev/null; done
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

one up >/dev/null 2>&1
check_eq "$?" 0 "a boot succeeds"
begin_suite; A=$SUITE; RUN_A=$RUN
begin_suite; B=$SUITE; RUN_B=$RUN
FLTH_RUN_ID="$RUN_A" one exec true >/dev/null 2>&1
FLTH_RUN_ID="$RUN_B" one exec true >/dev/null 2>&1
check_eq "$([ -e "$RUNS/ready.$RUN_A" ] && [ -e "$RUNS/ready.$RUN_B" ] && echo both)" both "two runs are under way"
stuck_process "$RUN_A" umount D
PARENTS="$PARENTS $PARENT"
check_eq "$(kill -0 "$STUCK" 2>/dev/null && echo there)" there "run A has a process no signal ends"

start=$SECONDS
out="$(one session-end "$A" 2>&1)"
check_eq "$?" 0 "the end of run A completes"
check_eq "$(( SECONDS - start < 60 ))" 1 "without waiting on the process for ever ($((SECONDS - start)) s)"
check_contains "$out" "process $STUCK (umount)" "naming the process that would not stop"
check_contains "$out" "state D" "its state"
check_contains "$out" "folio_wait_bit_common" "and what it waits on in the kernel"
check_eq "$([ -e "$RUNS/ready.$RUN_A" ] && echo kept || echo freed)" freed "the run is over, so its /var/cache is free for the next"
check_eq "$([ -d "$ROOTS/$RUN_A" ] && find "$ROOTS/$RUN_A" -type f | grep -c . || echo 0)" 0 "and its root is deleted"
check_eq "$(kill -0 "$B" 2>/dev/null && echo alive)" alive "run B's suite is untouched"

start=$SECONDS
one session-end "$B" >/dev/null 2>&1
check_eq "$?" 0 "and its end completes too"
check_eq "$(( SECONDS - start < 60 ))" 1 "not held up by run A's stuck process"
check_eq "$([ -e "$RUNS/ready.$RUN_B" ] && echo kept || echo freed)" freed "and frees its run"

finish stuck-run
