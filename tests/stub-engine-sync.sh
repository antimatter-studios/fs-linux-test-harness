#!/usr/bin/env bash
#
# The stub engine runs every guest script on the host. A consumer that drives the
# harness through tests/stubs/engine.sh with a PATH of its own, as rust-fs-btrfs's
# script guards do, reached the machine's real `sync` that way, 18 times in one tier
# (#202). Every boot now prepares the shared guest, whose script binds directories
# and enters namespaces (#220), and on the host those would be this machine's mounts.
# The engine itself must stop both, whatever PATH its caller gives it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
require_guest_bash || exit 1

# A consumer's setup, not make_stub_harness: the stub engine copied in, the harness's
# own scripts beside it, and a PATH whose first sync stands for the real one.
H="$SANDBOX/harness"
mkdir -p "$H"
cp -R "$REPO/scripts" "$H/"
cp "$REPO/tests/stubs/engine.sh" "$H/scripts/lib/engine.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/scripts/host-tools.sh"
chmod +x "$H/scripts/host-tools.sh"
export FLTH_TEST_STUB="$SANDBOX/stub"
mkdir -p "$FLTH_TEST_STUB" "$SANDBOX/real"
echo absent > "$FLTH_TEST_STUB/state"
: > "$FLTH_TEST_STUB/calls"
for tool in sync mount umount mountpoint unshare nsenter losetup; do
    printf '#!/bin/sh\necho "real %s" >> "%s/real/hits"\n' "$tool" "$SANDBOX" > "$SANDBOX/real/$tool"
done
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/real/sleep"
chmod +x "$SANDBOX/real/"*
export PATH="$SANDBOX/real:$PATH"
make_consumer "$SANDBOX/consumer" stub-engine-sync

(cd "$SANDBOX/consumer" && "$H/scripts/vm.sh" up) >/dev/null 2>&1
check_eq "$?" 0 "a first boot comes up through the stub engine"
check_eq "$(cat "$SANDBOX/real/hits" 2>/dev/null)" "" "and reaches no sync or mount tool on its caller's PATH"
check_contains "$(cat "$FLTH_TEST_STUB/guest-tools" 2>/dev/null)" "mount --bind" "its mounts are logged instead"
(cd "$SANDBOX/consumer" && "$H/scripts/vm.sh" exec sync) >/dev/null 2>&1
check_eq "$(cat "$SANDBOX/real/hits" 2>/dev/null)" "" "nor does a sync a test sends the guest itself"
check_contains "$(cat "$FLTH_TEST_STUB/calls")" "sync" "which is logged as a call"
(cd "$SANDBOX/consumer" && "$H/scripts/vm.sh" down) >/dev/null 2>&1
check_eq "$(cat "$SANDBOX/real/hits" 2>/dev/null)" "" "nor does a down"

finish stub-engine-sync
