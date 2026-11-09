#!/usr/bin/env bash
#
# boot-kernel.sh — the next boot runs the kernel a provisioning boot
# installed, on the one host whose guest does not choose its own (#80).
#
# The macOS box starts QEMU with `-kernel` and `-initrd` naming files beside
# the box, so nothing in the guest's /boot is ever read, and a kernel a setup
# script installs is never run. Linux guests boot through their own GRUB and
# are not touched.
#
# Driven through vm.sh and the real Vagrant engine, with `vagrant`, `ssh`,
# `ps` and `uname` stubbed: what is pinned is what each boot is told to run.
# That QEMU honours it, and the guest then reports that kernel, is proven by
# tests/smoke.sh against a real guest.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

# Short on purpose, as in tests/engine-vagrant.sh: on macOS the socket
# directory under it is refused when too long, and the sandbox is under
# whatever TMPDIR ran this test.
FLTH_STATE_DIR="$(mktemp -d "${FLTH_TEST_SOCKET_ROOT:-/tmp}/flth.XXXXXX")"
export FLTH_STATE_DIR
# shellcheck disable=SC2064  # expand now: the paths are fixed
trap "rm -rf '$SANDBOX' '$FLTH_STATE_DIR'" EXIT

require_guest_bash || exit 1
BIN="$SANDBOX/bin"
export STUBDIR="$SANDBOX/stubdir"
export GUEST="$SANDBOX/guest"
mkdir -p "$BIN" "$STUBDIR" "$GUEST"
# The setup call re-arms the guest's poweroff, and this is not a guest.
printf '#!/bin/sh\nexit 0\n' > "$BIN/shutdown"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
printf '#!/bin/sh\nexit 0\n' > "$BIN/shutdown"

# vagrant: `up` records what the boot was told to run; the machine's state
# lives in $STUBDIR/status.
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    up)
        echo "disposable=$FLTH_VM_DISPOSABLE kernel=${FLTH_VM_BOOT_KERNEL:-none} initrd=${FLTH_VM_BOOT_INITRD:-none}" >> "$STUBDIR/boots"
        echo running > "$STUBDIR/status"
        ;;
    halt) echo stopped > "$STUBDIR/status" ;;
    destroy) echo not_created > "$STUBDIR/status" ;;
    status) echo "1700000000,default,state,$(cat "$STUBDIR/status")" ;;
    ssh-config) printf 'Host default\n' ;;
esac
exit 0
STUB
# ssh: the script on stdin runs here, with the guest's /boot and the setup
# stamp's directory moved into the sandbox. Opening or closing the shared
# connection does nothing.
cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in -N | -O) exit 0 ;; esac
done
# To the end of the script, not of stdin: a call into the guest holds stdin open
# for as long as it lives, and ends its script with this line. The rest of stdin
# stays the script's own, as it is on a guest.
script=""
while IFS= read -r line; do
    script="$script$line
"
    [ "$line" != 'exit "$flth_status"' ] || { script="$script}
"; break; }
done
run="$STUBDIR/guest-run.$$"
printf '%s' "$script" |
    sed -e "s|/boot|$GUEST/boot|g" -e "s|/var/lib/fs-linux-test-harness|$GUEST/lib|g" -e "s|/run/fs-linux-test-harness|$GUEST/run-|g" |
    tee -a "$STUBDIR/guest-scripts" > "$run"
"$FLTH_TEST_GUEST_BASH" "$run"
rc=$?
rm -f "$run"
exit "$rc"
STUB
# ps: a QEMU naming the machine's disk while the machine is running.
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = -eo ] && [ "${2:-}" = args= ]; then
    echo init
    [ "$(cat "$STUBDIR/status")" = running ] && echo "qemu-system-aarch64 -drive file=$VAGRANT_DOTFILE_PATH/disk"
    exit 0
fi
exec /bin/ps "$@"
STUB
# The script of a provisioning boot, run here by the ssh above (#191).
printf '#!/bin/sh\nexit 0\n' > "$BIN/sync"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
host() {
    printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo %s ;; esac\n' "$1" "$2" > "$BIN/uname"
    chmod +x "$BIN/uname"
}

HARNESS="$SANDBOX/harness"
mkdir -p "$HARNESS"
cp -R "$REPO/scripts" "$REPO/vagrant" "$HARNESS/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HARNESS/scripts/host-tools.sh"
VM="$HARNESS/scripts/vm.sh"

C="$SANDBOX/consumer"
make_consumer "$C" boot-kernel-test
MACHINE="$FLTH_CACHE_DIR/machines/boot-kernel-test"
KERNEL="$MACHINE/boot/vmlinuz"
INITRD="$MACHINE/boot/initrd.img"
export SETUP_LOG="$SANDBOX/setup.log"

