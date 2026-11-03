#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_consumer "$SANDBOX/consumer" reboot-slot '[vm]' 'memory = "4G"'
export FLTH_CONFIG="$SANDBOX/consumer/fs-linux-test-harness.toml"
SLOT_SCRIPT="${FLTH_TEST_SLOT_SCRIPT:-$REPO/scripts/vm-slot.sh}"
"$SLOT_SCRIPT" acquire
check_eq "$?" 0 "a consumer reserves its initial boot"
holder="$FLTH_STATE_DIR/slot.lock/holder"
old_record="$(cat "$holder")"
old_token="$(printf '%s\n' "$old_record" | awk -F'\t' '{print $4}')"
identity="$(printf '%s\n' "$old_record" | awk -F'\t' '{print $1}')"
printf '%s\t%s\t%s\t%s\n' "$identity" reboot-slot "$(( $(date +%s) - 86400 ))" "$old_token" > "$holder"
"$SLOT_SCRIPT" check-memory
check_eq "$?" 0 "the next boot checks memory while retaining its reservation"
new_token="$(awk -F'\t' '{print $4}' "$holder")"
epoch="$(awk -F'\t' '{print $3}' "$holder")"
check_eq "$([ "$new_token" != "$old_token" ] && echo renewed || echo stale)" renewed "a reboot invalidates the token a stale waiter inspected"
check_eq "$([ "$(( $(date +%s) - epoch ))" -le 180 ] && echo fresh || echo expired)" fresh "a long provisioning run gets a fresh boot grace before rebooting"
export FLTH_SLOT_LIB=1
# shellcheck source=../scripts/vm-slot.sh
. "$SLOT_SCRIPT"
set +e
delete_generation "$old_token" breaking
check_eq "$?" 1 "the pre-reboot token cannot free the renewed reservation"
check_eq "$([ -d "$FLTH_STATE_DIR/slot.lock" ] && echo held || echo free)" held "the reboot keeps its counted slot against a stale waiter"
finish slot-reboot
