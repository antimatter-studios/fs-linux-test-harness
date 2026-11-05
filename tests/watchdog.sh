#!/usr/bin/env bash
#
# A watchdog stopped early must do nothing. A KILL to its group can reach its
# `sleep` first, and the shell then wakes before its own KILL arrives and runs the
# next line. Measured on arm64 macOS under Bash 3.2.57: that line ran in 1 of 400
# stops, and a session that took 0 seconds was reported as timed out (#158).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
FILE="$SANDBOX/timeout"

target_group() {
    set -m
    /bin/sleep 300 &
    TARGET=$!
    set +m
}
target_alive() { kill -0 -- "-$TARGET" 2>/dev/null && echo alive; }

# The race's outcome made certain: only the sleep goes, so the shell always wakes.
target_group
start_watchdog 300 "$FILE" "$TARGET"
tries=0
until pkill -KILL -P "$WATCHDOG" 2>/dev/null || [ "$tries" -ge 100 ]; do
    /bin/sleep 0.1
    tries=$((tries + 1))
done
wait "$WATCHDOG" 2>/dev/null
check_eq "$([ -e "$FILE" ] && echo written)" "" "a watchdog whose wait is cut short writes nothing"
check_eq "$(target_alive)" alive "and stops nothing"
kill -KILL -- "-$TARGET" 2>/dev/null
{ wait "$TARGET"; } 2>/dev/null
rm -f "$FILE"

# A watchdog that runs out still does its job, or it is no bound at all.
target_group
start_watchdog 1 "$FILE" "$TARGET"
{ wait "$WATCHDOG"; } 2>/dev/null
check_eq "$(cat "$FILE" 2>/dev/null)" timeout "a watchdog that runs out says so"
{ wait "$TARGET"; } 2>/dev/null
check_eq "$(target_alive)" "" "and stops the group"

finish watchdog
