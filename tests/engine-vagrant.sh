#!/usr/bin/env bash
#
# engine-vagrant.sh — scripts/lib/engine-vagrant.sh against stubbed
# `vagrant`, `ssh`, `ps` and `uname`.
#
# What is pinned: the mapping of Vagrant's states onto the engine's four,
# with `unknown` wherever the answer was not actually given; waiting out
# Vagrant's machine lock; the process match that liveness and the reaper
# rest on; and the rule that a script is only sent twice when the
# connection changed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

BIN="$SANDBOX/bin"
mkdir -p "$BIN"
export STUBDIR="$SANDBOX/stubdir"
mkdir -p "$STUBDIR"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"

# vagrant: `status` answers from $STUBDIR/status (a Vagrant state name),
# refusing with the lock message $STUBDIR/locked times first; `ssh-config`
# prints $STUBDIR/ssh-config; everything is logged.
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
echo "vagrant $* cwd=$PWD dot=$VAGRANT_DOTFILE_PATH" >> "$STUBDIR/log"
n="$(cat "$STUBDIR/locked" 2>/dev/null || echo 0)"
if [ "$n" -gt 0 ]; then
    echo $((n - 1)) > "$STUBDIR/locked"
    echo "An action 'status' was attempted on the machine 'default', but another process is already executing an action on the machine. Vagrant locks each machine for access by only one process at a time." >&2
    exit 1
fi
case "$1" in
    status)
        [ -f "$STUBDIR/status" ] || { echo "boom" >&2; exit 1; }
        echo "1700000000,default,metadata,provider,qemu"
        echo "1700000000,default,state,$(cat "$STUBDIR/status")"
        ;;
    ssh-config) cat "$STUBDIR/ssh-config" ;;
esac
exit 0
STUB
# ssh: runs the script from stdin locally; exits $STUBDIR/ssh-exit
# (default: the script's own status); counts invocations.
cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh $*" >> "$STUBDIR/ssh-log"
if [ -f "$STUBDIR/ssh-exit" ]; then cat > /dev/null; exit "$(cat "$STUBDIR/ssh-exit")"; fi
bash -s
STUB
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
[ -f "$STUBDIR/ps-fails" ] && exit 1
cat "$STUBDIR/ps" 2>/dev/null
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

make_consumer "$SANDBOX/c" engine-test
export FLTH_CONFIG="$SANDBOX/c/fs-linux-test-harness.toml"
. "$REPO/scripts/lib/common.sh"
flth_load
engine_prepare
ID="$(engine_identity)"

check_eq "$VAGRANT_DOTFILE_PATH" "$FLTH_CACHE_DIR/machines/engine-test/vagrant" "machine state goes to the consumer's machine directory"
check_eq "$VAGRANT_CWD" "$REPO/vagrant" "the Vagrantfile is the harness's own"
check_eq "$FLTH_VM_NAME|$FLTH_VM_MEMORY|$FLTH_VM_CPUS|$FLTH_VM_DISK|$FLTH_VM_SSH_PORT|$FLTH_VM_DEADLINE_MINUTES" \
    "engine-test|4G|4|32G|50122|480" "the config reaches the Vagrantfile through FLTH_VM_*"
# shellcheck disable=SC2153  # exported by engine_prepare
check_eq "$FLTH_SHARE_DIR" "$(cd "$SANDBOX/c" && pwd -P)/.vm-share" "and the share as an absolute host path"
check_eq "$ID" "$VAGRANT_DOTFILE_PATH" "the identity is the dotfile path, which QEMU's disk path contains"

# --- firmware links, by host ---------------------------------------------

fw_for() {
    # fw_for <uname -s> <uname -m>
    printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo %s ;; esac\n' "$1" "$2" > "$BIN/uname"
    chmod +x "$BIN/uname"
    unset FLTH_QEMU_DIR
    rm -rf "$FLTH_CACHE_DIR/firmware"
    FLTH_FIRMWARE_CODE=/fw/code.fd FLTH_FIRMWARE_VARS=/fw/vars.fd engine_prepare
}
fw_for Linux aarch64
check_eq "${FLTH_QEMU_DIR:-}" "$FLTH_CACHE_DIR/firmware" "Linux aarch64 gets a firmware directory"
check_eq "$(readlink "$FLTH_QEMU_DIR/edk2-aarch64-code.fd")|$(readlink "$FLTH_QEMU_DIR/edk2-arm-vars.fd")" \
    "/fw/code.fd|/fw/vars.fd" "linking the provider's names to the host's firmware"
fw_for Linux x86_64
check_eq "${FLTH_QEMU_DIR:-unset}" unset "Linux x86_64 needs no firmware (SeaBIOS)"
fw_for Darwin arm64
check_eq "${FLTH_QEMU_DIR:-unset}" unset "macOS uses Homebrew QEMU's own firmware"
rm -f "$BIN/uname"

# --- engine_alive ---------------------------------------------------------

