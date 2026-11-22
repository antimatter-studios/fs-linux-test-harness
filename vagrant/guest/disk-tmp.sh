#!/usr/bin/env bash
set -euo pipefail

directory=/var/lib/fs-linux-test-harness/boot-tmp
mkdir -p "$directory" /tmp
chmod 1777 "$directory"
if [ "$(findmnt -n -o FSTYPE -T "$directory")" = tmpfs ]; then
    echo "guest scratch directory is on tmpfs: $directory" >&2
    exit 1
fi
if [ "$(stat -c %d /tmp)" != "$(stat -c %d "$directory")" ]; then
    mount --bind "$directory" /tmp
fi
[ "$(findmnt -n -o FSTYPE -T /tmp)" != tmpfs ]
