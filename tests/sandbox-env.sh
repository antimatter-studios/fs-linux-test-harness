#!/usr/bin/env bash
#
# The suite runs where a person or a guest runs it, with what that left in the
# environment. FLTH_GUEST=1 is in every command the harness runs in a guest, and it
# turns a session into a plain exec, so the session tests there test nothing.
# FLTH_SHARED_ROOT moves every sandbox's consumer onto a guest they are not under.
set -uo pipefail
export FLTH_GUEST=1 FLTH_SHARED_ROOT=/nowhere FLTH_SHARED_MEMORY=1G FLTH_SHARED_CPUS=1 FLTH_SHARED_DISK=1G
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
make_consumer "$SANDBOX/consumer" sandbox-env
VM="$STUB_HARNESS/scripts/vm.sh"

for name in FLTH_GUEST FLTH_SHARED_ROOT FLTH_SHARED_MEMORY FLTH_SHARED_CPUS FLTH_SHARED_DISK; do
    check_eq "$(printenv "$name")" "" "a sandbox does not inherit $name"
done

out="$(cd "$SANDBOX/consumer" && "$VM" session "$VM" up 2>&1)"
check_eq "$?" 0 "a session runs in the sandbox's consumer ($(printf '%s' "$out" | tail -n 1))"
check_contains "$(stub_calls)" "down" "and it tears down what it booted, which a plain exec does not"

finish sandbox-env
