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
    sed -e "s|/run/|$box/run/|g" -e "s|/etc/pam.d/|$box/pam.d/|g" "$SCRIPT" > "$box/deadline.sh"
    if [ -n "${SSHD_PAM-$SSHD_PAM_DEBIAN}" ]; then
        mkdir -p "$box/pam.d"
        printf '%s\n' "${SSHD_PAM-$SSHD_PAM_DEBIAN}" > "$box/pam.d/sshd"
    fi
    if [ -n "${SED_FAILS:-}" ]; then
        printf '#!/bin/sh\nexit 1\n' > "$box/bin/sed"
        chmod +x "$box/bin/sed"
    fi
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
    pam="$(cat "$box/pam.d/sshd" 2>/dev/null)"
    pam_exists=no
    [ ! -e "$box/pam.d/sshd" ] || pam_exists=yes
}

# The lines that decide a login, as Debian ships them in /etc/pam.d/sshd.
SSHD_PAM_DEBIAN='# Disallow non-root logins when /etc/nologin exists.
account    required     pam_nologin.so

# Standard Un*x authorization.
@include common-account'
nologin_rule() { printf '%s\n' "$1" | grep -E '^[[:space:]]*account[[:space:]].*pam_nologin'; }

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

# --- the guest takes logins until it powers off (#150) --------------------

# logind writes /run/nologin five minutes before a scheduled poweroff, or at once
# when less than that is left, and pam_nologin in sshd's account stack then refuses
# the harness's own user. tests/smoke.sh holds this against a real logind and sshd.
grep -q '/etc/pam\.d/sshd' "$SCRIPT"
check_eq "$?" 0 "the fixture's /etc/pam.d rewrite reaches the file the script edits, and never the host's"

run_deadline 5 0 armed free
check_eq "$rc" 0 "a five-minute deadline succeeds"
check_eq "$args" "-h +5" "and still schedules the poweroff"
check_eq "$(nologin_rule "$pam")" "" "sshd's account stack no longer consults pam_nologin"
check_contains "$pam" "@include common-account" "and keeps the rest of its account stack"
check_contains "$pam" "# Disallow non-root logins" "and its comments"
check_contains "$pam" "pam_nologin.so" "and the rule stays in the file, commented, for someone reading the guest"

first="$pam"
SSHD_PAM="$first" run_deadline 5 0 armed free
check_eq "$pam" "$first" "the next boot of the same disk changes nothing further"

run_deadline 480 0 armed free
check_eq "$(nologin_rule "$pam")" "" "a long deadline has the same last five minutes"

SSHD_PAM='' run_deadline 5 0 armed free
check_eq "$rc" 0 "an sshd with no PAM stack has nothing to change"
check_eq "$pam_exists" no "and none is created"

run_deadline 5 0 armed held
check_eq "$pam" "$SSHD_PAM_DEBIAN" "a held guest schedules nothing, so nothing will refuse a login"

SED_FAILS=1 run_deadline 5 0 armed free
check_eq "$rc" 0 "a PAM file that cannot be changed does not fail the boot"
check_eq "$args" "-h +5" "the deadline is still armed: it is what stops a lost VM"
check_contains "$out" "new logins stop five minutes before the poweroff" "and the boot says what that costs"
check_eq "$pam" "$SSHD_PAM_DEBIAN" "and the file is left as it was"

finish deadline
