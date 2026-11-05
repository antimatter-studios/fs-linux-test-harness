#!/usr/bin/env bash
#
# One watchdog on the host for a running guest (#190). A stuck process or a guest
# that stopped answering ends the guest and frees the slot, and every suite on it
# fails with a status of its own, saying why. A long busy build trips nothing.
#
# Real vm.sh, vm-session.sh and vm-watchdog.sh, with the stub engine: what the guest
# would report comes from $STUB/report. tests/guest-watchdog-probe.sh holds the
# script that writes that report.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
unset FLTH_WATCHDOG
export FLTH_WATCHDOG_INTERVAL=1 FLTH_WATCHDOG_WARN_SECS=1 FLTH_WATCHDOG_STUCK_SECS=4 FLTH_WATCHDOG_SILENT_SECS=4
VM="$STUB_HARNESS/scripts/vm.sh"
STUB="$FLTH_TEST_STUB"
C="$SANDBOX/consumer"
make_consumer "$C" watched
MACHINE="$FLTH_CACHE_DIR/machines/watched"
ENDED=75

vm() { (cd "$C" && "$VM" "$@"); }
slot_holder() { awk -F'\t' '{print $2}' "$FLTH_STATE_DIR/slot.lock/holder" 2>/dev/null; }
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
watchdogs() {
    local pid
    pid="$(cat "$MACHINE/watchdog.pid" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo running
}
# shellcheck disable=SC2329
no_watchdog() { [ -z "$(watchdogs)" ]; }

healthy='mem 8000000 16000000
disk 40000000 64000000'
report() { printf '%s\n' "$healthy" "$@" > "$STUB/report"; }
fresh() {
    rm -f "$STUB/report" "$STUB/report_silent" "$STUB/report_cmd"
    report
    stub_reset_calls
}

# --- it starts and ends with the guest ------------------------------------------

fresh
vm up 2>/dev/null
check_eq "$?" 0 "a guest boots"
check_eq "$(watchdogs)" running "and a watchdog starts with it"
if wait_until 100 file_holds "$MACHINE/watchdog.log" ' ok: '; then
    ok "it logs what it sees"
else
    bad "it logs what it sees ($(cat "$MACHINE/watchdog.log" 2>/dev/null))"
fi
check_contains "$(vm status 2>&1)" "watchdog" "and vm.sh status shows it"
vm down 2>/dev/null
if wait_until 100 no_watchdog; then ok "a down ends it"; else bad "a down ends it"; fi

fresh
vm up 2>/dev/null
stub_state stopped
if wait_until 100 no_watchdog; then
    ok "a guest that stopped by itself ends it"
else
    bad "a guest that stopped by itself ends it"
fi
vm down 2>/dev/null

