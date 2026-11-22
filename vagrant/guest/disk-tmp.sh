#!/usr/bin/env bash
set -euo pipefail

systemctl mask tmp.mount
if [ "$(findmnt -n -o FSTYPE -T /tmp)" = tmpfs ]; then
    umount -l /tmp
fi
chmod 1777 /tmp
[ "$(findmnt -n -o FSTYPE -T /tmp)" != tmpfs ]
