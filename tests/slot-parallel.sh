#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
export FLTH_SLOT_LIB=1 FLTH_SLOT_COUNT=2
# shellcheck source=../scripts/vm-slot.sh
. "$REPO/scripts/vm-slot.sh"
set +e
CFG_vm_memory=4G
host_memory_mib() { echo 32768; }
engine_alive() { return 1; }
acquire_for() {
    (HOLDER_IDENTITY="$FLTH_CACHE_DIR/$1"; HOLDER_NAME="$1"; cmd_acquire)
}
release_for() {
    (HOLDER_IDENTITY="$FLTH_CACHE_DIR/$1"; HOLDER_NAME="$1"; cmd_release)
}
acquire_for parallel-one > "$SANDBOX/one.log" 2>&1 &
first=$!
acquire_for parallel-two > "$SANDBOX/two.log" 2>&1 &
second=$!
wait "$first"
check_eq "$?" 0 "one parallel consumer acquires a slot"
wait "$second"
check_eq "$?" 0 "the other parallel consumer acquires the second slot"
out="$(cmd_status)"
check_contains "$out" parallel-one "the first simultaneous holder remains recorded"
check_contains "$out" parallel-two "the second simultaneous holder remains recorded"
mkfifo "$SANDBOX/ready" "$SANDBOX/resume"
exec 3<>"$SANDBOX/ready"
exec 4<>"$SANDBOX/resume"
(
    sleep() { printf 'waiting\n' >&3; IFS= read -r signal <&4; }
    WAIT_SECS=10
    acquire_for parallel-three
) > "$SANDBOX/three.log" 2>&1 &
third=$!
signal=""
IFS= read -r -t 10 signal <&3
check_eq "$signal" waiting "a third consumer actually blocks while both slots are held"
check_contains "$(cat "$SANDBOX/three.log")" 'waiting for the VM slot' "the blocked consumer reports the queue"
release_for parallel-one
printf 'continue\n' >&4
wait "$third"
check_eq "$?" 0 "the blocked third consumer acquires a slot when its holder releases it"
out="$(cmd_status)"
check_contains "$out" parallel-two "the independent second holder is not displaced"
check_contains "$out" parallel-three "the former waiter now owns a slot"
release_for parallel-two
release_for parallel-three
exec 3>&-
exec 4>&-
finish slot-parallel
