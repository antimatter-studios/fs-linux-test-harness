#!/usr/bin/env bash
#
# deadline.sh <minutes> — schedule this guest's own poweroff. Runs as root
# in the guest on every boot.
#
# The hold marker lives in /run, so it lasts exactly as long as the boot
# it was granted on: a halt and restart re-arms the deadline instead of
# inheriting an exemption nobody remembers granting.
set -euo pipefail

MINS="${1:-}"
HOLD=/run/fs-linux-test-harness-held

# Validated again here, although the Vagrantfile validated it: this is a
# root shell, and the check costs one line.
case "$MINS" in
    '' | *[!0-9]* | 0*) echo "deadline: minutes must be a positive integer, got '$MINS'" >&2; exit 1 ;;
esac
[ "${#MINS}" -le 6 ] || { echo "deadline: at most six digits, got '$MINS'" >&2; exit 1; }

# Cancel first, so a re-provision cannot stack two timers.
shutdown -c >/dev/null 2>&1 || true

if [ -f "$HOLD" ]; then
    echo "deadline: held by $HOLD, no shutdown scheduled"
    exit 0
fi

# NOT BACKGROUNDED, AND ITS STATUS IS READ. `nohup shutdown ... &` put the
# one call this exists to make out of `set -e`'s reach and announced a
# timer that may never have been set. shutdown returns once it is armed.
if ! shutdown -h "+${MINS}"; then
    echo "deadline: FAILED to schedule poweroff in ${MINS} minutes" >&2
    exit 1
fi

# CONFIRMED FROM LOGIND'S OWN RECORD, where there is one. logind writes
# /run/systemd/shutdown/scheduled when a shutdown is scheduled; its
# absence is a real answer only where systemd runs, which
# /run/systemd/system tells us. (`systemctl show -p ScheduledShutdownUSec`
# is not that answer: it exits 0 and prints nothing for a property it
# does not know.)
if [ -d /run/systemd/system ]; then
    if [ -r /run/systemd/shutdown/scheduled ]; then
        echo "deadline: powering off in ${MINS} minutes unless held (timer armed)"
    else
        echo "deadline: shutdown returned 0 but logind has scheduled nothing" >&2
        exit 1
    fi
else
    echo "deadline: powering off in ${MINS} minutes unless held (request accepted, no systemd to confirm)"
fi
