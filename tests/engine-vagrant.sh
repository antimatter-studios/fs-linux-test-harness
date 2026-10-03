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
echo "vagrant $* cwd=$PWD dot=$VAGRANT_DOTFILE_PATH disposable=${FLTH_VM_DISPOSABLE:-unset} tmpdir=${TMPDIR:-}" >> "$STUBDIR/log"
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
tee "$STUBDIR/stdin" | bash -s
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
check_eq "$(state_for stopped)" stopped "stopped (the stock provider and the macOS fork) is stopped"
check_eq "$(state_for poweroff)" stopped "poweroff is stopped"
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
check_contains "$(cat "$STUBDIR/ssh-log")" "-F $FLTH_MACHINE_DIR/ssh-config" "ssh is plain ssh with those settings"
check_contains "$(cat "$STUBDIR/ssh-log")" "default -T sudo bash -s" "with the script on stdin, run as root"
check_contains "$(cat "$STUBDIR/ssh-log")" "-o ControlPath=$FLTH_STATE_DIR/ssh/" "over a shared connection, whose socket is short and outside every repository"
check_contains "$(cat "$STUBDIR/ssh-log")" "-o ControlMaster=yes" "the master is opened deliberately"
check_contains "$(cat "$STUBDIR/stdin")" "export FLTH_GUEST=1" "a command run in the guest is told it is in the guest"
check_contains "$(cat "$STUBDIR/ssh-log")" "-N -f default" "detached, with no command and none of the caller's streams"
check_lacks "$(grep 'bash -s' "$STUBDIR/ssh-log")" "ControlMaster" "and the call that carries the script is only a client of it"

: > "$STUBDIR/log"; : > "$STUBDIR/ssh-log"
engine_run 'true'
check_eq "$(grep -c ssh-config "$STUBDIR/log" | tr -d ' ')" 0 "a cached config costs no vagrant call"

echo 255 > "$STUBDIR/ssh-exit"; : > "$STUBDIR/ssh-log"
engine_run 'true'; rc=$?
check_eq "$rc" 255 "a 255 with unchanged settings is returned, not retried"
check_eq "$(grep -c 'bash -s' "$STUBDIR/ssh-log" | tr -d ' ')" 1 "so a script that may already have run is sent once"

printf 'Host default\n  Port 50123\n' > "$STUBDIR/ssh-config"; : > "$STUBDIR/ssh-log"
engine_run 'true'
check_eq "$(grep -c 'bash -s' "$STUBDIR/ssh-log" | tr -d ' ')" 2 "a 255 after which the settings changed is sent again"
check_contains "$(cat "$FLTH_MACHINE_DIR/ssh-config")" "50123" "with the refreshed settings"
rm -f "$STUBDIR/ssh-exit"

# --- the virtiofs socket's directory ---------------------------------------

# The macOS provider creates each virtiofs socket as
# $TMPDIR/vqemu-<machine id>-virtiofs<n>.sock, and a Unix socket path is
# limited to about 104 bytes. The caller's TMPDIR can be anything — a
# consumer's scratch directory inside its checkout — so `vagrant up` is
# given a short one the harness controls.
: > "$STUBDIR/log"
deep="$SANDBOX/a-consumer-checkout-somewhere/with/a/scratch/directory/that/is/deep/enough/to/overflow/tmp"
mkdir -p "$deep"
# The state directory is short here on purpose: the sandbox lives under
# whatever TMPDIR ran this test, which is the very thing being ruled out.
short_state="$(mktemp -d /tmp/flth.XXXXXX)"
FLTH_STATE_DIR="$short_state" TMPDIR="$deep" engine_up 2>/dev/null
check_eq "$?" 0 "up succeeds with a deep caller TMPDIR"
up_tmp="$(sed -n 's/^vagrant up .* tmpdir=//p' "$STUBDIR/log")"
check_eq "$up_tmp" "$short_state/tmp" "vagrant up is given the harness's own short TMPDIR, not the caller's"
mode="$(stat -c %a "$up_tmp" 2>/dev/null || stat -f %Lp "$up_tmp")"
check_eq "${mode: -3}" 700 "a directory only this user can use"
rm -rf "$short_state"