alive() { rc=0; engine_alive "$ID" || rc=$?; echo "$rc"; }
printf '%s\n' "/usr/bin/qemu-system-aarch64 -machine virt -drive file=$ID/machines/default/qemu/vq_x/linked-box.img" > "$STUBDIR/ps"
check_eq "$(alive)" 0 "a qemu-system process naming the machine's disk is alive"
printf '%s\n' "qemu-system-x86_64 -drive file=$ID/machines/default/qemu/x/linked-box.img" > "$STUBDIR/ps"
check_eq "$(alive)" 0 "matched by process name, with or without a path"
printf '%s\n' "bash -c pgrep -f $ID/machines/default/qemu" "vim $ID/notes" > "$STUBDIR/ps"
check_eq "$(alive)" 1 "a shell whose command line merely mentions the path is not a VM"
printf '%s\n' "qemu-system-aarch64 -drive file=${ID}-old/machines/default/linked-box.img" > "$STUBDIR/ps"
check_eq "$(alive)" 1 "another machine whose path merely starts with this one's is not this VM"
touch "$STUBDIR/ps-fails"
check_eq "$(alive)" 2 "an unreadable process table is 2, not 'not running'"
rm -f "$STUBDIR/ps-fails"; : > "$STUBDIR/ps"
check_eq "$(alive)" 2 "and so is an empty one"
printf 'init\n' > "$STUBDIR/ps"

# --- engine_state ---------------------------------------------------------

state_for() { rm -f "$STUBDIR/status"; [ -n "$1" ] && echo "$1" > "$STUBDIR/status"; engine_state 2>/dev/null; }
check_eq "$(state_for not_created)" absent "not_created is absent"
check_eq "$(state_for stopped)" stopped "stopped (stock provider) is stopped"
check_eq "$(state_for poweroff)" stopped "poweroff (macOS provider) is stopped"
check_eq "$(state_for paused)" unknown "a state it does not know is unknown"
check_eq "$(state_for '')" unknown "a status Vagrant could not give is unknown"
check_eq "$(state_for running)" unknown "Vagrant's 'running' with no VM process is a disagreement: unknown"
printf '%s\n' "qemu-system-aarch64 -drive file=$ID/machines/default/qemu/x/linked-box.img" > "$STUBDIR/ps"
: > "$STUBDIR/log"
check_eq "$(state_for stopped)" running "a live VM process is running"
check_eq "$(grep -c 'vagrant status' "$STUBDIR/log" | tr -d ' ')" 0 "without asking Vagrant (it costs seconds per call)"
touch "$STUBDIR/ps-fails"
check_eq "$(state_for running)" running "with the process table unreadable, Vagrant's answer stands"
rm -f "$STUBDIR/ps-fails"; printf 'init\n' > "$STUBDIR/ps"

echo 3 > "$STUBDIR/locked"; : > "$STUBDIR/log"
check_eq "$(state_for stopped)" stopped "a state behind Vagrant's machine lock is waited for"
check_eq "$(grep -c 'vagrant status' "$STUBDIR/log" | tr -d ' ')" 4 "retrying until the lock is released"
check_contains "$(cat "$STUBDIR/log")" "cwd=$REPO/vagrant" "running vagrant from the harness's Vagrantfile directory"

# --- engine_run -----------------------------------------------------------

printf 'Host default\n  Port 50122\n' > "$STUBDIR/ssh-config"
rm -f "$FLTH_MACHINE_DIR/ssh-config"
out="$(engine_run 'echo "quoted  spaces"; echo err >&2; exit 6' 2>"$SANDBOX/err")"
check_eq "$?" 6 "run returns the script's exit status"
check_eq "$out" "quoted  spaces" "and its stdout, quoting intact"
check_eq "$(cat "$SANDBOX/err")" "err" "and its stderr"
check_eq "$(cat "$FLTH_MACHINE_DIR/ssh-config")" "$(cat "$STUBDIR/ssh-config")" "ssh settings are cached from vagrant ssh-config"
check_contains "$(cat "$STUBDIR/ssh-log")" "-F $FLTH_MACHINE_DIR/ssh-config default -T sudo bash -s" "and used by plain ssh, script on stdin, as root"

: > "$STUBDIR/log"; : > "$STUBDIR/ssh-log"
engine_run 'true'
check_eq "$(grep -c ssh-config "$STUBDIR/log" | tr -d ' ')" 0 "a cached config costs no vagrant call"

echo 255 > "$STUBDIR/ssh-exit"; : > "$STUBDIR/ssh-log"
engine_run 'true'; rc=$?
check_eq "$rc" 255 "a 255 with unchanged settings is returned, not retried"
check_eq "$(grep -c . "$STUBDIR/ssh-log" | tr -d ' ')" 1 "so a script that may already have run is sent once"

printf 'Host default\n  Port 50123\n' > "$STUBDIR/ssh-config"; : > "$STUBDIR/ssh-log"
engine_run 'true'
check_eq "$(grep -c . "$STUBDIR/ssh-log" | tr -d ' ')" 2 "a 255 after which the settings changed is sent again"
check_contains "$(cat "$FLTH_MACHINE_DIR/ssh-config")" "50123" "with the refreshed settings"
rm -f "$STUBDIR/ssh-exit"

# --- engine_copy ------------------------------------------------------------

echo data > "$SANDBOX/img.bin"
check_eq "$(engine_copy "$SANDBOX/img.bin")" "/share/img.bin" "copy prints the guest path"
check_eq "$(cat "$FLTH_SHARE_HOST/img.bin")" data "and the file is in the share"

finish engine-vagrant
