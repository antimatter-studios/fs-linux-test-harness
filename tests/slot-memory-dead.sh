#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
make_consumer "$SANDBOX/new" new-pin '[vm]' 'memory = "2G"'
export FLTH_CONFIG="$SANDBOX/new/fs-linux-test-harness.toml"
export FLTH_SLOT_COUNT=2 FLTH_SLOT_WAIT=0 FLTH_SLOT_BOOT_GRACE=180

printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$SANDBOX/memory-bin/uname"
chmod +x "$SANDBOX/memory-bin/uname"
hash -r
printf 'MemAvailable:   6291456 kB\n' > "$FLTH_TEST_MEMINFO"

SLOT="$STUB_HARNESS/scripts/vm-slot.sh"
ONE="$FLTH_STATE_DIR/slot.lock"
TWO="$FLTH_STATE_DIR/slot-2.lock"
mkdir -p "$TWO"
printf '%s\t%s\t%s\t%s\n' /old/machine old-pin "$(( $(date +%s) - 86400 ))" old-token > "$TWO/holder"
printf '4096\n' > "$TWO/memory"
old_holder="$(cat "$TWO/holder")"

out="$("$SLOT" acquire 2>&1)"
check_eq "$?" 0 "a dead holder past its grace reserves no memory beside a free lower slot"
check_lacks "$out" 'insufficient host memory' "a dead holder does not cause a pending-memory refusal"
check_eq "$(cat "$ONE/memory" 2>/dev/null)" 2048 "the admitted guest records its own memory reservation"
check_eq "$(cat "$TWO/holder")" "$old_holder" "admission does not need to reach or reclaim the higher dead slot"
check_eq "$(cat "$TWO/memory")" 4096 "the dead holder is ignored without rewriting its reservation"

if [ -d "$ONE" ]; then rm -r "$ONE"; fi
touch "$FLTH_TEST_STUB/ps_unreadable"
out="$("$SLOT" acquire 2>&1)"
check_eq "$?" 1 "an unreadable process table still counts a holder past its grace"
check_contains "$out" 'insufficient host memory: 6144 MiB available' "the unknown holder causes a host-memory refusal"
check_contains "$out" '4096 MiB pending guests' "the unknown holder keeps its full memory reservation counted"
check_eq "$([ -d "$ONE" ] && echo held || echo free)" free "the refused acquire leaves no reservation in the lower slot"
check_eq "$(cat "$TWO/holder")" "$old_holder" "an unreadable process table leaves the existing holder unchanged"
check_eq "$(cat "$TWO/memory")" 4096 "an unreadable process table leaves the existing reservation unchanged"

finish slot-memory-dead
