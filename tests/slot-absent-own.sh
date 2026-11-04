#!/usr/bin/env bash
#
# The absence window protects a holder from rivals. It must not make a consumer
# wait on its own old record when its own VM is down, and it is the default.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
unset FLTH_SLOT_ABSENT_GRACE
make_consumer "$SANDBOX/own" own '[vm]' 'memory = "1G"'
make_consumer "$SANDBOX/rival" rival '[vm]' 'memory = "1G"'
export FLTH_SLOT_WAIT=0
SLOT="$STUB_HARNESS/scripts/vm-slot.sh"
LOCK_DIR="$FLTH_STATE_DIR/slot.lock"

FLTH_CONFIG="$SANDBOX/own/fs-linux-test-harness.toml" "$SLOT" acquire
check_eq "$?" 0 "a consumer takes the slot"
awk -F'\t' -v OFS='\t' '{$3 = $3 - 86400; print}' "$LOCK_DIR/holder" > "$LOCK_DIR/holder.aged"
mv "$LOCK_DIR/holder.aged" "$LOCK_DIR/holder"
stub_state stopped
aged_token="$(awk -F'\t' '{print $4}' "$LOCK_DIR/holder")"

FLTH_CONFIG="$SANDBOX/rival/fs-linux-test-harness.toml" "$SLOT" acquire 2>/dev/null
check_eq "$?" 1 "a rival waits out the window"
out="$(FLTH_CONFIG="$SANDBOX/own/fs-linux-test-harness.toml" "$SLOT" acquire 2>&1)"
check_eq "$?" 0 "the consumer's own record past its grace does not make it wait"
check_contains "$out" 'breaking the lock' "and it replaces the record"
check_eq "$([ "$(awk -F'\t' '{print $4}' "$LOCK_DIR/holder")" != "$aged_token" ] && echo new || echo same)" new \
    "a new generation holds the slot"

finish slot-absent-own
