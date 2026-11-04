#!/usr/bin/env bash
#
# shared-guest.sh — FLTH_SHARED_ROOT: one guest several suites use at once
# (#153). The list of suites using it decides when it may stop: a suite registers
# when its session begins and deregisters when it ends, and a shutdown request
# stops the guest only when the list is empty. A suite that died is dropped from
# the list, because it never deregisters.
#
# The real guest is held to this by tests/smoke.sh and by the run recorded in the
# pull request. Here the stub engine says what the VM does.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
# `sleep` is stubbed, so a wait for the slot would spin. Nothing here should wait.
export FLTH_SLOT_WAIT=0
VM="$STUB_HARNESS/scripts/vm.sh"
SLOT="$STUB_HARNESS/scripts/vm-slot.sh"
MACHINE="$FLTH_CACHE_DIR/machines/shared-debian-12"

SRC="$(cd "$SANDBOX" && pwd -P)/src"
make_consumer "$SRC/one" shared-one
make_consumer "$SRC/two" shared-two

# Calls that opted in, from each consumer's directory.
one() { (cd "$SRC/one" && FLTH_SHARED_ROOT="$SRC" "$VM" "$@"); }
two() { (cd "$SRC/two" && FLTH_SHARED_ROOT="$SRC" "$VM" "$@"); }

