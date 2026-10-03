#!/usr/bin/env bash
#
# mount-cache.sh <serial> <mountpoint> — mount the consumer's declared
# cache disk. Runs as root in the guest on every boot of a consumer that
# declares one ([cache] size); the Vagrantfile attaches the disk with this
# serial, outside the overlay a disposable boot writes to, so what is kept
# here outlives the boot that wrote it.
#
# THE FILESYSTEM IS THE GUEST'S OWN. A new disk is given whatever type the
# guest's root uses, by systemd's formatter, which leaves a disk that
# already carries a filesystem alone: the first boot formats, every later
# one mounts what is there. The harness names no filesystem and chooses
# none.
set -euo pipefail

serial="$1"
mountpoint="$2"

case "$serial" in '' | *[!A-Za-z0-9_-]*) echo "cache: bad serial '$serial'" >&2; exit 1 ;; esac
case "$mountpoint" in /*) ;; *) echo "cache: mountpoint must be absolute" >&2; exit 1 ;; esac

# Found by serial, never by a device name: those follow probe order.
dev="/dev/disk/by-id/virtio-$serial"
udevadm settle --timeout=30 2>/dev/null || true
if ! [ -e "$dev" ]; then
    echo "cache: no disk with serial $serial ($dev): the VM was booted without its cache disk" >&2
    exit 1
fi

mkdir -p "$mountpoint"
if mountpoint -q "$mountpoint"; then
    echo "cache: $mountpoint already mounted"
    exit 0
fi

makefs=""
for candidate in /usr/lib/systemd/systemd-makefs /lib/systemd/systemd-makefs; do
    if [ -x "$candidate" ]; then
        makefs="$candidate"
        break
    fi
done
if [ -z "$makefs" ]; then
    echo "cache: this guest has no systemd-makefs to prepare its cache disk with" >&2
    exit 1
fi
fstype="$(findmnt -n -o FSTYPE /)"
"$makefs" "$fstype" "$dev"

mount "$dev" "$mountpoint"
# Proven, not assumed: a mount that "succeeded" onto nothing would put a
# run's cache on the disposable disk, where it is silently lost.
mountpoint -q "$mountpoint"
echo "cache: $dev ($fstype) mounted at $mountpoint"