vm() { (cd "$C" && "$VM" "$@"); }
# vm_kept <args>: a vm call whose output no check reads. A passing run does not
# show what it printed; its stderr and exit status are kept, and a failing run
# prints them for every such call, so an `up` that stopped says why (#210).
VM_CALLS="$SANDBOX/vm-calls"
: > "$VM_CALLS"
vm_kept() {
    local rc
    vm "$@" 2> "$SANDBOX/vm-call.err"
    rc=$?
    {
        printf 'vm %s: exit %s\n' "$*" "$rc"
        sed 's/^/    /' "$SANDBOX/vm-call.err"
    } >> "$VM_CALLS"
    return "$rc"
}
boots() { cat "$STUBDIR/boots" 2>/dev/null; }
forget_boots() { rm -f "$STUBDIR/boots" "$STUBDIR/guest-scripts"; }
setup_runs() { grep -c . "$SETUP_LOG" 2>/dev/null | tr -d ' '; }
ON_BOX="kernel=none initrd=none"
ON_DISK="kernel=$KERNEL initrd=$INITRD"

# A disk as the box ships it: Raspberry Pi kernels in /boot, which the box
# has never booted, and none of the kernel it boots.
fresh_disk() {
    rm -rf "$GUEST" "$SETUP_LOG"
    mkdir -p "$GUEST/boot" "$GUEST/lib"
    local release
    for release in 6.6.51+rpt-rpi-2712 6.6.51+rpt-rpi-v8; do
        echo "box kernel $release" > "$GUEST/boot/vmlinuz-$release"
        echo "box initrd $release" > "$GUEST/boot/initrd.img-$release"
    done
    forget_boots
    echo not_created > "$STUBDIR/status"
}

# setup_installs <release>...: a setup script that installs these kernels.
# The script travels encoded, so it reaches the guest's /boot through $GUEST.
setup_installs() {
    local release
    {
        echo '#!/usr/bin/env bash'
        echo 'echo ran >> "$SETUP_LOG"'
        for release in "$@"; do
            echo "echo 'disk kernel $release' > \"\$GUEST/boot/vmlinuz-$release\""
            echo "echo 'disk initrd $release' > \"\$GUEST/boot/initrd.img-$release\""
        done
    } > "$C/setup.sh"
}

# --- which kernel the disk offers -------------------------------------------

newest() {
    local dir="$1" script
    script="$(sed "s|/boot|$dir|g" "$REPO/vagrant/guest/newest-kernel.sh" 2>/dev/null)"
    [ -n "$script" ] || { echo "no vagrant/guest/newest-kernel.sh"; return 1; }
    printf '%s\n' "$script" | bash -s 2>&1
}
offer() {
    local dir="$SANDBOX/offer" release
    rm -rf "$dir"
    mkdir -p "$dir"
    for release in "$@"; do
        : > "$dir/vmlinuz-$release"
        : > "$dir/initrd.img-$release"
    done
    printf '%s\n' "$dir"
}
check_eq "$(newest "$(offer)")" "" "a /boot with no kernels offers none"
check_eq "$(newest "$(offer 6.6.51+rpt-rpi-2712 6.6.51+rpt-rpi-v8)")" "" \
    "the box's Raspberry Pi kernels are not offered, though they are newer than the kernel it boots"
check_eq "$(newest "$(offer 6.6.51+rpt-rpi-v8 6.12.95+deb12-arm64)")" 6.12.95+deb12-arm64 \
    "a kernel the setup installed is offered"
check_eq "$(newest "$(offer 6.1.0-44-arm64 6.12.95+deb12-arm64 6.9.7+bpo-arm64)")" 6.12.95+deb12-arm64 \
    "the newest by version, not by the order of its name: 6.12 is newer than 6.9"
dir="$(offer 6.12.95+deb12-arm64)"
rm -f "$dir/initrd.img-6.12.95+deb12-arm64"
out="$(newest "$dir")"
check_eq "$?" 1 "a kernel with no initrd is refused rather than started without one"
check_contains "$out" "initrd.img-6.12.95+deb12-arm64" "naming the file it looked for"

# --- macOS: the next boot runs what the setup installed ----------------------

host Darwin arm64

fresh_disk
setup_installs 6.12.95+deb12-arm64
vm_kept up
check_eq "$?" 0 "up succeeds when the setup installs a kernel"
check_eq "$(boots)" "disposable=0 $ON_BOX
disposable=1 $ON_DISK" \
    "the provisioning boot runs the box's kernel, and the next boot the one it installed"
check_eq "$(cat "$KERNEL" 2>/dev/null)" "disk kernel 6.12.95+deb12-arm64" "with the bytes of the guest's own kernel"
check_eq "$(cat "$INITRD" 2>/dev/null)" "disk initrd 6.12.95+deb12-arm64" "and of its initrd"

vm_kept down
forget_boots
vm_kept up
check_eq "$(boots)" "disposable=1 $ON_DISK" "a later cold boot runs it too, with no provisioning boot"
vm_kept down

