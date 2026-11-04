#!/usr/bin/env bash
#
# slot-memory-unrecorded.sh -- memory admission beside a holder that wrote no
# `memory` file, as a harness before v0.5.5 does (#114).
#
# Consumers move their pins one at a time, so old and new holders share one
# state directory during a move. Such a holder's allocation cannot be known,
# and while it may still be booting its guest is not yet in available memory.
# An acquire waits until the holder settles or goes; only a reservation that
# is present and malformed is refused.
#
# The real script runs as its own process with the stub engine. `sleep` is a
# stub that runs $FLTH_TEST_STUB/on_sleep, which is how a wait sees the other
# holder change.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
make_consumer "$SANDBOX/new" new-pin '[vm]' 'memory = "2G"'
export FLTH_CONFIG="$SANDBOX/new/fs-linux-test-harness.toml"
export FLTH_SLOT_COUNT=2

printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$SANDBOX/memory-bin/uname"
cat > "$FLTH_TEST_STUB/bin/sleep" <<'STUB'
#!/bin/sh
if [ -f "$FLTH_TEST_STUB/on_sleep" ]; then
    sh "$FLTH_TEST_STUB/on_sleep"
fi
exit 0
STUB
chmod +x "$SANDBOX/memory-bin/uname" "$FLTH_TEST_STUB/bin/sleep"
hash -r

SLOT="$STUB_HARNESS/scripts/vm-slot.sh"
ONE="$FLTH_STATE_DIR/slot.lock"
TWO="$FLTH_STATE_DIR/slot-2.lock"
ON_SLEEP="$FLTH_TEST_STUB/on_sleep"

# old_holder <lock> <age seconds>: a holder record with no `memory` file.
old_holder() {
    mkdir -p "$1"
    printf '%s\t%s\t%s\t%s\n' /old/machine old-pin "$(( $(date +%s) - $2 ))" old-token > "$1/holder"
}

held() { if [ -d "$1" ]; then echo held; else echo free; fi; }

reset_state() {
    clear_lock "$ONE"
    clear_lock "$TWO"
    rm -f "$ON_SLEEP" "$FLTH_TEST_STUB/ps_unreadable"
    stub_state stopped
    printf 'MemAvailable:   67108864 kB\n' > "$FLTH_TEST_MEMINFO"
}

clear_lock() {
    if [ -d "$1" ]; then rm -r "$1"; fi
}

mkdir -p "$FLTH_STATE_DIR"

# THE REPORT: a holder stamped now, in its boot grace, with no `memory` file.
reset_state
old_holder "$ONE" 0
out="$(FLTH_SLOT_WAIT=0 "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a wait that runs out beside a fresh unrecorded holder takes no slot"
check_lacks "$out" 'refusing to start' "a fresh holder with no memory file is not a refusal"
check_contains "$out" 'waiting' "the wait is named as a wait"
check_contains "$out" 'old-pin' "the wait names the unrecorded holder"
check_contains "$out" 'gave up' "running out of wait is reported as giving up"
check_eq "$(held "$TWO")" free "a waiter leaves no reservation of its own behind"
check_eq "$(held "$ONE")" held "the unrecorded holder keeps its slot"

# The holder settles during the wait: past grace, and its VM is running.
reset_state
old_holder "$ONE" 0
cat > "$ON_SLEEP" <<SETTLE
printf '%s\t%s\t%s\t%s\n' /old/machine old-pin "\$(( \$(date +%s) - 86400 ))" old-token > "$ONE/holder"
echo running > "$FLTH_TEST_STUB/state"
SETTLE
out="$(FLTH_SLOT_WAIT=60 "$SLOT" acquire 2>&1)"
check_eq "$?" 0 "the acquire takes a slot once the unrecorded holder has settled"
check_contains "$out" 'got the slot' "the acquire reports the end of its wait"
check_eq "$(held "$ONE")" held "a settled holder is not robbed"
check_eq "$(cat "$TWO/memory" 2>/dev/null)" 2048 "the acquire records its own reservation"