long_state="$SANDBOX/$(printf 'x%.0s' $(seq 1 80))"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"; chmod +x "$BIN/uname"
: > "$STUBDIR/log"
out="$(FLTH_STATE_DIR="$long_state" TMPDIR="$deep" engine_up 2>&1)"
check_eq "$?" 1 "on macOS, up refuses when even the harness's socket directory is too long for a socket"
check_contains "$out" "$long_state/tmp" "naming the path"
check_contains "$out" "$(( ${#long_state} + 4 + 36 )) bytes" "and how long the socket path would be"
check_eq "$(grep -c 'vagrant up' "$STUBDIR/log" | tr -d ' ')" 0 "without starting a boot that cannot share"
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' > "$BIN/uname"
FLTH_STATE_DIR="$long_state" TMPDIR="$deep" engine_up 2>/dev/null
check_eq "$?" 0 "on Linux, which shares over 9p and makes no socket, the same path boots"
rm -f "$BIN/uname"

# --- disposable and provisioning boots ---------------------------------------

# The Vagrantfile is evaluated by every vagrant command, `status` and
# `halt` included, so the flag is always exported; only `up` reads it.
check_eq "${FLTH_VM_DISPOSABLE:-unset}" 1 "every Vagrant call sees a disposable machine unless told otherwise"
: > "$STUBDIR/log"
engine_up 2>/dev/null
check_contains "$(grep '^vagrant up' "$STUBDIR/log")" "disposable=1" "a plain up boots disposable: the run's writes are discarded"
: > "$STUBDIR/log"
engine_up --persist 2>/dev/null
check_contains "$(grep '^vagrant up' "$STUBDIR/log")" "disposable=0" "up --persist boots a machine whose writes reach its disk"
check_eq "${FLTH_VM_DISPOSABLE:-unset}" 1 "and only that boot: the next Vagrant call is back to disposable"

# --- engine_copy ------------------------------------------------------------

echo data > "$SANDBOX/img.bin"
check_eq "$(engine_copy "$SANDBOX/img.bin")" "/share/img.bin" "copy prints the guest path"
check_eq "$(cat "$FLTH_SHARE_HOST/img.bin")" data "and the file is in the share"

# --- the declared cache (#39) -----------------------------------------------

# A consumer with no [cache] gets no cache disk, and the Vagrantfile is
# told so in as many words: the variable is set, and empty.
check_eq "${FLTH_VM_CACHE_DISK-unset}" "" "no [cache]: the Vagrantfile is told there is no cache disk"
engine_up 2>/dev/null
check_eq "$(test -e "$FLTH_MACHINE_DIR/cache.img" && echo made || echo none)" none "and a boot makes none"

make_consumer "$SANDBOX/cached" cache-test '[cache]' 'size = "1G"'
export FLTH_CONFIG="$SANDBOX/cached/fs-linux-test-harness.toml"
flth_load
engine_prepare
disk="$FLTH_MACHINE_DIR/cache.img"
size_of() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }
check_eq "$FLTH_VM_CACHE_DISK" "$disk" "a declared cache is a disk in the machine directory, named to the Vagrantfile"
check_eq "$(test -e "$disk" && echo made || echo none)" none "made by a boot, not by every command that evaluates the Vagrantfile"
engine_up 2>/dev/null
check_eq "$(size_of "$disk")" $((1024 * 1024 * 1024)) "a boot makes it, the size [cache] declares"
check_eq "$(( $(du -k "$disk" | awk '{print $1}') < 1024 ))" 1 "sparse: it takes no space until the guest writes"
printf 'built once' | dd of="$disk" conv=notrunc bs=1 seek=4096 status=none 2>/dev/null ||
    printf 'built once' | dd of="$disk" conv=notrunc bs=1 seek=4096 2>/dev/null
engine_up 2>/dev/null
check_eq "$(dd if="$disk" bs=1 skip=4096 count=10 2>/dev/null)" "built once" "the next boot finds what the last one wrote there"
make_consumer "$SANDBOX/cached" cache-test '[cache]' 'size = "2G"'
flth_load
engine_prepare
out="$(engine_up 2>&1)"
check_eq "$(size_of "$disk")" $((2 * 1024 * 1024 * 1024)) "a changed size gets a disk of the new size"
check_eq "$(dd if="$disk" bs=1 skip=4096 count=10 2>/dev/null | tr -d '\0')" "" "an empty one: a cache is rebuilt, never resized under a filesystem"
check_contains "$out" "cache" "and says the cache was replaced"
engine_destroy 2>/dev/null
check_eq "$(test -e "$disk" && echo kept || echo gone)" gone "destroy deletes the cache with the machine"

finish engine-vagrant