# Stands in for a suite: it stays up until the watchdog stops its session.
cat > "$SANDBOX/suite.sh" <<'SUITE'
#!/usr/bin/env bash
: > "$1"
/bin/sleep 300 &
wait
SUITE
start_suite() {
    # start_suite <name>: sets SUITE_PID
    local name="$1" monitor=0
    case "$-" in *m*) monitor=1 ;; esac
    set -m
    (cd "$C" && exec "$VM" session bash "$SANDBOX/suite.sh" "$SANDBOX/$name.started") \
        > "$SANDBOX/$name.out" 2>&1 &
    SUITE_PID=$!
    [ "$monitor" = 1 ] || set +m
    wait_until 600 test -e "$SANDBOX/$name.started" || bad "$name never started"
}
reset_suites() { rm -f "$SANDBOX"/*.started "$SANDBOX"/*.out; }
# Bounded, so a suite the watchdog fails to stop fails this and does not hang it. Not
# in a substitution: `wait` only knows this shell's own children. Leaves SUITE_STATUS.
wait_for_suite() {
    local pid="$1" n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 600 ]; do
        /bin/sleep 0.1
        n=$((n + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null
        { wait "$pid"; } 2>/dev/null
        SUITE_STATUS=stuck
        return 0
    fi
    { wait "$pid"; } 2>/dev/null
    SUITE_STATUS=$?
}

# --- a stuck process ends the guest, whoever holds it ----------------------------

fresh
vm up 2>/dev/null
start_suite one
one=$SUITE_PID
start_suite two
two=$SUITE_PID
report 'd 4242 777 same-token - sync'
if wait_until 300 stopped; then
    ok "a stuck process ends the guest"
else
    bad "a stuck process ends the guest (state $(state); $(tail -n 3 "$MACHINE/watchdog.log" 2>/dev/null))"
fi
check_contains "$(stub_calls)" "down --force" "by force, since a graceful stop would wait on it too"
wait_for_suite "$one"
check_eq "$SUITE_STATUS" "$ENDED" "the first suite ends with a status of its own"
wait_for_suite "$two"
check_eq "$SUITE_STATUS" "$ENDED" "and so does the second"
for name in one two; do
    check_contains "$(cat "$SANDBOX/$name.out")" "the watchdog ended this guest" "$name says the watchdog ended the guest"
    check_contains "$(cat "$SANDBOX/$name.out")" "sync" "$name names the stuck process"
    check_contains "$(cat "$SANDBOX/$name.out")" "not a failure of the suite" "$name says this is not its own failure"
done
check_eq "$(slot_holder)" "" "the slot is free"
check_contains "$(vm status 2>&1)" "the watchdog ended" "vm.sh status says why it is down"
check_contains "$(cat "$MACHINE/watchdog.log")" "4242" "the log names the process"

out="$(vm exec true 2>&1)"
check_eq "$?" "$ENDED" "a later exec has the same status"
check_contains "$out" "the watchdog ended" "and the same reason"

# The next boot starts clean.
fresh
vm up 2>/dev/null
check_lacks "$(vm status 2>&1)" "the watchdog ended" "a new boot forgets the last one's ending"
vm exec true 2>/dev/null
check_eq "$?" 0 "and calls work again"
vm down 2>/dev/null
reset_suites

# --- a guest that stopped answering ----------------------------------------------

fresh
vm up 2>/dev/null
start_suite silent
silent=$SUITE_PID
: > "$STUB/report_silent"
if wait_until 300 stopped; then
    ok "a guest that stopped answering is ended"
else
    bad "a guest that stopped answering is ended (state $(state))"
fi
wait_for_suite "$silent"
check_eq "$SUITE_STATUS" "$ENDED" "its suite ends with that status"
check_contains "$(cat "$SANDBOX/silent.out")" "did not answer" "saying the guest did not answer"
check_eq "$(slot_holder)" "" "and the slot is free"
reset_suites

# One check that did not answer is a loaded host, not a lost guest.
fresh
vm up 2>/dev/null
cat > "$STUB/report_cmd" <<'CMD'
n="$(cat "$STUB/report_count" 2>/dev/null || echo 0)"
echo $((n + 1)) > "$STUB/report_count"
if [ "$n" = 1 ]; then exit 1; fi
printf 'mem 8000000 16000000\ndisk 40000000 64000000\n'
CMD
/bin/sleep 7
check_eq "$(state)" running "one missed check ends nothing"
vm down 2>/dev/null

# --- a long busy build trips nothing ----------------------------------------------

# In uninterruptible sleep at every check, as a process doing heavy I/O is, for
# longer than the limit, and getting somewhere between them.
fresh
vm up 2>/dev/null
start_suite busy
busy=$SUITE_PID
cat > "$STUB/report_cmd" <<'CMD'
n="$(cat "$STUB/report_count" 2>/dev/null || echo 0)"
echo $((n + 1)) > "$STUB/report_count"
printf 'mem 8000000 16000000\ndisk 40000000 64000000\nd 5151 888 token-%s - cc1\n' "$n"
CMD
rm -f "$STUB/report_count"
/bin/sleep 10
check_eq "$(state)" running "a busy process past the limit ends nothing"
if kill -0 "$busy" 2>/dev/null; then ok "and its suite runs on"; else bad "and its suite runs on"; fi
check_lacks "$(cat "$MACHINE/watchdog.log")" "stuck" "and nothing calls it stuck"
# Different processes in that state in turn are not one stuck process either.
kill -TERM "$busy" 2>/dev/null
wait_for_suite "$busy"
check_eq "$SUITE_STATUS" 143 "the suite's own end is its own status"
check_lacks "$(cat "$SANDBOX/busy.out")" "the watchdog ended" "and it blames nothing on the watchdog"
vm down 2>/dev/null
reset_suites

# --- warnings stop nothing --------------------------------------------------------

fresh
report 'd 6161 999 same-token - sync'
printf 'mem 100 16000000\ndisk 100 64000000\n' > "$STUB/report"
export FLTH_WATCHDOG_STUCK_SECS=1000
vm up 2>/dev/null
printf 'mem 100 16000000\ndisk 100 64000000\nd 6161 999 same-token - sync\n' > "$STUB/report"
if wait_until 100 file_holds "$MACHINE/watchdog.log" 'warning.*6161.*sync'; then
    ok "a process past the warning limit is named"
else
    bad "a process past the warning limit is named ($(tail -n 3 "$MACHINE/watchdog.log"))"
fi
check_contains "$(cat "$MACHINE/watchdog.log")" "warning: memory" "low memory is warned of"
check_contains "$(cat "$MACHINE/watchdog.log")" "warning: disk" "and low disk"
check_eq "$(state)" running "and neither stops anything"
check_contains "$(vm status 2>&1)" "warning" "vm.sh status shows the warning"
vm down 2>/dev/null
export FLTH_WATCHDOG_STUCK_SECS=4

# --- what the kernel says on its console (#196) -------------------------------------

# As a guest's kernel wrote it on 2026-11-05: an oops in reclaim that left the guest up,
# a second in a process reading a share, and later a soft lockup.
fresh
vm up 2>/dev/null
cat >> "$STUB/console.log" <<'CONSOLE'
[ 1783.104122] Unable to handle kernel NULL pointer dereference at virtual address 0000000000000000
[ 1783.104511] Internal error: Oops: 0000000096000004 [#1] SMP
[ 1783.104902] CPU: 2 PID: 73 Comm: kswapd0 Not tainted 6.1.0-42-cloud-arm64 #1  Debian 6.1.159-1
[ 1783.105301] pc : drop_buffers+0x3c/0x130
CONSOLE
if wait_until 100 file_holds "$MACHINE/watchdog.log" 'warning: the kernel oopsed'; then
    ok "an oops on the console is warned of"
else
    bad "an oops on the console is warned of ($(tail -n 3 "$MACHINE/watchdog.log"))"
fi
check_contains "$(cat "$MACHINE/watchdog.log")" "kswapd0" "naming the process it was in"
check_contains "$(cat "$MACHINE/watchdog.log")" "[#1]" "and which oops it was"
cat >> "$STUB/console.log" <<'CONSOLE'
[ 2950.441870] watchdog: BUG: soft lockup - CPU#7 stuck for 24s! [rustc:62246]
CONSOLE
if wait_until 100 file_holds "$MACHINE/watchdog.log" 'warning: a soft lockup'; then
    ok "a soft lockup on the console is warned of"
else
    bad "a soft lockup on the console is warned of ($(tail -n 3 "$MACHINE/watchdog.log"))"
fi
check_contains "$(cat "$MACHINE/watchdog.log")" "CPU#7 stuck for 24s! [rustc:62246]" "naming the CPU and the process"
/bin/sleep 3
check_eq "$(grep -c 'warning: the kernel oopsed' "$MACHINE/watchdog.log")" 1 "each is warned of once, not at every look"
report 'tainted 17024'
if wait_until 100 file_holds "$MACHINE/watchdog.log" 'warning: the kernel is tainted'; then
    ok "a taint is warned of"
else
    bad "a taint is warned of"
fi
check_contains "$(cat "$MACHINE/watchdog.log")" "17024" "with its value"
check_contains "$(cat "$MACHINE/watchdog.log")" "D: it oopsed" "and what its letters say"
check_contains "$(cat "$MACHINE/watchdog.log")" "L: a soft lockup" "each of them"
check_eq "$(state)" running "and none of it stops anything yet"
check_contains "$(vm status 2>&1)" "warning" "vm.sh status shows it"
vm down 2>/dev/null

# --- a held guest belongs to the person holding it --------------------------------

fresh
vm up 2>/dev/null
vm hold 2>/dev/null
report 'd 7171 111 same-token - sync'
/bin/sleep 7
check_eq "$(state)" running "a held guest is not ended"
check_contains "$(cat "$MACHINE/watchdog.log")" "held" "and the log says what it would have done"
vm down 2>/dev/null

# --- switched off -----------------------------------------------------------------

fresh
FLTH_WATCHDOG=off vm up 2>/dev/null
check_eq "$(watchdogs)" "" "FLTH_WATCHDOG=off starts none"
vm down 2>/dev/null

finish guest-watchdog
