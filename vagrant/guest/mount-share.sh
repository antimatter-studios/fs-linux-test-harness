#!/usr/bin/env bash
#
# mount-share.sh <tag> <mountpoint> — mount the host's shared directory
# over 9p. Runs as root in the guest on every boot (Linux hosts only; the
# macOS provider mounts its virtiofs share itself).
set -euo pipefail

tag="$1"
mountpoint="$2"

case "$tag" in '' | *[!A-Za-z0-9_]*) echo "share: bad tag '$tag'" >&2; exit 1 ;; esac
case "$mountpoint" in /*) ;; *) echo "share: mountpoint must be absolute" >&2; exit 1 ;; esac

mkdir -p "$mountpoint"
if mountpoint -q "$mountpoint"; then
    echo "share: $mountpoint already mounted"
    exit 0
fi
modprobe 9pnet_virtio 2>/dev/null || true
mount -t 9p -o trans=virtio,version=9p2000.L,msize=524288 "$tag" "$mountpoint"
# Proven, not assumed: a mount that "succeeded" onto nothing would make
# every later read of the share silently empty.
mountpoint -q "$mountpoint"
echo "share: $tag mounted at $mountpoint"
