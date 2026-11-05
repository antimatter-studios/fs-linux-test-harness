#!/usr/bin/env bash
#
# A test's stand-in for QEMU starts a session of its own, as the real one does, so
# no signal to the test reaches it. A run stopped from outside must still leave
# nothing on the host: the stand-ins end when the test does, and in any case within
# an hour.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
ROOT="$(mktemp -d "${FLTH_TEST_SOCKET_ROOT:-/tmp}/flthq.XXXXXX")" || exit 1
# shellcheck disable=SC2064  # expand now: the paths are fixed
trap "rm -rf '$SANDBOX' '$ROOT'" EXIT

# By the name a stand-in runs under, not by matching text anywhere on the line:
# this awk's own command line holds both the name and the path, and it is in the
# listing on a host that starts it before `ps` reads the process table.
stand_ins() {
    ps -axo pid=,args= | awk -v want="$ROOT/" '$2 == "qemu-system-stub" && index($0, want) > 0 { print $1 }'
}
wait_for_stand_in() {
    local tries=0
    while [ -z "$(stand_ins)" ] && [ "$tries" -lt 1200 ]; do
        /bin/sleep 0.25
        tries=$((tries + 1))
    done
    [ -n "$(stand_ins)" ]
}
wait_for_none() {
    local tries=0
    while [ -n "$(stand_ins)" ] && [ "$tries" -lt 240 ]; do
        /bin/sleep 0.25
        tries=$((tries + 1))
    done
    [ -z "$(stand_ins)" ]
}

# The test that left one behind, signalled as a person or a job limit would.
set -m
FLTH_TEST_SOCKET_ROOT="$ROOT" bash "$REPO/tests/session-boot-signal.sh" > "$SANDBOX/log" 2>&1 &
run=$!
set +m
if wait_for_stand_in; then
    ok "the test under it has a stand-in running"
else
    bad "the test never started a stand-in, so this says nothing ($(tail -n 3 "$SANDBOX/log"))"
fi
kill -TERM -- "-$run" 2>/dev/null
{ wait "$run"; } 2>/dev/null
if wait_for_none; then
    ok "a run stopped from outside leaves no stand-in running"
else
    bad "a run stopped from outside left a stand-in running: $(stand_ins | tr '\n' ' ')"
fi
for pid in $(stand_ins); do kill -KILL "$pid" 2>/dev/null; done

# Every stand-in, whichever test starts it, has an end of its own.
endless="$(grep -l 'qemu-system-stub.*while :' "$REPO"/tests/*.sh 2>/dev/null | grep -v stub-qemu-leak)"
check_eq "$endless" "" "no test starts a stand-in that loops for ever"

finish stub-qemu-leak