setup_installs 6.12.95+deb12-arm64 6.16.3+deb12-arm64
forget_boots
vm_kept up
check_eq "$(boots)" "disposable=0 $ON_DISK
disposable=1 $ON_DISK" "a changed setup is applied from the kernel the disk already runs"
check_eq "$(cat "$KERNEL" 2>/dev/null)" "disk kernel 6.16.3+deb12-arm64" "and the next boot runs the newer one it installed"
check_eq "$(cat "$INITRD" 2>/dev/null)" "disk initrd 6.16.3+deb12-arm64" "with its own initrd"
vm_kept down

# --- a disk provisioned before the harness kept a kernel ---------------------

rm -rf "${MACHINE:?}/boot"
runs="$(setup_runs)"
forget_boots
vm_kept up
check_eq "$(boots)" "disposable=0 $ON_BOX
disposable=1 $ON_DISK" "a machine provisioned by an earlier harness takes one provisioning boot to find its kernel"
check_eq "$(setup_runs)" "$runs" "and the setup is not run again: the disk carries it"
vm_kept down

# --- a destroyed machine's kernel goes with its disk -------------------------

vm_kept destroy
check_eq "$(test -e "$KERNEL" && echo kept || echo gone)" gone "destroy deletes the kept kernel with the disk that holds its modules"
check_eq "$(test -e "$INITRD" && echo kept || echo gone)" gone "and its initrd"

fresh_disk
setup_installs
mkdir -p "$MACHINE/boot"
echo stale > "$KERNEL"
echo stale > "$INITRD"
echo stale > "$MACHINE/boot/release"
vm_kept up
check_eq "$(boots)" "disposable=0 $ON_BOX
disposable=1 $ON_BOX" "a machine that no longer exists boots a new disk on the box's kernel, whatever was kept"
vm_kept destroy

# --- a setup that installs no kernel changes nothing --------------------------

fresh_disk
setup_installs
vm_kept up
check_eq "$(boots)" "disposable=0 $ON_BOX
disposable=1 $ON_BOX" "a setup that installs no kernel leaves every boot on the box's"
vm_kept down
forget_boots
vm_kept up
check_eq "$(boots)" "disposable=1 $ON_BOX" "and does not provision again on each cold boot to find that out"
vm_kept destroy

# --- a kernel that cannot be kept fails the provisioning ---------------------

fresh_disk
{
    echo '#!/usr/bin/env bash'
    echo 'echo ran >> "$SETUP_LOG"'
    echo 'echo "disk kernel 6.12.95+deb12-arm64" > "$GUEST/boot/vmlinuz-6.12.95+deb12-arm64"'
} > "$C/setup.sh"
out="$(vm up 2>&1)"
rc=$?
check_eq "$([ "$rc" -ne 0 ] && echo failed || echo passed)" failed "up fails when the kernel the setup installed has no initrd"
check_contains "$out" "initrd.img-6.12.95+deb12-arm64" "naming it"
check_eq "$(test -e "$MACHINE/base.sha256" && echo recorded || echo none)" none "and the disk is not recorded as provisioned"
check_eq "$(cat "$STUBDIR/status")" running "the provisioning boot is left up to be inspected, as a failed setup's is"
vm_kept down
echo "disk initrd 6.12.95+deb12-arm64" > "$GUEST/boot/initrd.img-6.12.95+deb12-arm64"
forget_boots
vm_kept up
check_eq "$?" 0 "the next up provisions again"
check_eq "$(boots)" "disposable=0 $ON_BOX
disposable=1 $ON_DISK" "and the next boot runs the kernel"
check_eq "$(setup_runs)" 1 "without running a setup the guest records as applied"
vm_kept destroy

# --- Linux guests choose for themselves --------------------------------------

for arch in x86_64 aarch64; do
    host Linux "$arch"
    fresh_disk
    setup_installs 6.12.95+deb12-arm64
    vm_kept up
    check_eq "$?" 0 "Linux $arch: up succeeds"
    check_eq "$(boots)" "disposable=0 $ON_BOX
disposable=1 $ON_BOX" "Linux $arch: QEMU is never told which kernel to run"
    check_lacks "$(cat "$STUBDIR/guest-scripts")" "vmlinuz" "Linux $arch: and the guest's kernels are not asked about"
    check_eq "$(test -e "$MACHINE/boot" && echo kept || echo none)" none "Linux $arch: and nothing is kept for it"
    vm_kept down
    forget_boots
    vm_kept up
    check_eq "$(boots)" "disposable=1 $ON_BOX" "Linux $arch: a cold boot is one disposable boot, with nothing to find out"
    vm_kept destroy
done

if [ "$fails" -gt 0 ]; then
    echo "every vm call no check read, in order, with its exit status and its stderr:"
    sed 's/^/  /' "$VM_CALLS"
fi

finish boot-kernel
