#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
FLTH_HARNESS="$REPO"
. "$REPO/scripts/lib/engine-vagrant.sh"
CFG_vm_ssh_port=50200

start_machine() {
    FLTH_MACHINE_DIR="$SANDBOX/$1"
    VAGRANT_DOTFILE_PATH="$FLTH_MACHINE_DIR/vagrant"
    key="$VAGRANT_DOTFILE_PATH/machines/default/qemu/private_key"
    mkdir -p "$(dirname "$key")"
    printf '%s\n' "$2" > "$FLTH_MACHINE_DIR/state"
    : > "$FLTH_MACHINE_DIR/events"
    unset FLTH_PROFILE_ID
}

event() { printf '%s\n' "$1" >> "$FLTH_MACHINE_DIR/events"; }
events() { cat "$FLTH_MACHINE_DIR/events"; }
ready() { [ ! -f "$FLTH_MACHINE_DIR/disk-tmp-ready" ] || echo ready; }
engine_state() { cat "$FLTH_MACHINE_DIR/state"; }
engine_vagrant_tmpdir() { printf '%s\n' "$SANDBOX"; }
engine_vagrant_ssh_port() { printf '%s\n' "$1"; }
engine_ssh_close() { :; }
engine_ssh_config() { :; }
engine_vagrant_forget_attached() { :; }
engine_vagrant_stop_forwarders() { :; }
engine_forget_kernel() { :; }
engine_alive() { [ "$(engine_state)" = running ]; }
sleep() { SECONDS=$((SECONDS + 120)); }
engine_vagrant_up() {
    event "up:$FLTH_VM_DISPOSABLE:key=$(cat "$key" 2>/dev/null || true)"
    if [ "$FLTH_VM_DISPOSABLE" = 0 ] && [ ! -f "$key" ]; then printf prepared > "$key"; fi
    printf 'running\n' > "$FLTH_MACHINE_DIR/state"
}
engine_run() {
    case "$1" in *tmp.mount*findmnt*sync*) event verify ;; *) return 1 ;; esac
    [ ! -f "$FLTH_MACHINE_DIR/verify-fails" ] || return 1
    case "$1" in *systemd-run*poweroff*) event poweroff ;; *) return 1 ;; esac
    if [ ! -f "$FLTH_MACHINE_DIR/stays-running" ]; then
        printf 'stopped\n' > "$FLTH_MACHINE_DIR/state"
        if [ ! -f "$FLTH_MACHINE_DIR/was-killed" ]; then
            printf 'reboot: Power down\n' > "$(engine_console_log)"
        fi
    fi
}
engine_vagrant() {
    [ "$1" = halt ] || return 1
    event halt
    if [ ! -f "$FLTH_MACHINE_DIR/stays-running" ]; then
        printf 'stopped\n' > "$FLTH_MACHINE_DIR/state"
    fi
    [ ! -f "$FLTH_MACHINE_DIR/halt-fails" ]
}
engine_vagrant_retrying() {
    [ "$1" = destroy ] || return 1
    printf 'absent\n' > "$FLTH_MACHINE_DIR/state"
}

start_machine fresh absent
engine_up 2>"$SANDBOX/fresh.err"
check_eq "$?" 0 'first boot succeeds'
check_eq "$(events)" $'up:0:key=\nverify\npoweroff\nhalt\nup:1:key=prepared' 'first boot verifies and powers off before booting disposable'
check_eq "$(ready)" ready 'a verified stopped disk has a readiness marker'
printf 'stopped\n' > "$FLTH_MACHINE_DIR/state"
: > "$FLTH_MACHINE_DIR/events"
engine_up 2>"$SANDBOX/reuse.err"
check_eq "$(events)" 'up:1:key=prepared' 'a reused disk keeps its key and boots without preparation'
engine_destroy 2>"$SANDBOX/destroy.err"
check_eq "$(ready)" '' 'destroy invalidates readiness'
check_eq "$(test -f "$key" && echo key)" '' 'destroy forgets the key of the removed disk'
: > "$FLTH_MACHINE_DIR/events"
engine_up 2>"$SANDBOX/recreate.err"
check_eq "$(events)" $'up:0:key=\nverify\npoweroff\nhalt\nup:1:key=prepared' 'a recreated disk must be prepared again'

start_machine cached stopped
printf legacy > "$key"
touch "$FLTH_MACHINE_DIR/verify-fails"
engine_up 2>"$SANDBOX/verify.err"
check_eq "$?" 1 'failed guest verification refuses boot'
check_eq "$(events)" $'up:0:key=\nverify\nhalt' 'an existing shared disk prepares with its box key and never boots disposable on failure'
check_eq "$(ready)" '' 'failed guest verification does not certify the disk'
mv "$FLTH_MACHINE_DIR/verify-fails" "$SANDBOX/verified-retry"
: > "$FLTH_MACHINE_DIR/events"
engine_up 2>"$SANDBOX/retry.err"
check_eq "$?" 0 'a failed preparation is retryable'
check_eq "$(events)" $'up:0:key=prepared\nverify\npoweroff\nhalt\nup:1:key=prepared' 'retry preserves the key authorized on the base disk'

start_machine halt-failed stopped
touch "$FLTH_MACHINE_DIR/halt-fails"
engine_up 2>"$SANDBOX/halt.err"
check_eq "$?" 1 'a failed halt refuses boot even if reported stopped'
check_eq "$(ready)" '' 'a failed halt does not certify the disk'

start_machine unconfirmed stopped
touch "$FLTH_MACHINE_DIR/stays-running"
engine_up 2>"$SANDBOX/unconfirmed.err"
check_eq "$?" 1 'a guest still running after the power-off deadline refuses boot'
check_eq "$(ready)" '' 'an unconfirmed shutdown does not certify the disk'

start_machine killed stopped
touch "$FLTH_MACHINE_DIR/was-killed"
engine_up 2>"$SANDBOX/killed.err"
check_eq "$?" 1 'a guest that exits without a clean power-off refuses boot'
check_eq "$(ready)" '' 'an abrupt stop does not certify the disk'

start_machine unreadable unknown
engine_up 2>"$SANDBOX/unknown.err"
check_eq "$?" 1 'an unreadable machine state refuses disk preparation'
check_eq "$(events)" '' 'no second guest is booted beside an unknown one'

start_machine profile stopped
FLTH_PROFILE_ID=profile-fingerprint
printf profile > "$key"
engine_up --persist 2>"$SANDBOX/profile.err"
check_eq "$(events)" $'up:0:key=profile\nverify\npoweroff\nhalt\nup:0:key=profile' 'a persistent profile boot retains its established key'

finish disk-tmp-lifecycle
