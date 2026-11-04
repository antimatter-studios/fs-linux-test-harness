#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
ROOT_SANDBOX="$SANDBOX"

vm() { (cd "$CONSUMER" && "$VM" "$@"); }
after_refusal() {
    awk '/^memory-refused$|^step-refused$/ { refused=1; next } refused && $0 != "state"' "$FLTH_TEST_STUB/calls"
}

for phase in provisioning post-provisioning disposable; do
    SANDBOX="$ROOT_SANDBOX/$phase"
    mkdir -p "$SANDBOX"
    export FLTH_CACHE_DIR="$SANDBOX/cache" FLTH_STATE_DIR="$SANDBOX/state"
    make_stub_harness
    VM="$STUB_HARNESS/scripts/vm.sh"
    CONSUMER="$SANDBOX/consumer"
    make_consumer "$CONSUMER" "refused-$phase"
    MACHINE="$FLTH_CACHE_DIR/machines/refused-$phase"
    printf '#!/bin/sh\necho Linux\n' > "$FLTH_TEST_STUB/bin/uname"
    chmod +x "$FLTH_TEST_STUB/bin/uname"
    cp "$STUB_HARNESS/scripts/vm-slot.sh" "$STUB_HARNESS/scripts/vm-slot-real.sh"
    cat > "$STUB_HARNESS/scripts/vm-slot.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = check-memory ]; then
    probe="$(cat "$FLTH_TEST_STUB/memory-probes" 2>/dev/null || echo 0)"
    probe=$((probe + 1))
    echo "$probe" > "$FLTH_TEST_STUB/memory-probes"
    if [ "$probe" = "${FLTH_TEST_REFUSE_BOOT:-0}" ]; then
        echo memory-refused >> "$FLTH_TEST_STUB/calls"
        printf 'MemAvailable: 0 kB\n' > "$FLTH_TEST_MEMINFO"
    fi
fi
exec "$(dirname "$0")/vm-slot-real.sh" "$@"
STUB
    export FLTH_TEST_REFUSE_BOOT=0
    if [ "$phase" = disposable ]; then
        vm up > "$SANDBOX/fixture.log" 2>&1
        check_eq "$?" 0 "$phase: the disk is provisioned before the refusal"
        vm down >> "$SANDBOX/fixture.log" 2>&1
        check_eq "$?" 0 "$phase: the fixture is stopped"
    fi
    stub_reset_calls
    echo 0 > "$FLTH_TEST_STUB/memory-probes"
    export FLTH_TEST_REFUSE_BOOT=1
    [ "$phase" != post-provisioning ] || export FLTH_TEST_REFUSE_BOOT=2
    output="$(vm up 2>&1)"
    check_eq "$?" 1 "$phase: a memory refusal fails up"
    check_contains "$output" 'insufficient host memory' "$phase: up names the memory refusal"
    check_contains "$output" 'refusing to start' "$phase: the admission diagnostic survives"
    check_lacks "$output" 'setup script (setup.sh) failed inside the VM' "$phase: refusal is not called a setup failure"
    check_lacks "$output" 'The VM is left running' "$phase: refusal does not claim a running VM"
    check_eq "$(grep -c '^memory-refused$' "$FLTH_TEST_STUB/calls")" 1 "$phase: admission refuses exactly one boot"
    check_eq "$(after_refusal)" '' "$phase: no boot, setup or guest call follows the refusal"
    check_eq "$([ -d "$FLTH_STATE_DIR/slot.lock" ] && echo held || echo free)" free "$phase: the slot is released"
    check_eq "$([ -d "$MACHINE/up.lock" ] && echo held || echo free)" free "$phase: the up lock is released"
    check_eq "$([ -f "$MACHINE/provisioning" ] && echo present || echo absent)" absent "$phase: no provisioning marker survives"
    printf 'MemAvailable: 67108864 kB\n' > "$FLTH_TEST_MEMINFO"
    export FLTH_TEST_REFUSE_BOOT=0
    vm up > "$SANDBOX/recovery.log" 2>&1
    check_eq "$?" 0 "$phase: a later admitted up succeeds"
    vm down >> "$SANDBOX/recovery.log" 2>&1
    check_eq "$?" 0 "$phase: the recovered VM stops"
done

FAILURE_VM="$STUB_HARNESS/scripts/failure-vm.sh"
sed '/^command="${1:-}"/,$d' "$VM" > "$FAILURE_VM"
cat >> "$FAILURE_VM" <<'STUB'
flth_load || exit 1
engine_prepare
eval "$FLTH_TEST_FAIL_STEP() { stub_log step-refused; echo 'vm: $FLTH_TEST_FAIL_STEP refused' >&2; return 17; }"
if [ "$FLTH_TEST_FAIL_STEP" = guest_call ]; then
    guest_run 'echo unexpected'
else
    vm_up
fi
STUB

for failure in engine_state:absent engine_forget_kernel:absent record_boot_invocation:absent \
    provision_disk:absent boot_engine:absent apply_setup:absent boot_engine:stopped \
    apply_setup:stopped apply_setup:running forget_disk_if_setup_ran:running guest_call:running; do
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
