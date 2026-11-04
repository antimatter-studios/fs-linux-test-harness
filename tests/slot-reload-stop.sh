#!/usr/bin/env bash
#
# `vm.sh reload` renews before it stops the VM, not only before it boots again:
# a stop can take a minute, and a rival must not find an old lease and no VM
# while it finishes. Held at the stop, so the renewal before the boot has not run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
make_consumer "$SANDBOX/reloader" reloading
make_consumer "$SANDBOX/rival" rival
export FLTH_SLOT_WAIT=0
SLOT="$STUB_HARNESS/scripts/vm-slot.sh"
VM="$STUB_HARNESS/scripts/vm.sh"
ONE="$FLTH_STATE_DIR/slot.lock"
STUB="$FLTH_TEST_STUB"
export FLTH_CONFIG="$SANDBOX/reloader/fs-linux-test-harness.toml"

"$VM" up 2>/dev/null
check_eq "$?" 0 "the VM boots"
awk -F'\t' -v OFS='\t' '{$3 = $3 - 86400; print}' "$ONE/holder" > "$ONE/holder.aged"
mv "$ONE/holder.aged" "$ONE/holder"

: > "$STUB/gate_down"
"$VM" reload > "$SANDBOX/reload.log" 2>&1 &
reload_pid=$!
tries=0
while [ ! -f "$STUB/gate_down.reached" ] && [ "$tries" -lt 600 ] && kill -0 "$reload_pid" 2>/dev/null; do
    /bin/sleep 0.1
    tries=$((tries + 1))
done
check_eq "$([ -f "$STUB/gate_down.reached" ] && echo reached || echo missed)" reached "the reload reaches its stop"
check_eq "$(cat "$STUB/state")" stopped "no engine process exists"
FLTH_CONFIG="$SANDBOX/rival/fs-linux-test-harness.toml" "$SLOT" acquire 2>/dev/null
check_eq "$?" 1 "a rival racing the stop does not get the slot"
check_eq "$(awk -F'\t' '{print $2}' "$ONE/holder")" reloading "the reload keeps it"
rm -f "$STUB/gate_down"
wait "$reload_pid"
check_eq "$?" 0 "the reload completes"
check_eq "$(cat "$STUB/state")" running "and the VM is back"

finish slot-reload-stop
