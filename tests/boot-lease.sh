#!/usr/bin/env bash
#
# A boot attempt can last 600 seconds, far past the 180 a holder with no VM is
# trusted for. Neither its length nor the moment after it may read as an abandoned
# slot, or a rival takes the slot from a boot that is still going (#161).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness

make_consumer "$SANDBOX/booter" booter '[vm]' 'memory = "1G"'
make_consumer "$SANDBOX/rival" rival '[vm]' 'memory = "1G"'

VM="$STUB_HARNESS/scripts/vm.sh"
SLOT="$STUB_HARNESS/scripts/vm-slot.sh"
LOCK_DIR="$FLTH_STATE_DIR/slot.lock"
STUB="$FLTH_TEST_STUB"
export FLTH_SLOT_WAIT=0
export SANDBOX SLOT LOCK_DIR

holder_name() { awk -F'\t' '{print $2}' "$LOCK_DIR/holder" 2>/dev/null; }
holder_token() { awk -F'\t' '{print $4}' "$LOCK_DIR/holder" 2>/dev/null; }
free_all() {
    "$SLOT" release --force
    rm -f "$STUB/on_failed_up" "$STUB/on_force_down" "$SANDBOX/rival.rc" "$SANDBOX/rival.out"
    stub_state absent
}

# What a 610 second attempt leaves behind: a lease that old, keeping its token.
cat > "$SANDBOX/age-lease" <<'SCRIPT'
now="$(date +%s)"
awk -F'\t' -v OFS='\t' -v since="$((now - 610))" '{$3 = since; print}' "$LOCK_DIR/holder" > "$LOCK_DIR/holder.aged"
mv "$LOCK_DIR/holder.aged" "$LOCK_DIR/holder"
SCRIPT

# And a waiter that has watched no VM for all of that, with the default window.
cat > "$SANDBOX/watched-absent" <<'SCRIPT'
bash "$SANDBOX/age-lease"
now="$(date +%s)"
printf '%s\t%s\t%s\n' "$(awk -F'\t' '{print $4}' "$LOCK_DIR/holder")" "$((now - 400))" "$now" > "$LOCK_DIR/absent"
SCRIPT

# A rival that wants the slot now, with the given absence window.
cat > "$SANDBOX/rival-polls" <<'SCRIPT'
out="$(FLTH_CONFIG="$SANDBOX/rival/fs-linux-test-harness.toml" "$SLOT" acquire 2>&1)"
echo "$?" > "$SANDBOX/rival.rc"
printf '%s\n' "$out" > "$SANDBOX/rival.out"
SCRIPT

# BETWEEN TWO ATTEMPTS, TO A RIVAL THAT BREAKS AN OLD LEASE ON SIGHT. That is a
# consumer pinned to a release from before the absence window.
stub_state absent; echo 1 > "$STUB/up_failures"; stub_reset_calls
cp "$SANDBOX/age-lease" "$STUB/on_failed_up"
{ echo 'export FLTH_SLOT_ABSENT_GRACE=0'; cat "$SANDBOX/rival-polls"; } > "$STUB/on_force_down"
out="$(FLTH_CONFIG="$SANDBOX/booter/fs-linux-test-harness.toml" "$VM" up 2>&1)"
rc=$?
check_eq "$(cat "$SANDBOX/rival.rc" 2>/dev/null)" 1 "between attempts, a rival finds a renewed lease and waits"
check_lacks "$(cat "$SANDBOX/rival.out" 2>/dev/null)" 'breaking the lock' "and breaks nothing"
check_eq "$rc" 0 "the second attempt starts and the boot is an up"
check_lacks "$out" 'no memory reservation owns this boot' "it still owns its reservation"
check_eq "$(holder_name)" booter "and the slot"
free_all

# BETWEEN TWO ATTEMPTS, TO A RIVAL ON THE DEFAULT WINDOW THAT HAS ALREADY WATCHED
# NO VM FOR LONGER THAN THAT. A renewal is a restart somebody knows about.
stub_state absent; echo 1 > "$STUB/up_failures"; stub_reset_calls
cp "$SANDBOX/watched-absent" "$STUB/on_failed_up"
cp "$SANDBOX/rival-polls" "$STUB/on_force_down"
out="$(FLTH_CONFIG="$SANDBOX/booter/fs-linux-test-harness.toml" "$VM" up 2>&1)"
rc=$?
check_eq "$(cat "$SANDBOX/rival.rc" 2>/dev/null)" 1 "a rival that watched the absence also waits"
check_eq "$rc" 0 "and that boot is an up"
check_eq "$(holder_name)" booter "holding the slot"
free_all

# DURING AN ATTEMPT, BEFORE ITS VM EXISTS. A first boot downloads the box and a
# loaded host can take minutes to reach QEMU: nothing is running, and the process
# that will start it is alive.
stub_state absent; stub_reset_calls
: > "$STUB/gate_up"
export FLTH_SLOT_RENEW_SECS=1
FLTH_CONFIG="$SANDBOX/booter/fs-linux-test-harness.toml" "$VM" up > "$SANDBOX/live.out" 2>&1 &
booter=$!
waits=0
while [ ! -f "$STUB/gate_up.reached" ] && [ "$waits" -lt 1200 ]; do
    /bin/sleep 0.1
    waits=$((waits + 1))
done
check_eq "$([ -f "$STUB/gate_up.reached" ] && echo reached)" reached "a boot reaches the long part of its attempt"
bash "$SANDBOX/age-lease"
aged="$(holder_token)"
waits=0
while [ "$(holder_token)" = "$aged" ] && [ "$waits" -lt 300 ]; do
    /bin/sleep 0.1
    waits=$((waits + 1))
done
check_eq "$([ "$(holder_token)" != "$aged" ] && echo renewed)" renewed "a live attempt renews its own lease"
FLTH_SLOT_ABSENT_GRACE=0 bash "$SANDBOX/rival-polls"
check_eq "$(cat "$SANDBOX/rival.rc")" 1 "so a rival cannot take the slot from a boot still going"
check_eq "$(holder_name)" booter "and it stays with the boot"
rm -f "$STUB/gate_up"
wait "$booter"
check_eq "$?" 0 "the boot finishes as an up"
unset FLTH_SLOT_RENEW_SECS

# ONCE THE BOOT HAS ENDED, NOTHING RENEWS FOR IT. A lease that stays renewed for a
# process that has gone would hold the slot for ever.
token="$(holder_token)"
/bin/sleep 3
check_eq "$(holder_token)" "$token" "nothing renews the lease once the attempt has ended"
free_all

finish boot-lease
