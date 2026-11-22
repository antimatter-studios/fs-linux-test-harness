#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
export FLTH_RESOURCE_PROFILE=low
unset FLTH_TEST_JOBS RUST_TEST_THREADS
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
C="$SANDBOX/consumer"
make_consumer "$C" thread-default '[test]' 'guest_command = "sh jobs.sh"'
printf '%s\n' 'printf "%s/%s" "${FLTH_TEST_JOBS-unset}" "${RUST_TEST_THREADS-unset}" > "$FLTH_SHARE/setup-jobs"' > "$C/setup.sh"
printf '%s\n' 'printf "%s/%s\n" "${FLTH_TEST_JOBS-unset}" "${RUST_TEST_THREADS-unset}"' > "$C/jobs.sh"
mkdir -p "$FLTH_TEST_STUB/guest-repo"
cp "$C/jobs.sh" "$FLTH_TEST_STUB/guest-repo/jobs.sh"
vm() { (cd "$C" && "$VM" "$@"); }
probe='printf "%s/%s" "${FLTH_TEST_JOBS-unset}" "${RUST_TEST_THREADS-unset}"'
check_eq "$(vm run "$probe" 2>/dev/null)" 1/1 'low profile limits guest tests'
check_eq "$(cat "$C/.vm-share/setup-jobs")" 1/1 'setup receives test limits'
check_contains "$(vm guest-test 2>&1)" 1/1 'guest-test receives test limits'
check_eq "$(FLTH_TEST_JOBS=3 vm exec "$probe" 2>/dev/null)" 3/3 'environment overrides test jobs'
check_contains "$(vm config 2>/dev/null)" vm.test_jobs=1 'config reports test jobs'
SECOND="$SANDBOX/second"
make_consumer "$SECOND" thread-config '[vm]' 'test_jobs = 2'
vm_second() { (cd "$SECOND" && "$VM" "$@"); }
check_eq "$(vm_second run "$probe" 2>/dev/null)" 2/2 'consumer config limits guest tests'
check_eq "$(FLTH_TEST_JOBS=3 vm_second exec "$probe" 2>/dev/null)" 3/3 'environment overrides consumer config'
for invalid in 0 -1 nope '1; touch unwanted'; do
    out="$(FLTH_TEST_JOBS="$invalid" vm config 2>&1)"; rc=$?
    check_eq "$rc" 1 'invalid thread limit is refused'
    check_contains "$out" test_jobs 'error names test jobs'
done
finish guest-test-threads