# A live process to stand in for a suite's session, and its end.
suite() {
    /bin/sleep 300 >/dev/null 2>&1 &
    SUITE=$!
}
end_suite() {
    kill -KILL "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}
suites=""
# shellcheck disable=SC2329  # the trap below calls it
cleanup() {
    local pid
    for pid in $suites; do kill -KILL "$pid" 2>/dev/null; done
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

downs() { stub_calls | grep -c '^down' | tr -d ' '; }

one up >/dev/null 2>&1
check_eq "$?" 0 "a suite that opted in boots"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "the guest is up"
check_eq "$([ -d "$MACHINE" ] && echo one)" one "on the one machine every consumer that opted in shares"
check_eq "$([ -e "$FLTH_CACHE_DIR/machines/shared-one" ] && echo own)" "" "and not on a machine of its own"
check_contains "$(two config)" "vm.memory=8G" "the shared machine's memory is its own, not a consumer's"
check_contains "$(FLTH_SHARED_MEMORY=12G two config)" "vm.memory=12G" "and a host can change it"

suite; A=$SUITE; suites="$suites $A"
suite; B=$SUITE; suites="$suites $B"
one session-begin "$A" 2>/dev/null
check_eq "$?" 0 "the first suite registers"
two session-begin "$B" 2>/dev/null
check_eq "$?" 0 "the second suite registers"

status="$(one status 2>&1)"
check_contains "$status" "shared-one (pid $A)" "status names the first suite"
check_contains "$status" "shared-two (pid $B)" "status names the second suite"

stub_reset_calls
out="$(one down 2>&1)"
check_eq "$?" 0 "a shutdown request while suites are registered succeeds"
check_contains "$out" "left running" "and says the guest is left running"
check_contains "$out" "shared-one (pid $A)" "naming the first suite"
check_contains "$out" "shared-two (pid $B)" "naming the second suite"
check_eq "$(downs)" 0 "and does not ask the guest to stop"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "the guest stays up"

out="$(one reap 2>&1)"
check_eq "$?" 0 "a reap while suites are registered succeeds"
check_eq "$(downs)" 0 "and does not ask the guest to stop"

out="$(two destroy 2>&1)"
check_eq "$?" 1 "a destroy while suites are registered is refused"
check_contains "$out" "shared-one (pid $A)" "naming the suites"
check_eq "$(stub_calls | grep -c '^destroy' | tr -d ' ')" 0 "and destroys nothing"

two session-end "$B" 2>/dev/null
check_eq "$?" 0 "a suite that finishes deregisters"
check_eq "$(downs)" 0 "and leaves the guest up for the other"
check_lacks "$(one status 2>&1)" "shared-two" "and is off the list"
one session-end "$A" 2>/dev/null
check_eq "$?" 0 "the last suite deregisters"
check_eq "$(downs)" 0 "and leaves the guest up too: it is there for the next run"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "the guest is still up with nobody on the list"

out="$(one reap 2>&1)"
check_eq "$?" 0 "a reap of an idle shared guest succeeds"
check_eq "$(downs)" 0 "and leaves it: an idle shared guest is not a leak"
check_contains "$out" "left running" "and says so"
check_contains "$("$SLOT" status 2>&1)" "held by" "the slot stays held while it is up"

out="$(two down 2>&1)"
check_eq "$?" 0 "a shutdown request with an empty list succeeds"
check_eq "$(downs)" 1 "and asks the guest to stop"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "the guest stops"
check_contains "$("$SLOT" status 2>&1)" "free" "and the slot is released"

# A SUITE KILLED OUTRIGHT never deregisters, and must not keep the guest up.
one up >/dev/null 2>&1
suite; A=$SUITE; suites="$suites $A"
suite; B=$SUITE; suites="$suites $B"
one session-begin "$A" 2>/dev/null
two session-begin "$B" 2>/dev/null
stub_reset_calls
end_suite "$A"
out="$(two down 2>&1)"
check_eq "$(downs)" 0 "a shutdown request with one suite dead and one alive leaves the guest up"
check_contains "$out" "shared-two (pid $B)" "naming the live one"
check_lacks "$out" "shared-one" "and not the dead one"
end_suite "$B"
two down >/dev/null 2>&1
check_eq "$(downs)" 1 "a shutdown request after both were killed stops the guest"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "so a SIGKILL does not keep it up"

# A pid the system has handed to something else is not the suite it was.
one up >/dev/null 2>&1
suite; A=$SUITE; suites="$suites $A"
one session-begin "$A" 2>/dev/null
marker="$MACHINE/sessions/$A"
check_eq "$(cut -f1 "$marker")" "$A" "the entry records the owner's pid"
check_eq "$(cut -f3 "$marker")" shared-one "and which suite it is"
printf '%s\tMon Jan  1 00:00:00 2001\tshared-one\n' "$A" > "$marker"
stub_reset_calls
one down >/dev/null 2>&1
check_eq "$(downs)" 1 "an entry whose pid now names another process does not keep the guest up"
end_suite "$A"

# REGISTERING AND THE SHUTDOWN CHECK TAKE THE SAME LOCK. A suite that registers
# during a shutdown waits for it, and then boots a new guest.
one up >/dev/null 2>&1
: > "$FLTH_TEST_STUB/gate_down"
one down >/dev/null 2>&1 &
stopper=$!
tries=0
until [ -f "$FLTH_TEST_STUB/gate_down.reached" ] || [ "$tries" -ge 100 ]; do
    /bin/sleep 0.1
    tries=$((tries + 1))
done
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "the shutdown has stopped the guest and not finished"
suite; A=$SUITE; suites="$suites $A"
two session-begin "$A" 2>/dev/null &
joiner=$!
/bin/sleep 1
check_eq "$(kill -0 "$joiner" 2>/dev/null && echo waiting)" waiting "a suite registering during the shutdown waits for it"
rm -f "$FLTH_TEST_STUB/gate_down"
wait "$stopper"
check_eq "$?" 0 "the shutdown finishes"
wait "$joiner"
check_eq "$?" 0 "and then the suite registers"
check_eq "$([ -f "$MACHINE/sessions/$A" ] && echo registered)" registered "and is on the list"
two up >/dev/null 2>&1
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "and boots a new guest"
two session-end "$A" 2>/dev/null
end_suite "$A"
two down >/dev/null 2>&1

# A GUEST THAT STOPPED ITSELF has nothing to halt, so the last suite gives its
# slot back.
one up >/dev/null 2>&1
suite; A=$SUITE; suites="$suites $A"
one session-begin "$A" 2>/dev/null
stub_state stopped
stub_reset_calls
one session-end "$A" 2>/dev/null
check_eq "$?" 0 "the last suite of a guest that stopped itself ends cleanly"
check_contains "$("$SLOT" status 2>&1)" "free" "and gives the slot back"
end_suite "$A"

# THE SETTING ITSELF.
out="$(cd "$SRC/one" && FLTH_SHARED_ROOT=relative/path "$VM" status 2>&1)"
check_eq "$?" 1 "a relative FLTH_SHARED_ROOT is refused"
check_contains "$out" "FLTH_SHARED_ROOT must be an absolute path" "naming the setting"
out="$(cd "$SRC/one" && FLTH_SHARED_ROOT="$SRC/with,comma" "$VM" status 2>&1)"
check_eq "$?" 1 "a path the VM cannot share is refused"

# A CONSUMER THAT DOES NOT OPT IN keeps today's behaviour.
stub_state absent
(cd "$SRC/one" && "$VM" up) >/dev/null 2>&1
suite; A=$SUITE; suites="$suites $A"
(cd "$SRC/one" && "$VM" session-begin "$A") 2>/dev/null
marker="$FLTH_CACHE_DIR/machines/shared-one/sessions/$A"
check_eq "$(awk -F'\t' '{print NF}' "$marker")" 2 "with the setting off the entry is what it was"
stub_reset_calls
(cd "$SRC/one" && "$VM" session-end "$A") >/dev/null 2>&1
check_eq "$(downs)" 1 "with the setting off the last session stops the guest"
end_suite "$A"

finish shared-guest
