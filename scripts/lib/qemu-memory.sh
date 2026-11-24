# shellcheck shell=bash

flth_qemu_memory_check() {
    local accel="$1" ram="$2" limit="${FLTH_HOST_MEMORY_LIMIT_MIB-unset}" scale=1

    case "$ram" in
        *G) ram="${ram%G}"; scale=1024 ;;
        *M) ram="${ram%M}" ;;
    esac
    if ! [[ "$ram" =~ ^[1-9][0-9]{0,5}$ ]]; then
        printf 'vm: guest RAM must be a size like 2048, 2048M or 2G (at most six digits), got %s\n' "$2" >&2
        return 1
    fi
    FLTH_QEMU_GUEST_MIB=$((ram * scale))
    FLTH_QEMU_TB_MIB=0
    FLTH_QEMU_OVERHEAD_MIB=384
    if [ "$accel" = tcg ]; then
        FLTH_QEMU_TB_MIB="${FLTH_TCG_TB_SIZE_MIB-128}"
        if ! [[ "$FLTH_QEMU_TB_MIB" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$FLTH_QEMU_TB_MIB" -gt 1024 ]; then
            printf 'vm: FLTH_TCG_TB_SIZE_MIB must be an integer from 1 to 1024, got %s\n' "$FLTH_QEMU_TB_MIB" >&2
            return 1
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
