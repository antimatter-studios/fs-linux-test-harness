#!/usr/bin/env bash
# Build limits belong to each call, including setup and a suite in the guest.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
unset CARGO_BUILD_JOBS
VM="$STUB_HARNESS/scripts/vm.sh"
C="$SANDBOX/consumer"
make_consumer "$C" build-default '[test]' 'guest_command = "sh jobs.sh"'
cat > "$C/setup.sh" <<'SETUP'
printf '%s\n' "${CARGO_BUILD_JOBS-unset}" > "$FLTH_SHARE/setup-jobs"
SETUP
cat > "$C/jobs.sh" <<'SUITE'
printf 'jobs=%s\n' "${CARGO_BUILD_JOBS-unset}"
SUITE
# The stub logs mount requests; seed the repository its guest calls execute in.
mkdir -p "$FLTH_TEST_STUB/guest-repo"
cp "$C/jobs.sh" "$FLTH_TEST_STUB/guest-repo/jobs.sh"
vm() { (cd "$C" && "$VM" "$@"); }
probe='printf "jobs=%s\n" "${CARGO_BUILD_JOBS-unset}"'
out="$(vm run "$probe" 2>"$SANDBOX/default.log")"; rc=$?
check_eq "$rc" 0 'a default guest command succeeds'
check_eq "$out" jobs=1 'run exports a single build job by default'
check_eq "$(cat "$C/.vm-share/setup-jobs" 2>/dev/null)" 1 'setup receives the same single-job default'
check_eq "$(vm exec "$probe" 2>/dev/null)" jobs=1 'exec exports the single-job default'
out="$(vm guest-test 2>&1)"; rc=$?
check_eq "$rc" 0 'guest-test succeeds with its default build limit'
check_contains "$out" jobs=1 'guest-test exports the single-job default'
check_eq "$(CARGO_BUILD_JOBS=3 vm exec "$probe" 2>/dev/null)" jobs=3 'the host environment overrides the default'

SECOND="$SANDBOX/second"
make_consumer "$SECOND" build-config '[vm]' 'build_jobs = 2' '[test]' 'guest_command = "sh jobs.sh"'
cp "$C/setup.sh" "$C/jobs.sh" "$SECOND/"
vm_second() { (cd "$SECOND" && "$VM" "$@"); }
out="$(vm_second run "$probe" 2>"$SANDBOX/config.log")"; rc=$?
check_eq "$rc" 0 'a consumer with build_jobs loads and runs'
check_eq "$out" jobs=2 'the config sets guest build concurrency'
check_eq "$(cat "$SECOND/.vm-share/setup-jobs" 2>/dev/null)" 2 'the config also limits setup builds'
out="$(vm_second guest-test 2>&1)"; rc=$?
check_eq "$rc" 0 'guest-test accepts configured concurrency'
check_contains "$out" jobs=2 'guest-test uses configured concurrency'
check_eq "$(CARGO_BUILD_JOBS=3 vm_second exec "$probe" 2>/dev/null)" jobs=3 'the environment takes precedence over config'
check_contains "$(vm_second config 2>/dev/null)" vm.build_jobs=2 'config reports effective build concurrency'
check_eq "$(vm exec "$probe" 2>/dev/null)" jobs=1 'another consumer retains its own default'
for invalid in 0 -1 nope '1; touch unwanted'; do
    out="$(CARGO_BUILD_JOBS="$invalid" vm config 2>&1)"; rc=$?
    check_eq "$rc" 1 'invalid environment concurrency is refused'
    check_contains "$out" build_jobs 'the refusal names the build setting'
done
make_consumer "$SANDBOX/bad" build-bad '[vm]' 'build_jobs = 0'
out="$(FLTH_CONFIG="$SANDBOX/bad/fs-linux-test-harness.toml" "$VM" config 2>&1)"; rc=$?
check_eq "$rc" 1 'zero configured build jobs is refused'
check_contains "$out" build_jobs 'invalid config names build_jobs'
finish guest-build-jobs
