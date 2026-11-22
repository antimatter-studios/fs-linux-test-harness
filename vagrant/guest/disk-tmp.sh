#!/usr/bin/env bash
set -euo pipefail

directory=/var/lib/fs-linux-test-harness/boot-tmp
mkdir -p "$directory" /tmp
chmod 1777 "$directory"
if [ "$(findmnt -n -o FSTYPE -T "$directory")" = tmpfs ]; then
    echo "guest scratch directory is on tmpfs: $directory" >&2
    exit 1
fi
if [ "$(findmnt -n -o FSTYPE -T /tmp)" = tmpfs ]; then
    mount --bind "$directory" /tmp
fi
chmod 1777 /tmp
[ "$(findmnt -n -o FSTYPE -T /tmp)" != tmpfs ]
