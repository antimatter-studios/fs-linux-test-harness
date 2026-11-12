#!/usr/bin/env bash
#
# shared-guest-call.sh — a call into a shared guest outside any session is a user of
# it (#153). A shutdown request stops the guest only when nobody is using it, and a
# `vm.sh run` or `vm.sh exec` by hand is using it for as long as it lasts.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
SRC="$(cd "$SANDBOX" && pwd -P)/src"
make_consumer "$SRC/one" call-one
make_consumer "$SRC/two" call-two
mkdir -p "$FLTH_TEST_STUB/guest-repo/one" "$FLTH_TEST_STUB/guest-repo/two" "$FLTH_TEST_STUB/guest-proc"
SESSIONS="$FLTH_CACHE_DIR/machines/shared-debian-12/sessions"
GO="$SANDBOX/go"
STARTED="$SANDBOX/started"
one() { (cd "$SRC/one" && "$VM" "$@"); }
two() { (cd "$SRC/two" && "$VM" "$@"); }
downs() { stub_calls | grep -c '^down' | tr -d ' '; }
waits="touch '$STARTED'; until [ -f '$GO' ]; do /bin/sleep 0.1; done; echo finished"
wait_for_start() {
    local tries=0
    until [ -f "$STARTED" ] || [ "$tries" -ge 300 ]; do
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
}
entries() {
    local n=0 f
    for f in "$SESSIONS"/*; do [ -f "$f" ] && n=$((n + 1)); done
    printf '%s\n' "$n"
}
CALL=""
# shellcheck disable=SC2329  # the trap below calls it
cleanup() {
    : > "$GO"
    [ -z "$CALL" ] || wait "$CALL" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

one up >/dev/null 2>&1

for command in run exec; do
    rm -f "$GO" "$STARTED"
    stub_reset_calls
    one "$command" "$waits" > "$SANDBOX/out" 2>/dev/null &
    CALL=$!
    wait_for_start
    check_eq "$(entries)" 1 "a $command outside any session is on the list while it lasts"
    out="$(two down 2>&1)"
    check_eq "$?" 0 "a shutdown request during a $command succeeds"
    check_contains "$out" "left running" "and leaves the guest running"
    check_contains "$out" "call-one (pid " "naming who is using it"
    check_eq "$(downs)" 0 "and does not ask the guest to stop"
    : > "$GO"
    wait "$CALL"
    check_eq "$?" 0 "the $command finishes"
    CALL=""
    check_eq "$(cat "$SANDBOX/out")" finished "with its own output"
    check_eq "$(entries)" 0 "and leaves the list"
done

one exec 'exit 7' 2>/dev/null
check_eq "$?" 7 "a call's status is still the command's"
check_eq "$(entries)" 0 "and a failed call leaves the list too"

# A call inside a session adds nothing: the session is on the list already.
/bin/sleep 300 >/dev/null 2>&1 &
SUITE=$!
RUN="$(one run-id)"
(FLTH_RUN_ID="$RUN" one session-begin "$SUITE") 2>/dev/null
rm -f "$GO" "$STARTED"
FLTH_RUN_ID="$RUN" one exec "$waits" >/dev/null 2>&1 &
CALL=$!
wait_for_start
check_eq "$(entries)" 1 "a call inside a session adds no entry"
: > "$GO"
wait "$CALL"
CALL=""
one session-end "$SUITE" 2>/dev/null
kill -KILL "$SUITE" 2>/dev/null
wait "$SUITE" 2>/dev/null

# A CALL KILLED OUTRIGHT does not keep the guest up, and does not end the standing run.
rm -f "$GO" "$STARTED"
(cd "$SRC/one" && exec "$VM" exec "/bin/sleep 300") >/dev/null 2>&1 &
CALL=$!
tries=0
until [ "$(entries)" = 1 ] || [ "$tries" -ge 300 ]; do /bin/sleep 0.1; tries=$((tries + 1)); done
kill -KILL "$CALL"
wait "$CALL" 2>/dev/null
CALL=""
stub_reset_calls
two down >/dev/null 2>&1
check_eq "$(downs)" 1 "a shutdown request after a call was killed stops the guest"

# ONLY THE SETTING CHANGES ANY OF THIS.
stub_state absent
(cd "$SRC/one" && "$VM" up) >/dev/null 2>&1
rm -f "$GO" "$STARTED"
(cd "$SRC/one" && "$VM" exec "$waits") >/dev/null 2>&1 &
CALL=$!
wait_for_start
check_eq "$([ -d "$FLTH_CACHE_DIR/machines/call-one/sessions" ] && echo listed)" "" "with the setting off a call writes no entry"
: > "$GO"
wait "$CALL"
CALL=""

finish shared-guest-call
