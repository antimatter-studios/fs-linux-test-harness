#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
C="$SANDBOX/consumer"
make_consumer "$C" oom-log
mkdir -p "$FLTH_TEST_STUB/guest-repo" "$FLTH_TEST_STUB/host-bin"
cat > "$FLTH_TEST_STUB/host-bin/dmesg" <<'STUB'
#!/bin/sh
printf '%s\n' '[ 12.0] Out of memory: Killed process 42 (test)' '[ 12.1] unrelated kernel event'
STUB
chmod +x "$FLTH_TEST_STUB/host-bin/dmesg"
output="$(cd "$C" && "$VM" run 'exit 9' 2>&1)"; rc=$?
check_eq "$rc" 9 'the guest failure status is preserved'
check_contains "$output" 'Out of memory: Killed process 42' 'guest OOM evidence is retained'
check_contains "$output" 'another run may be responsible' 'the log does not attribute the event to this run'
check_lacks "$output" 'unrelated kernel event' 'unrelated kernel messages are not printed'
finish guest-oom-log
