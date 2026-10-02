#!/usr/bin/env bash
#
# guest-suite.sh <pass|corrupt> — runs as root inside the VM.
#
# Build an ext4 image from the host's payload, read a file back out with
# debugfs, compare it, and run e2fsck. Results go to /share/results for
# the host to collect.
#
# THE TOOLS WORK ON THE GUEST'S OWN DISK, never on the share. The payload
# is copied in, the image is built and checked under /var/tmp, and only
# the finished artefacts are copied back. The share is a host directory
# behind a daemon, not a disk: on the macOS engine an O_DIRECT open of a
# shared file fails with ENOTDIR, and over 9p mmap and chown fail. /var/tmp,
# not /tmp: a tmpfs /tmp is sized from the guest's RAM.
# tests/guest-scratch.sh refuses an image tool pointed at the share.
set -euo pipefail

mode="$1"
share=/share
results="$share/results"
work="$(mktemp -d /var/tmp/flth-smoke.XXXXXX)"
trap 'rm -rf "$work"' EXIT
img="$work/fs.img"
rm -rf "$results"
mkdir -p "$results"

uname -a > "$results/uname.txt"
cp -R "$share/payload" "$work/payload"
truncate -s 64M "$img"
mkfs.ext4 -q -F -b 4096 -d "$work/payload" "$img"

if [ "$mode" = corrupt ]; then
    # The first data block of payload.bin, and one byte in it flipped.
    block="$(debugfs -R "bmap /payload.bin 0" "$img" 2>/dev/null)"
    offset=$((block * 4096))
    byte="$(od -An -tu1 -j"$offset" -N1 "$img" | tr -d ' ')"
    printf '%b' "\\$(printf '%03o' $(( (byte + 1) % 256 )))" |
        dd of="$img" bs=1 seek="$offset" count=1 conv=notrunc status=none
    echo "corrupted byte at offset $offset (block $block)" > "$results/corruption.txt"
fi

debugfs -R "dump /payload.bin $work/dumped.bin" "$img" 2>/dev/null
debugfs -R "cat /dir/hello.txt" "$img" 2>/dev/null > "$work/hello.txt"
cp "$work/dumped.bin" "$work/hello.txt" "$results/"

if ! cmp "$work/payload/payload.bin" "$work/dumped.bin" > "$work/cmp.log" 2>&1; then
    cp "$img" "$work/cmp.log" "$results/"
    echo fail > "$results/verdict"
    echo "content check FAILED: $(cat "$work/cmp.log")" >&2
    exit 1
fi
cmp "$work/payload/dir/hello.txt" "$work/hello.txt" >> "$work/cmp.log" 2>&1

# -f forces a full check, -n answers no to every repair: it reports
# without touching the image.
e2fsck -fn "$img" > "$work/e2fsck.log" 2>&1
cp "$img" "$work/cmp.log" "$work/e2fsck.log" "$results/"
echo pass > "$results/verdict"
echo "guest suite: content matches and e2fsck is clean"
