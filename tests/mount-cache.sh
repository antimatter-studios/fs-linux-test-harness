#!/usr/bin/env bash
#
# mount-cache.sh — vagrant/guest/mount-cache.sh, which puts a consumer's
# declared cache disk (#39) at its mount point on every boot, run here
# against stubbed udevadm, findmnt, systemd-makefs, mount and mountpoint
# and a fake /dev/disk/by-id.
#
# What is pinned: the disk is found by the serial the Vagrantfile gives
# it, never by a device name that depends on probe order; it is given the
# filesystem the guest's own root uses, through systemd's formatter, which
# leaves a disk that already carries one alone; a disk that is not there,
# a formatter that is not there, and a mount that did not happen are each
# a failure that says so. That the formatter really keeps what an earlier
# boot wrote is proven on a real VM by tests/smoke.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

SCRIPT="$REPO/vagrant/guest/mount-cache.sh"

# run_cache <serial> <mountpoint> <disk present|absent> <makefs ok|fails|missing> <mount ok|silent|already>
run_cache() {
    local box="$SANDBOX/run$RANDOM$RANDOM"
    mkdir -p "$box/bin" "$box/by-id" "$box/systemd"
    sed -e "s|/dev/disk/by-id/|$box/by-id/|g" \
        -e "s|/usr/lib/systemd/|$box/systemd/|g" \
        -e "s|/lib/systemd/|$box/systemd/|g" "$SCRIPT" > "$box/mount-cache.sh"
    [ "$3" = present ] && : > "$box/by-id/virtio-$1"
    printf '#!/bin/sh\necho "udevadm $*" >> "%s/calls"\n' "$box" > "$box/bin/udevadm"
    # findmnt: the root's type, and whatever is mounted where.
    printf '#!/bin/sh\necho "findmnt $*" >> "%s/calls"\nfor a; do last=$a; done\n[ "$last" = / ] && echo rootfs-type && exit 0\ncat "%s/mounted" 2>/dev/null\n' \
        "$box" "$box" > "$box/bin/findmnt"
    case "$4" in
        ok) printf '#!/bin/sh\necho "makefs $*" >> "%s/calls"\n' "$box" > "$box/systemd/systemd-makefs" ;;
        fails) printf '#!/bin/sh\necho "makefs $*" >> "%s/calls"\necho "makefs: no" >&2\nexit 1\n' "$box" > "$box/systemd/systemd-makefs" ;;
    esac
    case "$5" in
        ok) printf '#!/bin/sh\necho "mount $*" >> "%s/calls"\necho rootfs-type > "%s/mounted"\n' "$box" "$box" > "$box/bin/mount" ;;
        silent) printf '#!/bin/sh\necho "mount $*" >> "%s/calls"\n' "$box" > "$box/bin/mount" ;;
        already)
            printf '#!/bin/sh\necho "mount $*" >> "%s/calls"\n' "$box" > "$box/bin/mount"
            echo rootfs-type > "$box/mounted" ;;
    esac
    printf '#!/bin/sh\n[ -s "%s/mounted" ]\n' "$box" > "$box/bin/mountpoint"
    chmod +x "$box/bin/"* "$box/systemd/"* 2>/dev/null
    out="$(PATH="$box/bin:/usr/bin:/bin" bash "$box/mount-cache.sh" "$1" "$box$2" 2>&1 </dev/null)"
    rc=$?
    calls="$(cat "$box/calls" 2>/dev/null)"
    dev="$box/by-id/virtio-$1"
    mnt="$box$2"
}

grep -q '/dev/disk/by-id/virtio-' "$SCRIPT"
check_eq "$?" 0 "the fixture's by-id rewrite reaches the path the script finds the disk at"

run_cache flth-cache /cache present ok ok
check_eq "$rc" 0 "a fresh cache disk is mounted"
check_contains "$calls" "makefs rootfs-type $dev" "given the guest root's own filesystem, by systemd's formatter, on the disk named by its serial"
check_contains "$calls" "mount $dev $mnt" "and mounted where it was asked"
check_contains "$out" "$mnt" "saying where"
check_eq "$(test -d "$mnt" && echo made)" made "the mount point is created"
check_contains "$calls" "udevadm settle" "the device links are waited for before the disk is looked for"

run_cache flth-cache /cache present ok already
check_eq "$rc" 0 "a cache already mounted is left as it is"
check_lacks "$calls" "makefs" "  without formatting anything"
check_lacks "$calls" "mount " "  or mounting it twice"

run_cache flth-cache /cache absent ok ok
check_eq "$rc" 1 "no disk with the serial fails the boot"
check_contains "$out" "flth-cache" "  naming the serial it looked for"
check_lacks "$calls" "makefs" "  and formats nothing"

run_cache flth-cache /cache present missing ok
check_eq "$rc" 1 "a guest without systemd's formatter fails"
check_contains "$out" "systemd-makefs" "  naming what is missing"
check_lacks "$calls" "mount " "  and mounts nothing"

run_cache flth-cache /cache present fails ok
check_eq "$rc" 1 "a formatter that fails fails the boot"
check_lacks "$calls" "mount " "  and nothing is mounted over the disk it could not prepare"

run_cache flth-cache /cache present ok silent
check_eq "$rc" 1 "a mount that reported success onto nothing is a failure"

run_cache 'bad serial;x' /cache present ok ok
check_eq "$rc" 1 "a serial that is not a plain name is refused"
check_lacks "$calls" "makefs" "  before anything is touched"
out="$(bash "$SCRIPT" flth-cache relative 2>&1)"
check_eq "$?" 1 "a relative mount point is refused"

finish mount-cache
