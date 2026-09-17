#!/usr/bin/env bash
#
# deadline.sh — vagrant/guest/deadline.sh, the guest's own poweroff timer,
# run here against a stubbed `shutdown` and a fake /run.
#
# The defects this pins were all silent: a backgrounded `shutdown` that
# announced a timer it never set, a confirmation that read "unsupported"
# as "not armed", a knob that could not change the value.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

SCRIPT="$REPO/vagrant/guest/deadline.sh"

# run_deadline <minutes> <shutdown exit|NONE> <armed|unarmed|nosystemd> <held|free>
run_deadline() {
    local box="$SANDBOX/run$RANDOM$RANDOM"
    mkdir -p "$box/bin" "$box/run"
    sed -e "s|/run/|$box/run/|g" "$SCRIPT" > "$box/deadline.sh"
    if [ "$2" != NONE ]; then
        printf '#!/bin/sh\n[ "$1" = -c ] && exit 0\necho "$@" > "%s/args"\nexit %s\n' "$box" "$2" > "$box/bin/shutdown"
        chmod +x "$box/bin/shutdown"
    fi
    case "$3" in
        armed) mkdir -p "$box/run/systemd/system" "$box/run/systemd/shutdown"; : > "$box/run/systemd/shutdown/scheduled" ;;
        unarmed) mkdir -p "$box/run/systemd/system" ;;
    esac
    [ "$4" = held ] && : > "$box/run/fs-linux-test-harness-held"
    out="$(PATH="$box/bin:/usr/bin:/bin" bash "$box/deadline.sh" "$1" 2>&1 </dev/null)"
    rc=$?
    args="$(cat "$box/args" 2>/dev/null)"
}

grep -q '^HOLD=/run/fs-linux-test-harness-held$' "$SCRIPT"
check_eq "$?" 0 "the fixture's /run rewrite reaches the hold marker the script uses"

run_deadline 480 0 armed free
check_eq "$rc" 0 "an armed timer succeeds"
check_contains "$out" "powering off in 480 minutes unless held (timer armed)" "and says it is confirmed armed"
check_eq "$args" "-h +480" "the scheduling call carries -h and the minutes"

run_deadline 480 1 armed free
check_eq "$rc" 1 "a shutdown that cannot be scheduled fails"
check_contains "$out" "FAILED to schedule" "loudly"
check_lacks "$out" "powering off" "and does not announce a timer"

run_deadline 480 NONE armed free
check_eq "$rc" 1 "a guest with no shutdown command fails rather than reporting success"

run_deadline 480 0 unarmed free
check_eq "$rc" 1 "an accepted request logind did not record is a failure"
check_contains "$out" "logind has scheduled nothing" "saying so"

run_deadline 480 0 nosystemd free
check_eq "$rc" 0 "a guest without systemd is reported as unconfirmed, not failed"
check_contains "$out" "no systemd to confirm" "with the weaker claim spelled out"

run_deadline 480 0 armed held
check_eq "$rc" 0 "a held guest succeeds"
check_contains "$out" "no shutdown scheduled" "and schedules nothing"
check_eq "$args" "" "without calling shutdown to schedule"

for evil in "" 0 abc "480; reboot" -1 1234567 '$(id)' "048"; do
    run_deadline "$evil" 0 armed free
    check_eq "$rc" 1 "the guest refuses minutes $(printf '%q' "$evil")"
done

# mount-share.sh argument checks (the mount itself needs a guest).
out="$(bash "$REPO/vagrant/guest/mount-share.sh" 'bad tag' /share 2>&1)"
check_eq "$?" 1 "mount-share refuses a malformed tag"
out="$(bash "$REPO/vagrant/guest/mount-share.sh" flth_share relative 2>&1)"
check_eq "$?" 1 "mount-share refuses a relative mountpoint"

finish deadline
