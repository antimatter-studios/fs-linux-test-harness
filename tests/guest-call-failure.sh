#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
CONSUMER="$SANDBOX/consumer"
make_consumer "$CONSUMER" guest-call-failure
VM="$STUB_HARNESS/scripts/guest-call-failure.sh"
sed '/^command="${1:-}"/,$d' "$STUB_HARNESS/scripts/vm.sh" > "$VM"
cat >> "$VM" <<'STUB'
flth_load || exit 1
engine_prepare
guest_call() { echo 'vm: guest command construction refused' >&2; return 17; }
status=0
guest_run 'echo unexpected' || status=$?
exit "$status"
STUB
output="$(cd "$CONSUMER" && bash "$VM" 2>&1)"
check_eq "$?" 17 "a conditional guest call keeps command-construction failure"
check_contains "$output" 'guest command construction refused' "the construction failure remains visible"
check_lacks "$(stub_calls)" run "no empty or partial command reaches the guest"
finish guest-call-failure
