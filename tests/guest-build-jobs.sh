#!/usr/bin/env bash
# Build limits belong to each call, including setup and a suite in the guest.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
# These check the low profile's single-job default.
export FLTH_RESOURCE_PROFILE=low
make_stub_harness
unset FLTH_BUILD_JOBS CARGO_BUILD_JOBS
VM="$STUB_HARNESS/scripts/vm.sh"
C="$SANDBOX/consumer"
make_consumer "$C" build-default '[test]' 'guest_command = "sh jobs.sh"'
cat > "$C/setup.sh" <<'SETUP'
printf '%s/%s\n' "${FLTH_BUILD_JOBS-unset}" "${CARGO_BUILD_JOBS-unset}" > "$FLTH_SHARE/setup-jobs"
SETUP
cat > "$C/jobs.sh" <<'SUITE'
printf 'jobs=%s/%s\n' "${FLTH_BUILD_JOBS-unset}" "${CARGO_BUILD_JOBS-unset}"
SUITE
# The stub logs mount requests; seed the repository its guest calls execute in.
mkdir -p "$FLTH_TEST_STUB/guest-repo"
cp "$C/jobs.sh" "$FLTH_TEST_STUB/guest-repo/jobs.sh"
vm() { (cd "$C" && "$VM" "$@"); }
probe='printf "jobs=%s/%s\n" "${FLTH_BUILD_JOBS-unset}" "${CARGO_BUILD_JOBS-unset}"'
out="$(vm run "$probe" 2>"$SANDBOX/default.log")"; rc=$?
check_eq "$rc" 0 'a default guest command succeeds'
check_eq "$out" jobs=1/1 'run exports the generic limit and Cargo mapping'
check_eq "$(cat "$C/.vm-share/setup-jobs" 2>/dev/null)" 1/1 'setup receives both build-limit variables'
check_eq "$(vm exec "$probe" 2>/dev/null)" jobs=1/1 'exec exports the generic limit and Cargo mapping'
out="$(vm guest-test 2>&1)"; rc=$?
check_eq "$rc" 0 'guest-test succeeds with its default build limit'
check_contains "$out" jobs=1/1 'guest-test exports both build-limit variables'
check_eq "$(FLTH_BUILD_JOBS=3 vm exec "$probe" 2>/dev/null)" jobs=3/3 'FLTH_BUILD_JOBS overrides the default and maps to Cargo'

SECOND="$SANDBOX/second"
make_consumer "$SECOND" build-config '[vm]' 'build_jobs = 2' '[test]' 'guest_command = "sh jobs.sh"'
cp "$C/setup.sh" "$C/jobs.sh" "$SECOND/"
vm_second() { (cd "$SECOND" && "$VM" "$@"); }
out="$(vm_second run "$probe" 2>"$SANDBOX/config.log")"; rc=$?
check_eq "$rc" 0 'a consumer with build_jobs loads and runs'
check_eq "$out" jobs=2/2 'the config sets generic and Cargo guest build concurrency'
check_eq "$(cat "$SECOND/.vm-share/setup-jobs" 2>/dev/null)" 2/2 'the config also limits setup builds'
out="$(vm_second guest-test 2>&1)"; rc=$?
check_eq "$rc" 0 'guest-test accepts configured concurrency'
check_contains "$out" jobs=2/2 'guest-test uses configured concurrency'
check_eq "$(FLTH_BUILD_JOBS=3 vm_second exec "$probe" 2>/dev/null)" jobs=3/3 'FLTH_BUILD_JOBS takes precedence over config'
# A host's CARGO_BUILD_JOBS still overrides the config, as before resource profiles,
# and FLTH_BUILD_JOBS overrides it in turn (#264).
check_eq "$(CARGO_BUILD_JOBS=4 vm_second exec "$probe" 2>/dev/null)" jobs=4/4 'a host CARGO_BUILD_JOBS still takes precedence over config'
check_eq "$(CARGO_BUILD_JOBS=4 vm exec "$probe" 2>/dev/null)" jobs=4/4 'and over the resource profile'
check_eq "$(CARGO_BUILD_JOBS=4 FLTH_BUILD_JOBS=3 vm_second exec "$probe" 2>/dev/null)" jobs=3/3 'FLTH_BUILD_JOBS takes precedence over a host CARGO_BUILD_JOBS'
check_contains "$(vm_second config 2>/dev/null)" vm.build_jobs=2 'config reports effective build concurrency'
check_eq "$(vm exec "$probe" 2>/dev/null)" jobs=1/1 'another consumer retains its own default'
for invalid in 0 -1 nope '1; touch unwanted'; do
    out="$(FLTH_BUILD_JOBS="$invalid" vm config 2>&1)"; rc=$?
    check_eq "$rc" 1 'invalid environment concurrency is refused'
    check_contains "$out" build_jobs 'the refusal names the build setting'
    out="$(CARGO_BUILD_JOBS="$invalid" vm config 2>&1)"; rc=$?
    check_eq "$rc" 1 'an invalid host CARGO_BUILD_JOBS is refused'
done
make_consumer "$SANDBOX/bad" build-bad '[vm]' 'build_jobs = 0'
out="$(FLTH_CONFIG="$SANDBOX/bad/fs-linux-test-harness.toml" "$VM" config 2>&1)"; rc=$?
check_eq "$rc" 1 'zero configured build jobs is refused'
check_contains "$out" build_jobs 'invalid config names build_jobs'
finish guest-build-jobs
