#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-prepare}" = verify ]; then
    mask_state="$(systemctl is-enabled tmp.mount 2>/dev/null || true)"
    case "$mask_state" in
        masked | masked-runtime) ;;
        *) echo "guest booted without tmp.mount masked (state: ${mask_state:-unknown})" >&2; exit 1 ;;
    esac
    case "$(findmnt -n -o FSTYPE -T /tmp)" in
        tmpfs | ramfs | '') echo "guest booted without disk-backed /tmp" >&2; exit 1 ;;
    esac
    exit 0
fi

systemctl mask tmp.mount
directory=/var/lib/fs-linux-test-harness/boot-tmp
mkdir -p "$directory" /tmp
chmod 1777 "$directory"
case "$(findmnt -n -o FSTYPE -T "$directory")" in
    tmpfs | ramfs | '') echo "guest scratch directory is not disk-backed: $directory" >&2; exit 1 ;;
esac
if [ "$(findmnt -n -o FSTYPE -T /tmp)" = tmpfs ]; then
    mount --bind "$directory" /tmp
fi
chmod 1777 /tmp
case "$(findmnt -n -o FSTYPE -T /tmp)" in tmpfs | ramfs | '') exit 1 ;; esac
