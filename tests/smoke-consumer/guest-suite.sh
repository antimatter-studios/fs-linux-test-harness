#!/usr/bin/env bash
#
# guest-suite.sh <pass|corrupt> — runs as root inside the VM.
#
# Build an ext4 image from the host's payload, read a file back out with
# debugfs, compare it, and run e2fsck. Results go to /share/results for
# the host to collect.
set -euo pipefail

mode="$1"
share=/share
results="$share/results"
img="$results/fs.img"
mkdir -p "$results"
rm -f "$img"

uname -a > "$results/uname.txt"
truncate -s 64M "$img"
mkfs.ext4 -q -F -b 4096 -d "$share/payload" "$img"

if [ "$mode" = corrupt ]; then
    # The first data block of payload.bin, and one byte in it flipped.
    block="$(debugfs -R "bmap /payload.bin 0" "$img" 2>/dev/null)"
    offset=$((block * 4096))
    byte="$(od -An -tu1 -j"$offset" -N1 "$img" | tr -d ' ')"
    printf '%b' "\\$(printf '%03o' $(( (byte + 1) % 256 )))" |
        dd of="$img" bs=1 seek="$offset" count=1 conv=notrunc status=none
    echo "corrupted byte at offset $offset (block $block)" > "$results/corruption.txt"
fi

debugfs -R "dump /payload.bin $results/dumped.bin" "$img" 2>/dev/null
debugfs -R "cat /dir/hello.txt" "$img" 2>/dev/null > "$results/hello.txt"

if ! cmp "$share/payload/payload.bin" "$results/dumped.bin" > "$results/cmp.log" 2>&1; then
    echo fail > "$results/verdict"
    echo "content check FAILED: $(cat "$results/cmp.log")" >&2
    exit 1
fi
cmp "$share/payload/dir/hello.txt" "$results/hello.txt" >> "$results/cmp.log" 2>&1

# -f forces a full check, -n answers no to every repair: it reports
# without touching the image.
e2fsck -fn "$img" > "$results/e2fsck.log" 2>&1
echo pass > "$results/verdict"
echo "guest suite: content matches and e2fsck is clean"
