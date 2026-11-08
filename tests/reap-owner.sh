#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_chore || finish reap-owner
new_sandbox
mkdir -p "$SANDBOX/harness/scripts/lib" "$SANDBOX/consumer" "$SANDBOX/bin"
cp -R "$REPO/scripts/." "$SANDBOX/harness/scripts/"
make_consumer "$SANDBOX/consumer" reap-owner
export FLTH_CONFIG="$SANDBOX/consumer/fs-linux-test-harness.toml"
export FLTH_TEST_OWNER_STATE="$SANDBOX/guest-state"
echo running > "$FLTH_TEST_OWNER_STATE"
cat > "$SANDBOX/harness/scripts/lib/engine.sh" <<'STUB'
engine_prepare() { mkdir -p "$FLTH_MACHINE_DIR"; }
engine_identity() { echo "$FLTH_MACHINE_DIR/vagrant"; }
engine_alive() { [ "$(cat "$FLTH_TEST_OWNER_STATE")" = running ]; }
engine_state() { cat "$FLTH_TEST_OWNER_STATE"; }
engine_down() { echo stopped > "$FLTH_TEST_OWNER_STATE"; }
STUB
cat > "$SANDBOX/consumer/chores.yml" <<EOF
version: '3'
lifecycle:
  after_all:
    - '$SANDBOX/harness/scripts/vm.sh reap'
tasks:
  unrelated:
    cmds: ['true']
EOF
chore -C "$SANDBOX/consumer" unrelated > "$SANDBOX/reap.log" 2>&1
check_eq "$?" 0 "an unrelated chore invocation succeeds"
check_eq "$(cat "$FLTH_TEST_OWNER_STATE")" running "after_all does not stop another run's idle VM"
check_contains "$(cat "$SANDBOX/reap.log")" 'another invocation' "the reaper names why it leaves another run's VM alone"
"$SANDBOX/harness/scripts/vm.sh" reap > "$SANDBOX/manual.log" 2>&1
check_eq "$(cat "$FLTH_TEST_OWNER_STATE")" stopped "an explicit manual reap can still stop a leaked VM"
finish reap-owner
