#!/usr/bin/env bash
#
# runtime-attach.sh — each run attaches its own tree to the running shared guest,
# and detaches it when it ends (#222). There is no boot-time root: a tree anywhere
# on the host joins the guest, and FLTH_SHARED_ROOT is not read.
#
# What is pinned against the stub engine, which records attach and detach as calls
# and runs the guest's side here with its mount tools logging:
#   - two consumers in unrelated directories both run on one guest, each run with
#     its own device, mounted over /repo in the run's namespace;
#   - a session's end ends its run in the guest BEFORE its device is detached,
#     because a virtiofsd that goes while the guest can still use its mount wedges
#     every hot-plug in the guest until it reboots;
#   - a device left by a run whose session died is detached by the reaper;
#   - a run whose virtiofsd died has its device removed before anything else runs
#     in it, and the call that found it fails, saying why.
# tests/smoke.sh holds a real guest to it, on KVM in CI.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
BOX="$(cd "$SANDBOX" && pwd -P)"
TOOLS="$FLTH_TEST_STUB/guest-tools"
CALLS="$FLTH_TEST_STUB/calls"

ONE="$BOX/here/one"
TWO="$BOX/somewhere/else/entirely/two"
make_consumer "$ONE" attach-one
make_consumer "$TWO" attach-two

standing() { (cd "$1" && FLTH_RUN_ID='' "$VM" config | sed -n 's/^run.standing=//p'); }

# --- two trees with nothing in common join one guest --------------------------

(cd "$ONE" && "$VM" up) >/dev/null 2>"$SANDBOX/one.err"
check_eq "$?" 0 "a consumer boots the shared guest ($(tail -n 1 "$SANDBOX/one.err"))"
(cd "$TWO" && "$VM" up) >/dev/null 2>"$SANDBOX/two.err"
check_eq "$?" 0 "and a consumer in an unrelated directory joins it ($(tail -n 1 "$SANDBOX/two.err"))"
check_eq "$(grep -c '^up$' "$CALLS" | tr -d ' ')" 1 "one boot serves both"
one_run="$(standing "$ONE")"
two_run="$(standing "$TWO")"
check_contains "$(cat "$CALLS")" "attach $one_run $ONE" "the first consumer's tree is attached as a device of its own"
check_contains "$(cat "$CALLS")" "attach $two_run $TWO" "and so is the second's"
: > "$TOOLS"
(cd "$TWO" && "$VM" exec true) >/dev/null 2>&1
check_contains "$(cat "$TOOLS")" "mount -t virtiofs $two_run $FLTH_TEST_STUB/guest-repo" \
    "a run mounts its own device over /repo in its namespace"
check_lacks "$(cd "$ONE" && "$VM" config)" "shared.root" "config names no shared root: there is none"
(cd "$ONE" && FLTH_SHARED_ROOT=/nowhere/at/all "$VM" exec true) >/dev/null 2>&1
check_eq "$?" 0 "FLTH_SHARED_ROOT is not read"

# --- a session's run is attached for the session and detached after it --------

: > "$CALLS"
(cd "$ONE" && "$VM" session bash -c '"$1" run true' flth-test "$VM") >/dev/null 2>"$SANDBOX/session.err"
check_eq "$?" 0 "a session's call runs ($(tail -n 1 "$SANDBOX/session.err"))"
session_run="$(sed -n 's/^attach \([^ ]*\) .*/\1/p' "$CALLS" | grep -v -e "$one_run" | head -n 1)"
check_contains "$session_run" "-" "the session's run is attached under a run id of its own"
check_contains "$(cat "$CALLS")" "detach $session_run" "and detached when the session ends"
end_at="$(grep -n "run.sh end $session_run" "$FLTH_TEST_STUB/scripts" | head -n 1 | cut -d: -f1)"
order="$(grep -nE "^(run|detach $session_run)$" "$CALLS" | tail -n 2 | sed 's/^[0-9]*://' | paste -sd, -)"
check_eq "$([ -n "$end_at" ] && echo ended)" ended "the run is ended in the guest"
check_eq "$order" "run,detach $session_run" "before its device is detached, never after"

# --- a device whose run has no session any more --------------------------------

: > "$CALLS"
mkdir -p "$FLTH_TEST_STUB/attached"
printf '%s\n' "$BOX/gone" > "$FLTH_TEST_STUB/attached/feedface-0123456789abcdef"
(cd "$ONE" && "$VM" reap) >/dev/null 2>&1
check_contains "$(cat "$CALLS")" "detach feedface-0123456789abcdef" "reap detaches a device whose run has no live session"
check_lacks "$(cat "$CALLS")" "detach $one_run" "and leaves a standing run's"

# --- a run whose virtiofsd died ------------------------------------------------

: > "$CALLS"
: > "$FLTH_TEST_STUB/scripts"
: > "$FLTH_TEST_STUB/daemon-dead.$two_run"
out="$(cd "$TWO" && "$VM" exec true 2>&1)"
rc=$?
check_eq "$rc" 75 "a call into a run whose virtiofsd died fails with the interrupted status"
check_contains "$out" "virtiofsd" "naming the daemon that died"
check_contains "$(cat "$CALLS")" "detach $two_run" "its device is detached"
check_lacks "$(cat "$FLTH_TEST_STUB/scripts")" "echo true" "and nothing else ran in that run first"
rm -f "$FLTH_TEST_STUB/daemon-dead.$two_run"
(cd "$TWO" && "$VM" exec 'echo again') >/dev/null 2>&1
check_eq "$?" 0 "the next call attaches the tree again"

# --- the watchdog finds a run's virtiofsd gone (vm-watchdog.sh, look_at_trees) ----

# A session whose command waits, on a run with its tree attached.
GO="$SANDBOX/go"
(cd "$ONE" && exec "$VM" session bash -c '"$1" run true && touch "$2.started" && until [ -f "$2" ]; do /bin/sleep 0.1; done' \
    flth-test "$VM" "$GO") >/dev/null 2>"$SANDBOX/lost.err" &
lost_session=$!
ticks=0
until [ -f "$GO.started" ] || [ "$ticks" -ge 300 ]; do /bin/sleep 0.1; ticks=$((ticks + 1)); done
lost_run="$(cut -f4 "$FLTH_CACHE_DIR/machines/shared-debian-12/sessions/$lost_session" 2>/dev/null)"
check_contains "$lost_run" "-" "a session's run has its tree attached"
: > "$CALLS"
: > "$FLTH_TEST_STUB/daemon-dead.$lost_run"
(cd "$ONE" && "$VM" tree-lost "$lost_run") >/dev/null 2>&1
wait "$lost_session"
check_eq "$?" 75 "the session whose tree's daemon went ends with the interrupted status"
check_contains "$(cat "$SANDBOX/lost.err")" "has gone" "saying why"
order="$(grep -nE "^(run|detach $lost_run)$" "$CALLS" | head -n 2 | sed 's/^[0-9]*://' | paste -sd, -)"
check_eq "$order" "detach $lost_run,run" "its device was removed before anything ran in the guest"
: > "$GO"
rm -f "$FLTH_TEST_STUB/daemon-dead.$lost_run"

finish runtime-attach
