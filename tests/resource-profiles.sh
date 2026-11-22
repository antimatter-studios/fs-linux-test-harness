#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
CONSUMER="$SANDBOX/consumer"
make_consumer "$CONSUMER" resource-profiles
vm() { (cd "$CONSUMER" && "$VM" "$@"); }
. "$REPO/scripts/lib/common.sh"

check_eq "$(flth_detect_resource_profile Darwin false)" high 'macOS automatically selects high'
check_eq "$(flth_detect_resource_profile Linux false 'Raspberry Pi 5 Model B')" medium 'Raspberry Pi automatically selects medium'
check_eq "$(flth_detect_resource_profile Darwin true)" low 'GitHub Actions selects low before host OS detection'
check_eq "$(flth_detect_resource_profile Linux false 'Generic Linux host')" low 'unrecognized hosts safely select low'

out="$(FLTH_RESOURCE_PROFILE=high vm config)"
check_contains "$out" 'resource.profile=high' 'config reports the selected high resource profile'
check_contains "$out" 'vm.memory=8G' 'high sets shared guest memory'
check_contains "$out" 'vm.cpus=8' 'high sets shared guest CPUs'
check_contains "$out" 'vm.build_jobs=8' 'high sets build parallelism'
check_contains "$out" 'vm.test_jobs=8' 'high sets test parallelism'
check_contains "$out" 'slots=32' 'high leaves attached runs at 32 (#264)'

out="$(FLTH_RESOURCE_PROFILE=medium vm config)"
check_contains "$out" 'vm.memory=4G' 'medium sets shared guest memory'
check_contains "$out" 'vm.cpus=2' 'medium sets shared guest CPUs'
check_contains "$out" 'vm.build_jobs=2' 'medium sets build parallelism'
check_contains "$out" 'vm.test_jobs=2' 'medium sets test parallelism'
check_contains "$out" 'slots=32' 'medium leaves attached runs at 32 (#264)'

out="$(FLTH_RESOURCE_PROFILE=low vm config)"
check_contains "$out" 'vm.memory=2G' 'low sets shared guest memory'
check_contains "$out" 'vm.cpus=2' 'low sets shared guest CPUs'
check_contains "$out" 'vm.build_jobs=1' 'low sets build parallelism'
check_contains "$out" 'vm.test_jobs=1' 'low sets test parallelism'
check_contains "$out" 'slots=32' 'low leaves attached runs at 32 (#264)'

out="$(GITHUB_ACTIONS=true FLTH_RESOURCE_PROFILE='' vm config)"
check_contains "$out" 'resource.profile=low' 'unset profile auto-selects low in GitHub Actions'
out="$(GITHUB_ACTIONS=true FLTH_RESOURCE_PROFILE=high FLTH_BUILD_JOBS=5 FLTH_SHARED_MEMORY=3G FLTH_SHARED_CPUS=3 FLTH_SHARED_SLOTS=4 vm config)"
check_contains "$out" 'resource.profile=high' 'explicit profile overrides automatic detection'
check_contains "$out" 'vm.build_jobs=5' 'explicit build limit overrides the profile'
check_contains "$out" 'vm.memory=3G' 'explicit memory overrides the profile'
check_contains "$out" 'vm.cpus=3' 'explicit CPU count overrides the profile'
check_contains "$out" 'slots=4' 'explicit slot count overrides the profile'

out="$(FLTH_RESOURCE_PROFILE=invalid vm config 2>&1)"; rc=$?
check_eq "$rc" 1 'unknown resource profiles are refused'
check_contains "$out" 'FLTH_RESOURCE_PROFILE must be high, medium or low' 'unknown profile error names the accepted values'
out="$(FLTH_PROFILE=old-name vm config 2>&1)"; rc=$?
check_eq "$rc" 1 'the old VM profile variable is a hard error'
check_contains "$out" 'use FLTH_VM_PROFILE' 'old profile error gives the replacement name'
out="$(FLTH_PROFILE_DIR=/old/path vm config 2>&1)"; rc=$?
check_eq "$rc" 1 'the old VM profile directory variable is a hard error'
check_contains "$out" 'use FLTH_VM_PROFILE_DIR' 'old profile directory error gives the replacement name'

finish resource-profiles
