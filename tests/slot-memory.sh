#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_consumer "$SANDBOX/one" memory-one '[vm]' 'memory = "2G"'
export FLTH_CONFIG="$SANDBOX/one/fs-linux-test-harness.toml" FLTH_SLOT_LIB=1
# shellcheck source=../scripts/vm-slot.sh
. "$REPO/scripts/vm-slot.sh"
set +e
slot_identify
check_eq "$(guest_memory_mib)" 2048 "guest gigabytes are converted to MiB"
CFG_vm_memory=3072M
check_eq "$(guest_memory_mib)" 3072 "guest megabytes remain MiB"
CFG_vm_memory=2G
saved_memory="$(declare -f host_memory_mib)"
host_memory_mib() { echo 6144; }
mkdir -p "$FLTH_STATE_DIR/slot-2.lock"
printf '%s\t%s\t%s\t%s\n' other-memory memory-two "$(now)" token-two > "$FLTH_STATE_DIR/slot-2.lock/holder"
echo 4096 > "$FLTH_STATE_DIR/slot-2.lock/memory"
engine_alive() { return 1; }
out="$(memory_admit 2>&1)"
check_eq "$?" 1 "simultaneous boot reservations cannot spend the same available memory"
check_contains "$out" '4096 MiB pending guests' "the refusal reports the other boot's reservation"
host_memory_mib() { echo 8192; }
memory_admit
check_eq "$?" 0 "exactly enough memory admits the guest with the host reserve intact"
printf '%s\t%s\t%s\t%s\n' other-memory memory-two "$(( $(now) - 86400 ))" token-two > "$FLTH_STATE_DIR/slot-2.lock/holder"
host_memory_mib() { echo 4096; }
engine_alive() { return 0; }
memory_admit
check_eq "$?" 0 "a settled running guest is already reflected in available host memory"
snapshot="$(LOCK="$FLTH_STATE_DIR/slot-2.lock"; HOLDER="$LOCK/holder"; read_holder)"
CFG_vm_memory=4G
renewed=gen-reboot
LOCK="$FLTH_STATE_DIR/slot-2.lock" renew_holder "$snapshot" "$renewed"
CFG_vm_memory=2G
check_eq "$([ "$renewed" != token-two ] && echo renewed || echo unchanged)" renewed "each reboot replaces the generation as well as renewing the boot grace"
(LOCK="$FLTH_STATE_DIR/slot-2.lock"; HOLDER="$LOCK/holder"; delete_generation token-two breaking)
check_eq "$?" 1 "a waiter holding the pre-reboot token cannot delete the renewed slot"
out="$(memory_admit 2>&1)"
check_eq "$?" 1 "a reboot renews the pending memory reservation even for an old slot"
engine_alive() { return 2; }
out="$(memory_admit 2>&1)"
check_eq "$?" 1 "an unreadable process table cannot waive the pending reservation"
export FLTH_SLOT_COUNT=1 FLTH_SLOT_WAIT=0
WAIT_SECS=0
out="$(cmd_acquire 2>&1)"
check_eq "$?" 1 "reducing the limit drains disabled slots before admitting a replacement"
check_contains "$out" memory-two "draining names the holder in the disabled slot"
cmd_release --force
check_eq "$([ -d "$FLTH_STATE_DIR/slot-2.lock" ] && echo held || echo free)" free "force release also finds slots above a lowered limit"
unset FLTH_SLOT_LIB
eval "$saved_memory"
# The probes run real commands, so stubs on PATH reach them as a host would.
stub_command() {
    printf '#!/bin/sh\n%s\n' "$2" > "$SANDBOX/memory-bin/$1"
    chmod +x "$SANDBOX/memory-bin/$1"
    hash -r
}
stub_command uname 'echo Linux'
check_eq "$(host_memory_mib)" 65536 "the Linux probe converts MemAvailable from KiB to MiB"
printf 'MemAvailable: 8192 kB\n' > "$FLTH_TEST_MEMINFO"
check_eq "$(host_memory_mib)" 8 "the Linux probe uses the available field, not total memory"
printf 'MemTotal: 67108864 kB\n' > "$FLTH_TEST_MEMINFO"
host_memory_mib >/dev/null
check_eq "$?" 1 "a missing Linux available-memory field is not zero or a guessed capacity"
stub_command uname 'echo Darwin'
stub_command vm_stat "printf '%s\\n' 'Mach Virtual Memory Statistics: (page size of 4096 bytes)' 'Pages free: 256.' 'Pages inactive: 256.' 'Pages speculative: 512.'"
check_eq "$(host_memory_mib)" 4 "the macOS probe adds reclaimable pages at the reported page size"
stub_command vm_stat "echo 'Pages free: 100.'"
host_memory_mib >/dev/null
check_eq "$?" 1 "an incomplete macOS memory report refuses rather than guessing"
finish slot-memory
