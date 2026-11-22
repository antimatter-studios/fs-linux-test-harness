#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-0}" = 1 ]; then
    [ "$(systemctl is-enabled tmp.mount 2>/dev/null || true)" = masked ] || {
        echo 'guest booted without tmp.mount masked' >&2
        exit 1
    }
    [ "$(findmnt -n -o FSTYPE -T /tmp)" != tmpfs ] || {
        echo 'guest booted with /tmp on tmpfs' >&2
        exit 1
    }
fi
systemctl mask tmp.mount
if [ "$(findmnt -n -o FSTYPE -T /tmp)" = tmpfs ]; then
    umount -l /tmp
fi
chmod 1777 /tmp
[ "$(findmnt -n -o FSTYPE -T /tmp)" != tmpfs ]
