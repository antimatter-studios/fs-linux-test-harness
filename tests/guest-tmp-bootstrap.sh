#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
FLTH_HARNESS="$REPO"
. "$REPO/scripts/lib/engine-vagrant.sh"
FLTH_MACHINE_DIR="$SANDBOX/machine"
VAGRANT_DOTFILE_PATH="$FLTH_MACHINE_DIR/vagrant"
mkdir -p "$VAGRANT_DOTFILE_PATH/machines/default/qemu"
key="$VAGRANT_DOTFILE_PATH/machines/default/qemu/private_key"
printf old > "$key"
printf stopped > "$SANDBOX/state"
engine_state() { cat "$SANDBOX/state"; }
engine_up() {
    printf '%s/%s\n' "${FLTH_TMP_BOOTSTRAP:-unset}" "$1" >> "$SANDBOX/calls"
    printf prepared > "$key"
    printf running > "$SANDBOX/state"
}
engine_run() { [ ! -f "$SANDBOX/fail-sync" ]; }
engine_down() { printf stopped > "$SANDBOX/state"; }

engine_vagrant_prepare_disk_tmp
check_eq "$?" 0 'preparation succeeds'
check_eq "$(cat "$SANDBOX/calls")" '1/--persist' 'preparation boots the base disk persistently'
check_eq "$(cat "$key")" prepared 'the prepared disk keeps its matching key'
check_eq "$([ -f "$FLTH_MACHINE_DIR/disk-tmp-ready" ] && echo ready)" ready 'successful shutdown records preparation'
engine_vagrant_prepare_disk_tmp
check_eq "$(wc -l < "$SANDBOX/calls" | tr -d ' ')" 1 'a prepared disk is not bootstrapped again'
rm -f "$FLTH_MACHINE_DIR/disk-tmp-ready"
touch "$SANDBOX/fail-sync"
engine_vagrant_prepare_disk_tmp 2>/dev/null
check_eq "$?" 1 'verification failure refuses preparation'
check_eq "$([ -f "$FLTH_MACHINE_DIR/disk-tmp-ready" ] && echo ready)" '' 'failed verification never records readiness'
check_eq "$([ -f "$FLTH_MACHINE_DIR/disk-tmp-started" ] && echo started)" started 'failed preparation remains retryable'
rm -f "$SANDBOX/fail-sync"
engine_vagrant_prepare_disk_tmp
check_eq "$?" 0 'interrupted preparation can be retried'
finish guest-tmp-bootstrap
