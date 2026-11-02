#!/usr/bin/env bash
#
# newest-kernel.sh — print the release of the newest kernel on this disk that
# something other than the box installed; nothing when there is none.
#
# Asked on a macOS guest's provisioning boot, whose kernel is a file beside the
# box and not one on the disk (scripts/lib/engine-vagrant.sh).
#
# THE BOX'S RASPBERRY PI KERNELS ARE LEFT OUT. The box is built from a
# Raspberry Pi image, whose /boot holds -rpi- kernels the box has never booted
# on QEMU's virt machine. They are newer than the 6.1 kernel it does boot, so
# "the newest in /boot" alone would move every consumer onto one of them.
set -euo pipefail

newest=""
for kernel in /boot/vmlinuz-*; do
    [ -e "$kernel" ] || continue
    release="${kernel##*/vmlinuz-}"
    case "$release" in *-rpi-*) continue ;; esac
    newest="$(printf '%s\n%s\n' "$newest" "$release" | sort -V | tail -n 1)"
done
[ -n "$newest" ] || exit 0

# Without its initrd the next boot would pair this kernel with the box's, whose
# modules do not fit it, and stop with no root to mount.
if [ ! -e "/boot/initrd.img-$newest" ]; then
    echo "newest-kernel: /boot/vmlinuz-$newest has no /boot/initrd.img-$newest" >&2
    exit 1
fi
printf '%s\n' "$newest"
