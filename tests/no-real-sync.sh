#!/usr/bin/env bash
#
# A guest's script runs on the host under the stub engine, and a test can send the
# guest `sync`. A VM-free test must not flush every disk on the machine running it
# (#191), and inside a shared guest that call can wait for ever on what another
# suite has stuck. So a stand-in is first on PATH, and a call reaches it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
make_consumer "$SANDBOX/consumer" no-real-sync
VM="$STUB_HARNESS/scripts/vm.sh"

check_eq "$(command -v sync)" "$FLTH_TEST_STUB/bin/sync" "sync on PATH is the stand-in"
(cd "$SANDBOX/consumer" && "$VM" up) >/dev/null 2>&1
check_eq "$?" 0 "a first boot comes up"
(cd "$SANDBOX/consumer" && "$VM" exec sync) >/dev/null 2>&1
check_contains "$(stub_calls)" "sync" "and a sync sent to it reached the stand-in"
(cd "$SANDBOX/consumer" && "$VM" down) >/dev/null 2>&1

finish no-real-sync
