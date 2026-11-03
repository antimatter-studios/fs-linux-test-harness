#!/usr/bin/env bash
#
# online-discard.sh -- have the guest's root tell its disk about the blocks it
# frees. Runs as root in the guest on every disposable boot.
#
# A disposable boot writes to an overlay on the host's disk, and QEMU can give a
# block back to the host only when the guest says it is free. The Vagrantfile's
# discard=unmap has QEMU act on that; this has the guest say it. Some boxes mount
# their root this way already and some do not: the macOS box's says `rw,noatime`.
#
# The mount option, and not a timed trim: a suite can write and delete a lot
# between two ticks of a timer, and a host disk does not wait for the next one.
#
# It does not stop the boot. An overlay that does not shrink matters only on a
# host short of disk, and a guest that runs is more use than one that does not.
set -uo pipefail

if ! out="$(mount -o remount,discard / 2>&1)"; then
    echo "online-discard: the root refused the discard option, so the overlay keeps every block written: $out" >&2
fi
exit 0
