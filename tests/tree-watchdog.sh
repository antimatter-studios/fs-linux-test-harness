#!/usr/bin/env bash
#
# A run whose virtiofsd stops answering, while a call waits on its tree (#289). The
# guest still answers the watchdog, so its silent limit never fires, and the waiting
# process may not be in uninterruptible sleep at all, so its stuck limit may not
# either. Without this, the call waited until the CI job's limit (#274, #281).
#
# A request a virtiofsd never answers is never completed by the guest's kernel, and
# removing the device then wedges hot-plug for the whole guest. So a run with a call
# waiting on a daemon that has gone, or has stopped answering, can only be ended with
# the guest. Every suite on it fails with the watchdog's status, naming the run's
# tree and its virtiofsd. A run whose daemon has gone with nothing waiting on it
# keeps the narrower path: its device goes first and only that run ends.
#
# Real vm.sh, vm-session.sh and vm-watchdog.sh, with the stub engine. What the guest
# would report, among it the processes waiting on a FUSE reply, comes from
# $STUB/report. tests/guest-watchdog-probe.sh holds the script that writes it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
unset FLTH_WATCHDOG
export FLTH_WATCHDOG_INTERVAL=1 FLTH_WATCHDOG_WARN_SECS=1 FLTH_WATCHDOG_STUCK_SECS=1000 \
    FLTH_WATCHDOG_SILENT_SECS=1000 FLTH_WATCHDOG_TREE_SECS=4
VM="$STUB_HARNESS/scripts/vm.sh"
STUB="$FLTH_TEST_STUB"
C="$SANDBOX/consumer"
make_consumer "$C" treed
C="$(cd "$C" && pwd -P)"
MACHINE="$FLTH_CACHE_DIR/machines/shared-debian-12"
ENDED=75

vm() { (cd "$C" && "$VM" "$@"); }
state() { cat "$STUB/state"; }
wait_until() {
    # wait_until <tenths of a second> <command...>
    local tries="$1" n=0
    shift
    until "$@"; do
        [ "$n" -lt "$tries" ] || return 1
        /bin/sleep 0.1
        n=$((n + 1))
    done
}
# shellcheck disable=SC2329  # wait_until calls these by name
stopped() { [ "$(state)" = stopped ]; }
# shellcheck disable=SC2329
file_holds() { grep -q "$2" "$1" 2>/dev/null; }