# The holder goes away during the wait.
reset_state
old_holder "$ONE" 0
printf 'rm "%s/holder"\nrmdir "%s"\n' "$ONE" "$ONE" > "$ON_SLEEP"
out="$(FLTH_SLOT_WAIT=60 "$SLOT" acquire 2>&1)"
check_eq "$?" 0 "the acquire takes a slot once the unrecorded holder has gone"
check_eq "$(cat "$ONE/memory" 2>/dev/null)" 2048 "the slot it left is the one taken"

# Past grace with no VM: nothing is booting and nothing is allocated. In a slot
# above the one taken, so the walk over slots never reaches it to break it.
reset_state
old_holder "$TWO" 86400
out="$(FLTH_SLOT_WAIT=0 "$SLOT" acquire 2>&1)"
check_eq "$?" 0 "a dead holder with no memory file does not stop an admission"
check_lacks "$out" 'refusing to start' "a dead unrecorded holder is not a refusal"

# Past grace and the process table cannot be read: unknown is never stopped.
reset_state
old_holder "$TWO" 86400
touch "$FLTH_TEST_STUB/ps_unreadable"
out="$(FLTH_SLOT_WAIT=0 "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "an unreadable process table does not waive an unrecorded holder"
check_lacks "$out" 'refusing to start' "an unreadable process table is a wait here, not a refusal"
check_eq "$(held "$TWO")" held "an unreadable process table leaves the holder its slot"
check_eq "$(held "$ONE")" free "the waiter leaves no reservation of its own behind"

# Memory already short without the unknown holder: waiting cannot help.
reset_state
old_holder "$ONE" 0
printf 'MemAvailable:   1048576 kB\n' > "$FLTH_TEST_MEMINFO"
out="$(FLTH_SLOT_WAIT=60 "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "known memory that is already short still refuses"
check_contains "$out" 'insufficient host memory' "the refusal is about host memory"

# A reservation that is present but malformed is still refused.
for malformed in garbage ''; do
    reset_state
    old_holder "$ONE" 0
    printf '%s' "$malformed" > "$ONE/memory"
    out="$(FLTH_SLOT_WAIT=60 "$SLOT" acquire 2>&1)"
    check_eq "$?" 1 "a malformed reservation refuses: '$malformed'"
    check_contains "$out" 'memory reservation is unknown for old-pin; refusing to start' \
        "the refusal names the malformed holder: '$malformed'"
    check_lacks "$out" 'waiting' "a malformed reservation does not wait: '$malformed'"
    check_eq "$(held "$TWO")" free "the refusal leaves no reservation behind: '$malformed'"
done

# The check before each boot meets the same holder, and keeps its own slot.
reset_state
"$SLOT" acquire 2>/dev/null
check_eq "$?" 0 "the booting consumer holds a slot"
old_holder "$TWO" 0
out="$(FLTH_SLOT_WAIT=0 "$SLOT" check-memory 2>&1)"
check_eq "$?" 1 "a boot check that runs out of wait does not boot"
check_lacks "$out" 'refusing to start' "the boot check beside a fresh holder is not a refusal"
check_contains "$out" 'old-pin' "the boot check names the unrecorded holder"
check_eq "$(held "$ONE")" held "the boot check keeps its own slot while it waits"

cat > "$ON_SLEEP" <<SETTLE
printf '%s\t%s\t%s\t%s\n' /old/machine old-pin "\$(( \$(date +%s) - 86400 ))" old-token > "$TWO/holder"
echo running > "$FLTH_TEST_STUB/state"
SETTLE
out="$(FLTH_SLOT_WAIT=60 "$SLOT" check-memory 2>&1)"
check_eq "$?" 0 "the boot check passes once the unrecorded holder has settled"
check_lacks "$out" 'refusing to start' "the settled boot check reports no refusal"
finish slot-memory-unrecorded
