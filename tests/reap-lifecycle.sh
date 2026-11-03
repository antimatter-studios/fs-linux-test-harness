#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
mkdir -p "$SANDBOX/harness/scripts/lib" "$SANDBOX/consumer"
cp -R "$REPO/scripts/." "$SANDBOX/harness/scripts/"
make_consumer "$SANDBOX/one" reap-one
make_consumer "$SANDBOX/two" reap-two
cat > "$SANDBOX/harness/scripts/lib/engine.sh" <<'STUB'
engine_prepare() { mkdir -p "$FLTH_MACHINE_DIR"; }
engine_identity() { echo "$FLTH_MACHINE_DIR/vagrant"; }
engine_alive() { [ "$(cat "$FLTH_MACHINE_DIR/state")" = running ]; }
engine_state() { cat "$FLTH_MACHINE_DIR/state"; }
engine_down() { echo stopped > "$FLTH_MACHINE_DIR/state"; }
STUB
mkdir -p "$FLTH_CACHE_DIR/machines/reap-one" "$FLTH_CACHE_DIR/machines/reap-two"
echo running > "$FLTH_CACHE_DIR/machines/reap-two/state"
cat > "$SANDBOX/consumer/chores.yml" <<EOF
version: '3'
lifecycle:
  after_all:
    - 'FLTH_CONFIG=$SANDBOX/one/fs-linux-test-harness.toml $SANDBOX/harness/scripts/vm.sh reap'
    - 'FLTH_CONFIG=$SANDBOX/two/fs-linux-test-harness.toml $SANDBOX/harness/scripts/vm.sh reap'
tasks:
  own:
    cmds:
      - 'printf "%s\\t%s\\n" "\$PPID" "\$(ps -o lstart= -p "\$PPID" | sed "s/^ *//")" > "$FLTH_CACHE_DIR/machines/reap-one/boot-invocation"; echo running > "$FLTH_CACHE_DIR/machines/reap-one/state"'
  unrelated:
    cmds: ['true']
EOF
chore -C "$SANDBOX/consumer" own > "$SANDBOX/own.log" 2>&1
check_eq "$?" 0 "a chore invocation with two lifecycle reapers succeeds"
check_eq "$(cat "$FLTH_CACHE_DIR/machines/reap-one/state")" stopped "after_all stops the VM this invocation owns"
check_eq "$(cat "$FLTH_CACHE_DIR/machines/reap-two/state")" running "the same lifecycle sweep leaves the other consumer's VM running"
check_contains "$(cat "$SANDBOX/own.log")" 'another invocation' "the foreign VM is protected even while idle"
chore -C "$SANDBOX/consumer" unrelated > "$SANDBOX/unrelated.log" 2>&1
check_eq "$(cat "$FLTH_CACHE_DIR/machines/reap-two/state")" running "a later unrelated chore still does not take ownership"
finish reap-lifecycle
