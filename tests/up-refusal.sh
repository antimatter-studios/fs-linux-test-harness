#!/usr/bin/env bash
#
# up-refusal.sh — an `up` that is refused, or whose step fails, says why and does
# nothing after it: no boot, no setup, no guest call.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
CONSUMER="$SANDBOX/consumer"
make_consumer "$CONSUMER" refused
MACHINE="$FLTH_CACHE_DIR/machines/shared-debian-12"

vm() { (cd "$CONSUMER" && "$VM" "$@"); }
after_refusal() {
    awk '/^memory-refused$|^step-refused$/ { refused=1; next } refused && $0 != "state"' "$FLTH_TEST_STUB/calls"
}

# THE HOST'S MEMORY IS MEASURED BEFORE EACH BOOT ATTEMPT (#220, which moved it out
# of the slot). The probe asks `uname -s` first, so a stand-in that counts the
# probes takes the host's memory away at the one named by FLTH_TEST_REFUSE_BOOT.
cat > "$FLTH_TEST_STUB/bin/uname" <<'STUB'
#!/bin/sh
probe="$(cat "$FLTH_TEST_STUB/memory-probes" 2>/dev/null || echo 0)"
probe=$((probe + 1))
echo "$probe" > "$FLTH_TEST_STUB/memory-probes"
if [ "$probe" = "${FLTH_TEST_REFUSE_BOOT:-0}" ]; then
    echo memory-refused >> "$FLTH_TEST_STUB/calls"
    printf 'MemAvailable: 0 kB\n' > "$FLTH_TEST_MEMINFO"
fi
echo "${FLTH_TEST_UNAME:-Linux}"
STUB
chmod +x "$FLTH_TEST_STUB/bin/uname"

for attempt in 1 2; do
    stub_state absent
    stub_reset_calls
    echo 0 > "$FLTH_TEST_STUB/memory-probes"
    # The second: a first attempt that fails, and a host that has no room for the retry.
    [ "$attempt" = 1 ] || echo 1 > "$FLTH_TEST_STUB/up_failures"
    export FLTH_TEST_REFUSE_BOOT="$attempt"
    output="$(vm up 2>&1)"
    check_eq "$?" 1 "attempt $attempt: a memory refusal fails up"
    check_contains "$output" 'not enough host memory for the shared guest: 0 MiB available' "attempt $attempt: up names the refusal and the numbers"
    check_contains "$output" '8192 MiB for the guest and 2048 MiB left for the host' "attempt $attempt: what the guest and the host need"
    check_lacks "$output" 'setup script (setup.sh) failed inside the VM' "attempt $attempt: refusal is not called a setup failure"
    check_lacks "$output" 'The VM is left running' "attempt $attempt: refusal does not claim a running VM"
    check_eq "$(grep -c '^memory-refused$' "$FLTH_TEST_STUB/calls")" 1 "attempt $attempt: one boot is refused"
    check_eq "$(after_refusal)" '' "attempt $attempt: no boot, setup or guest call follows the refusal"
    check_eq "$([ -d "$MACHINE/up.lock" ] && echo held || echo free)" free "attempt $attempt: the up lock is released"
    printf 'MemAvailable: 67108864 kB\n' > "$FLTH_TEST_MEMINFO"
    export FLTH_TEST_REFUSE_BOOT=0
    rm -f "$FLTH_TEST_STUB/up_failures"
    vm up > "$SANDBOX/recovery.log" 2>&1
    check_eq "$?" 0 "attempt $attempt: a later up with room succeeds"
    vm down >> "$SANDBOX/recovery.log" 2>&1
    check_eq "$?" 0 "attempt $attempt: the recovered VM stops"
done

# The probes, as a host answers them.
stub_state absent
stub_reset_calls
printf 'MemAvailable: 8192000 kB\n' > "$FLTH_TEST_MEMINFO"
check_contains "$(vm up 2>&1)" '8000 MiB available' "the Linux probe converts MemAvailable from KiB to MiB"
printf 'MemTotal: 67108864 kB\n' > "$FLTH_TEST_MEMINFO"
check_contains "$(vm up 2>&1)" 'free memory could not be measured' "a missing Linux available-memory field refuses rather than guessing"
printf 'MemAvailable: 67108864 kB\n' > "$FLTH_TEST_MEMINFO"
check_contains "$(FLTH_SHARED_MEMORY=1G vm config)" 'vm.memory=1G' "FLTH_SHARED_MEMORY asks for less"
export FLTH_TEST_UNAME=Darwin
printf '#!/bin/sh\nprintf "%%s\\n" "Mach Virtual Memory Statistics: (page size of 4096 bytes)" "Pages free: 256." "Pages inactive: 256." "Pages speculative: 512."\n' > "$SANDBOX/memory-bin/vm_stat"
check_contains "$(vm up 2>&1)" '4 MiB available' "the macOS probe adds reclaimable pages at the reported page size"
printf '#!/bin/sh\necho "Pages free: 100."\n' > "$SANDBOX/memory-bin/vm_stat"
check_contains "$(vm up 2>&1)" 'free memory could not be measured' "an incomplete macOS memory report refuses rather than guessing"
unset FLTH_TEST_UNAME
check_eq "$(grep -c '^up$' "$FLTH_TEST_STUB/calls" | tr -d ' ')" 0 "none of those refusals booted"
stub_reset_calls

# vm.sh's definitions with a step made to fail. `up` runs its boot as vm.sh again,
# `vm.sh up-boot` (#209), which here is this script again, so the step fails there too.
FAILURE_VM="$STUB_HARNESS/scripts/failure-vm.sh"
sed '/^command="${1:-}"/,$d' "$VM" > "$FAILURE_VM"
cat >> "$FAILURE_VM" <<'STUB'
flth_load || exit 1
engine_prepare
eval "$FLTH_TEST_FAIL_STEP() { stub_log step-refused; echo 'vm: $FLTH_TEST_FAIL_STEP refused' >&2; return 17; }"
if [ "${1:-}" = up-boot ]; then
    vm_up_boot "$2" "$3"
elif [ "$FLTH_TEST_FAIL_STEP" = guest_call ]; then
    guest_run 'echo unexpected'
else
    vm_up
fi
STUB

for failure in engine_state:absent boot_engine:absent apply_setup:absent boot_engine:stopped \
    apply_setup:stopped apply_setup:running guest_call:running; do
    step="${failure%:*}"
    state="${failure#*:}"
    if [ "$state" = absent ]; then
        stub_state absent
    else
        vm up > "$SANDBOX/stage-fixture.log" 2>&1
        check_eq "$?" 0 "$failure: the fixture boots"
        if [ "$state" = stopped ]; then
            vm down >> "$SANDBOX/stage-fixture.log" 2>&1
            check_eq "$?" 0 "$failure: the fixture stops"
        fi
    fi
    stub_reset_calls
    output="$(cd "$CONSUMER" && FLTH_TEST_FAIL_STEP="$step" bash "$FAILURE_VM" 2>&1)"
    check_eq "$?" 17 "$failure: the failed step's status reaches the caller"
    check_contains "$output" "$step refused" "$failure: the failed step is named"
    check_eq "$(after_refusal)" '' "$failure: no later engine or guest work runs"
    vm down > "$SANDBOX/stage-cleanup.log" 2>&1
    check_eq "$?" 0 "$failure: the fixture is cleaned up"
done

finish up-refusal
