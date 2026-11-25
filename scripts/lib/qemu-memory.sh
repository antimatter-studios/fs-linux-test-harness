# shellcheck shell=bash

flth_qemu_ram_mib() {
    local ram="$1" scale=1

    case "$ram" in
        *G) ram="${ram%G}"; scale=1024 ;;
        *M) ram="${ram%M}" ;;
    esac
    if ! [[ "$ram" =~ ^[1-9][0-9]{0,5}$ ]]; then
        printf 'vm: guest RAM must be a size like 2048, 2048M or 2G (at most six digits), got %s\n' "$1" >&2
        return 1
    fi
    printf '%s\n' "$((ram * scale))"
}

flth_resolve_vm_memory() {
    local guest_mib ceiling
    FLTH_QEMU_TB_LIMIT_MIB="${FLTH_VM_MEM:-0}"
    if [ "$FLTH_QEMU_TB_LIMIT_MIB" != 0 ] &&
        ! { [[ "$FLTH_QEMU_TB_LIMIT_MIB" =~ ^[1-9][0-9]{0,9}$ ]] &&
            [ "$FLTH_QEMU_TB_LIMIT_MIB" -ge 128 ] && [ "$FLTH_QEMU_TB_LIMIT_MIB" -le 4294967295 ]; }; then
        printf 'vm: FLTH_VM_MEM must be empty, 0, or an integer from 128 to 4294967295 MiB, got %s\n' "$FLTH_QEMU_TB_LIMIT_MIB" >&2
        return 1
    fi
    if [ "${FLTH_GUEST_MEM+x}" = x ]; then
        if ! [[ "$FLTH_GUEST_MEM" =~ ^[1-9][0-9]{0,5}$ ]]; then
            printf 'vm: FLTH_GUEST_MEM must be a positive integer in MiB (at most six digits), got %s\n' "$FLTH_GUEST_MEM" >&2
            return 1
        fi
        CFG_vm_memory="${FLTH_GUEST_MEM}M"
    fi
    [ "$FLTH_QEMU_TB_LIMIT_MIB" != 0 ] || return 0

    ceiling=$((FLTH_QEMU_TB_LIMIT_MIB / 2))
    guest_mib="$(flth_qemu_ram_mib "$CFG_vm_memory")" || return
    [ "$guest_mib" -gt "$ceiling" ] || return 0
    if [ "${FLTH_GUEST_MEM+x}" = x ]; then
        printf 'vm: FLTH_GUEST_MEM=%s exceeds half of FLTH_VM_MEM=%s (%s MiB)\n' "$guest_mib" "$FLTH_QEMU_TB_LIMIT_MIB" "$ceiling" >&2
        return 1
    fi
    CFG_vm_memory="${ceiling}M"
}

flth_qemu_memory_check() {
    local accel="$1" limit="${FLTH_HOST_MEMORY_LIMIT_MIB-unset}"

    FLTH_QEMU_GUEST_MIB="$(flth_qemu_ram_mib "$2")" || return
    FLTH_QEMU_TB_MIB=0
    FLTH_QEMU_OVERHEAD_MIB=384
    if [ "$accel" = tcg ]; then
        if [ "$#" -eq 2 ]; then
            FLTH_QEMU_TB_MIB="${FLTH_TCG_TB_SIZE_MIB-128}"
            if ! [[ "$FLTH_QEMU_TB_MIB" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$FLTH_QEMU_TB_MIB" -gt 1024 ]; then
                printf 'vm: FLTH_TCG_TB_SIZE_MIB must be an integer from 1 to 1024, got %s\n' "$FLTH_QEMU_TB_MIB" >&2
                return 1
            fi
        elif [ "$3" = 0 ]; then
            # QEMU picks its own cache size when tb-size is omitted. Budget
            # for its 1 GiB automatic maximum on supported 64-bit hosts.
            FLTH_QEMU_TB_MIB=1024
        else
            FLTH_QEMU_TB_MIB="$3"
        fi
    fi
    if [ "${FLTH_HOST_MEMORY_LIMIT_MIB+x}" = x ] && ! [[ "$limit" =~ ^[1-9][0-9]{0,5}$ ]]; then
        printf 'vm: FLTH_HOST_MEMORY_LIMIT_MIB must be a positive integer of at most six digits, got %s\n' "$limit" >&2
        return 1
    fi

    FLTH_QEMU_TOTAL_MIB=$((FLTH_QEMU_GUEST_MIB + FLTH_QEMU_TB_MIB + FLTH_QEMU_OVERHEAD_MIB))
    printf '[vm] qemu-memory accelerator=%s ram_mib=%s tb_mib=%s overhead_mib=%s total_mib=%s limit_mib=%s\n' \
        "$accel" "$FLTH_QEMU_GUEST_MIB" "$FLTH_QEMU_TB_MIB" "$FLTH_QEMU_OVERHEAD_MIB" "$FLTH_QEMU_TOTAL_MIB" "$limit" >&2
    if [ "$limit" != unset ] && [ "$FLTH_QEMU_TOTAL_MIB" -gt "$limit" ]; then
        printf 'vm: QEMU memory estimate of %s MiB exceeds FLTH_HOST_MEMORY_LIMIT_MIB=%s; no guest started\n' \
            "$FLTH_QEMU_TOTAL_MIB" "$limit" >&2
        return 1
    fi
}
