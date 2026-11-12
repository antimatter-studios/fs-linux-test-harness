#!/usr/bin/env bash
#
# Re-arming is limited to once in a window, and a call inside that window leaves
# the poweroff where it was. The window has to fit inside the deadline: at one
# minute a call 59 seconds after the last re-arm found the stamp in its window,
# and the guest powered off one second into it (#152).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
STUB="$FLTH_TEST_STUB"
C="$SANDBOX/consumer"

rearms() { grep -c "^shutdown --no-wall -h +$1\$" "$STUB/calls" | tr -d ' '; }
# A call into a guest last re-armed this many seconds ago.
call_after() {
    printf '%s\n' "$(( $(date +%s) - $1 ))" > "$STUB/guest-rearmed"
    stub_reset_calls
    (cd "$C" && "$VM" exec true) 2>/dev/null
}

# The shared guest's deadline is the host's to set, not a consumer's (#220).
consumer_with() {
    make_consumer "$C" deadline-window
    export FLTH_SHARED_DEADLINE="$1"
    (cd "$C" && "$VM" up) >/dev/null 2>&1
}

consumer_with 1
stub_state running
# A loaded host can take longer than this window over one call, and the call then
# re-arms again as it ends, so these count at least one.
moved() { [ "$(rearms "$1")" -ge 1 ] && echo moved; }
call_after 30
check_eq "$(moved 1)" moved "at one minute, a call half a minute after the last re-arm moves the poweroff"
call_after 59
check_eq "$(moved 1)" moved "and so does a call one second before it"
# A stamp ahead of the clock is inside any window however long the call takes.
echo $(( $(date +%s) + 3600 )) > "$STUB/guest-rearmed"
stub_reset_calls
(cd "$C" && "$VM" exec true) 2>/dev/null
check_eq "$(rearms 1)" 0 "a window is still kept: a call right after a re-arm calls logind no more"
(cd "$C" && "$VM" down) >/dev/null 2>&1

consumer_with 2
stub_state running
call_after 40
check_eq "$(moved 2)" moved "at two minutes the window is a sixth of it as well"
(cd "$C" && "$VM" down) >/dev/null 2>&1

# Nothing changes for a deadline long enough to hold the whole minute.
consumer_with 480
stub_state running
call_after 45
check_eq "$(rearms 480)" 0 "at eight hours a call inside the minute does not call logind"
call_after 70
check_eq "$(moved 480)" moved "and one past the minute does"
(cd "$C" && "$VM" down) >/dev/null 2>&1

finish deadline-window