healthy='mem 8000000 16000000
disk 40000000 64000000'
report() { printf '%s\n' "$healthy" "$@" > "$STUB/report"; }
fresh() {
    rm -f "$STUB/report" "$STUB/report_cmd" "$STUB"/daemon-dead.* "$STUB"/daemon-pid.* "$SANDBOX"/*.started "$SANDBOX"/*.out
    report
    stub_reset_calls
}

# Stands in for a suite whose call waits on its tree: a session whose one call into
# the guest does not return until the session is stopped.
start_suite() {
    # start_suite <name>: sets SUITE_PID and SUITE_RUN
    local name="$1" monitor=0
    case "$-" in *m*) monitor=1 ;; esac
    set -m
    (cd "$C" && exec "$VM" session bash -c \
        '"$1" run "touch $2; while :; do /bin/sleep 0.1; done"' flth-test "$VM" "$SANDBOX/$name.started") \
        > "$SANDBOX/$name.out" 2>&1 &
    SUITE_PID=$!
    [ "$monitor" = 1 ] || set +m
    wait_until 600 test -e "$SANDBOX/$name.started" || bad "$name never started"
    SUITE_RUN="$(cut -f4 "$MACHINE/sessions/$SUITE_PID" 2>/dev/null)"
}
# Bounded, so a suite the watchdog fails to stop fails this and does not hang it.
# Leaves SUITE_STATUS, and SUITE_TOOK in seconds.
wait_for_suite() {
    local pid="$1" n=0 began=$SECONDS
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 300 ]; do
        /bin/sleep 0.1
        n=$((n + 1))
    done
    SUITE_TOOK=$((SECONDS - began))
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null
        { wait "$pid"; } 2>/dev/null
        SUITE_STATUS=stuck
        return 0
    fi
    { wait "$pid"; } 2>/dev/null
    SUITE_STATUS=$?
}
# The calls before the guest was forced down, for what happened to the device first.
calls_before_down() { sed '/^down --force$/,$d' "$STUB/calls"; }

# --- its virtiofsd dies while a call waits on the tree ------------------------------

fresh
vm up 2>/dev/null
start_suite gone
gone=$SUITE_PID
check_eq "$([ -f "$STUB/attached/$SUITE_RUN" ] && echo attached)" attached "the suite's run has its tree attached"
stub_reset_calls
report "f 4343 777 5:100:9 $SUITE_RUN setfattr"
echo 9191 > "$STUB/daemon-pid.$SUITE_RUN"
: > "$STUB/daemon-dead.$SUITE_RUN"
wait_for_suite "$gone"
check_eq "$SUITE_STATUS" "$ENDED" "a call waiting on a run whose virtiofsd died fails with the watchdog's status"
check_eq "$([ "$SUITE_TOOK" -le 10 ] && echo bounded)" bounded "within the bound (${SUITE_TOOK}s)"
out="$(cat "$SANDBOX/gone.out")"
check_contains "$out" "the watchdog ended this guest" "saying the watchdog ended it"
check_contains "$out" "virtiofsd (pid 9191)" "naming the run's virtiofsd"
check_contains "$out" "$C" "and the run's tree"
check_contains "$out" "has gone" "and that the daemon has gone"
check_contains "$out" "setfattr" "and the process that waited on it"
check_contains "$out" "not a failure of the suite" "and that it is not the suite's failure"
check_eq "$(state)" stopped "the guest is ended: only a reboot clears a request nobody will answer"
check_lacks "$(calls_before_down)" "detach $SUITE_RUN" "and the device is not removed under the waiting request first"
check_contains "$(cat "$MACHINE/watchdog.log")" "$SUITE_RUN" "the log names the run"
check_contains "$(vm status 2>&1)" "virtiofsd" "status says why the guest went"
vm down 2>/dev/null

# --- its virtiofsd lives on and stops answering -------------------------------------

fresh
vm up 2>/dev/null
start_suite hung
hung=$SUITE_PID
report "f 5454 888 5:100:9 $SUITE_RUN touch"
wait_for_suite "$hung"
check_eq "$SUITE_STATUS" "$ENDED" "a call its run's virtiofsd stopped answering fails with the watchdog's status"
check_eq "$([ "$SUITE_TOOK" -le 15 ] && echo bounded)" bounded "within the bound (${SUITE_TOOK}s for a 4s limit)"
out="$(cat "$SANDBOX/hung.out")"
check_contains "$out" "virtiofsd" "naming the run's virtiofsd"
check_contains "$out" "$C" "and the run's tree"
check_contains "$out" "has not answered" "and that it stopped answering"
check_contains "$out" "touch" "and the process that waited on it"
check_eq "$(state)" stopped "the guest is ended"
check_contains "$(cat "$MACHINE/watchdog.log")" "warning: " "the watchdog warned of the wait before it ended the guest"
vm down 2>/dev/null

# --- a busy tree trips nothing --------------------------------------------------------

# A process that makes call after call on its tree is waiting on a reply at every look,
# for longer than the limit, and its count of times it ran moves between them.
fresh
vm up 2>/dev/null
start_suite busy
busy=$SUITE_PID
printf 'run=%s\n' "$SUITE_RUN" > "$STUB/report_run"
cat > "$STUB/report_cmd" <<'CMD'
. "$STUB/report_run"
n="$(cat "$STUB/report_count" 2>/dev/null || echo 0)"
echo $((n + 1)) > "$STUB/report_count"
printf 'mem 8000000 16000000\ndisk 40000000 64000000\nf 6565 999 5:100:%s %s cp\n' "$n" "$run"
CMD
rm -f "$STUB/report_count"
/bin/sleep 8
check_eq "$(state)" running "a busy tree past the limit ends nothing"
if kill -0 "$busy" 2>/dev/null; then ok "and its suite runs on"; else bad "and its suite runs on"; fi
check_lacks "$(cat "$MACHINE/watchdog.log")" "has not answered" "and nothing calls its daemon unanswering"
kill -TERM "$busy" 2>/dev/null
wait_for_suite "$busy"
check_lacks "$(cat "$SANDBOX/busy.out")" "the watchdog ended" "its own end blames nothing on the watchdog"
vm down 2>/dev/null

# --- a wait on the suite's own FUSE filesystem is not its virtiofsd's ---------------

# The guest says its run's connection has nothing outstanding: the thread waits on a
# FUSE filesystem the suite runs in the guest, which is the suite's to judge.
fresh
vm up 2>/dev/null
start_suite own
own=$SUITE_PID
report "f 7676 111 5:100:9 $SUITE_RUN own-fuse-client" "t $SUITE_RUN 0"
/bin/sleep 8
check_eq "$(state)" running "a wait past the limit with nothing outstanding on the run's connection ends nothing"
check_lacks "$(cat "$MACHINE/watchdog.log")" "has not answered" "and nothing calls its virtiofsd unanswering"
# And its virtiofsd going then is the narrower case: nothing of it is outstanding.
stub_reset_calls
: > "$STUB/daemon-dead.$SUITE_RUN"
wait_for_suite "$own"
check_eq "$SUITE_STATUS" "$ENDED" "its virtiofsd going ends the run with the watchdog's status"
check_contains "$(stub_calls)" "detach $SUITE_RUN" "removing its device, since nothing of it is outstanding"
check_eq "$(state)" running "and leaving the guest up"
vm down 2>/dev/null

# --- its virtiofsd dies with requests outstanding and no thread seen waiting ---------

fresh
vm up 2>/dev/null
start_suite pending
pending=$SUITE_PID
stub_reset_calls
report "t $SUITE_RUN 2"
: > "$STUB/daemon-dead.$SUITE_RUN"
wait_for_suite "$pending"
check_eq "$SUITE_STATUS" "$ENDED" "a run whose virtiofsd died with requests outstanding fails with the watchdog's status"
check_contains "$(cat "$SANDBOX/pending.out")" "2 requests outstanding" "saying how many it left unanswered"
check_contains "$(cat "$SANDBOX/pending.out")" "$C" "naming the run's tree"
check_eq "$(state)" stopped "the guest is ended"
check_lacks "$(calls_before_down)" "detach $SUITE_RUN" "and the device is not removed under those requests first"
vm down 2>/dev/null

# --- its virtiofsd dies with nothing waiting on the tree ----------------------------

# Nothing can be using the device: it is removed before anything else runs in the run,
# and only that run ends. The guest stays up for every other suite.
fresh
vm up 2>/dev/null
start_suite idle
idle=$SUITE_PID
stub_reset_calls
: > "$STUB/daemon-dead.$SUITE_RUN"
wait_for_suite "$idle"
check_eq "$SUITE_STATUS" "$ENDED" "a run whose idle virtiofsd died ends with the watchdog's status"
out="$(cat "$SANDBOX/idle.out")"
check_contains "$out" "virtiofsd" "naming the run's virtiofsd"
check_contains "$out" "$C" "and the run's tree"
check_contains "$(stub_calls)" "detach $SUITE_RUN" "its device is removed"
check_eq "$(state)" running "and the guest stays up for the next run"
vm down 2>/dev/null

finish tree-watchdog
