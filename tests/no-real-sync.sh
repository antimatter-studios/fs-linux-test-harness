#!/usr/bin/env bash
#
# A guest's script runs on the host under the stub engine, and a provisioning boot's
# script is `sync`. A VM-free test must not flush every disk on the machine running
# it (#191), and inside a shared guest that call can wait for ever on what another
# suite has stuck. So a stand-in is first on PATH, and a boot reaches it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
make_consumer "$SANDBOX/consumer" no-real-sync
VM="$STUB_HARNESS/scripts/vm.sh"

check_eq "$(command -v sync)" "$FLTH_TEST_STUB/bin/sync" "sync on PATH is the stand-in"
(cd "$SANDBOX/consumer" && "$VM" up) >/dev/null 2>&1
check_eq "$?" 0 "a first boot, which provisions, comes up"
check_contains "$(stub_calls)" "sync" "and its sync reached the stand-in"
(cd "$SANDBOX/consumer" && "$VM" down) >/dev/null 2>&1

# The other way a guest's script runs here: a stand-in ssh that runs what it is sent.
check_contains "$(cat "$REPO/tests/boot-kernel.sh")" 'BIN/sync"' "tests/boot-kernel.sh has its own sync"

finish no-real-sync
