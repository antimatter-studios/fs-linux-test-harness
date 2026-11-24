#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'usage: %s <guest RAM for QEMU -m>\n' "${0##*/}" >&2
    exit 1
fi

# shellcheck source=scripts/lib/qemu-memory.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/qemu-memory.sh"
flth_qemu_memory_check tcg "$1"
printf 'tcg,thread=multi,tb-size=%s\n' "$FLTH_QEMU_TB_MIB"
