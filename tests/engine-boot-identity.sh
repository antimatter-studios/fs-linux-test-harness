#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_consumer "$SANDBOX/consumer with spaces" boot-identity
export FLTH_CONFIG="$SANDBOX/consumer with spaces/fs-linux-test-harness.toml"
. "$REPO/scripts/lib/common.sh"
flth_load
engine_prepare
mkdir -p "$SANDBOX/bin"
export BOOT_PS="$SANDBOX/processes"
printf '#!/bin/sh\n[ ! -f "$BOOT_PS.fail" ] || exit 1\ncat "$BOOT_PS"\n' > "$SANDBOX/bin/ps"
chmod +x "$SANDBOX/bin/ps"
export PATH="$SANDBOX/bin:$PATH"
identity="$(engine_identity)"
write_process() { printf '%s Wed Nov  4 10:00:00 2026 %s\n' "$1" "$2"; }
{
    write_process 10 "sh -c qemu-system-aarch64 -drive file=$identity/disk"
    write_process 20 "qemu-system-aarch64 -drive file=$identity-other/disk"
    write_process 30 "/usr/bin/qemu-system-aarch64 -drive file=$identity/disk"
} > "$BOOT_PS"
out="$(engine_boot_identity 2>/dev/null)"
check_eq "$?" 0 "the running machine has a boot identity"
check_eq "$out" '30 Wed Nov 4 10:00:00 2026' "the identity includes its PID and start time, excluding shells and neighbouring machines"
before="$out"
write_process 31 "qemu-system-aarch64 -drive file=$identity/disk" > "$BOOT_PS"
out="$(engine_boot_identity 2>/dev/null)"
check_eq "$?" 0 "a replacement process is identified"
check_eq "$(test "$out" != "$before" && echo changed)" changed "a new PID in the same second is a new boot"
printf '%s\n' "30 Thu Nov  5 10:00:00 2026 qemu-system-aarch64 -drive file=$identity/disk" > "$BOOT_PS"
out="$(engine_boot_identity 2>/dev/null)"
check_eq "$(test "$out" != "$before" && echo changed)" changed "a reused PID with a new start time is a new boot"
printf '1 Wed Nov  4 10:00:00 2026 init\n' > "$BOOT_PS"
out="$(engine_boot_identity 2>/dev/null)"
check_eq "$?" 1 "no matching process has no boot identity"
check_eq "$out" '' "an absent VM supplies no identity"
: > "$BOOT_PS.fail"
out="$(engine_boot_identity 2>/dev/null)"
check_eq "$?" 2 "an unreadable process table is unknown, not absent"
check_eq "$out" '' "an unreadable process table supplies no identity"
finish engine-boot-identity
