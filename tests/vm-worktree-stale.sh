#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
ONE="$SANDBOX/worktree-one"
TWO="$SANDBOX/worktree-two"
make_consumer "$ONE" vm-worktree-stale
make_consumer "$TWO" vm-worktree-stale
ONE="$(cd "$ONE" && pwd -P)"
TWO="$(cd "$TWO" && pwd -P)"
MACHINE="$FLTH_CACHE_DIR/machines/vm-worktree-stale"
MARKER="$SANDBOX/ran-in-guest"
from() { local root="$1"; shift; (cd "$root" && "$VM" "$@"); }

out="$(from "$ONE" up 2>&1)"
check_eq "$?" 0 "the first worktree boots the machine"
out="$(from "$TWO" exec true 2>&1)"
check_eq "$?" 1 "a record for the running boot still refuses another worktree"
check_contains "$out" "$ONE" "the refusal names the worktree mounted by this boot"
saved_worktree="$(cat "$MACHINE/mounted-worktree")"
boot="$(cat "$FLTH_TEST_STUB/boot_identity")"
out="$(from "$ONE" down 2>&1)"
check_eq "$?" 0 "the first boot stops"
(
    export FLTH_CONFIG="$TWO/fs-linux-test-harness.toml"
    . "$STUB_HARNESS/scripts/lib/common.sh"
    flth_load
    engine_prepare
    engine_up
) >"$SANDBOX/older-boot.log" 2>&1
check_eq "$?" 0 "an older harness boots directly through the engine without updating the record"
check_eq "$(cat "$MACHINE/mounted-worktree")" "$saved_worktree" "the worktree record still names the previous boot's worktree"
check_eq "$(( $(cat "$FLTH_TEST_STUB/boot_identity") > boot ))" 1 "the engine identifies a different running boot"

out="$(from "$TWO" exec "touch '$MARKER'" 2>&1)"
check_eq "$?" 0 "exec from the actual mounted worktree ignores the stale record"
check_eq "$(test -f "$MARKER" && echo reached)" reached "that legitimate command reaches the guest"
check_lacks "$out" "$ONE mounted" "the stale worktree is not reported as mounted"
out="$(from "$TWO" run true 2>&1)"
check_eq "$?" 0 "run ignores a record from before the running boot"
out="$(from "$ONE" exec true 2>&1)"
check_eq "$?" 0 "a stale match is treated as unknown, not as a new ownership claim"
out="$(from "$TWO" status 2>&1)"
check_eq "$?" 0 "status still reports the running guest"
check_lacks "$out" "$ONE" "status does not name the stale worktree as mounted"
printf 'payload\n' > "$SANDBOX/payload"
out="$(from "$TWO" put "$SANDBOX/payload" 2>&1)"
check_eq "$?" 0 "put ignores a record from before the running boot"
out="$(from "$TWO" session-end "$$" 2>&1)"
check_eq "$?" 0 "session cleanup treats the stale record as no record"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "the last session may stop a guest whose worktree is unknown"

out="$(from "$TWO" up 2>&1)"
check_eq "$?" 0 "a current harness boots again"
out="$(from "$ONE" exec true 2>&1)"
check_eq "$?" 1 "a current boot replaces the stale association"
check_contains "$out" "$TWO" "the new refusal names the current boot's worktree"
: > "$FLTH_TEST_STUB/boot_identity_unreadable"
out="$(from "$ONE" exec true 2>&1)"
check_eq "$?" 0 "an unreadable boot identity cannot authenticate a worktree record"
rm "$FLTH_TEST_STUB/boot_identity_unreadable"
rm -f "$MACHINE/mounted-worktree-boot"
out="$(from "$ONE" exec true 2>&1)"
check_eq "$?" 0 "a legacy record with no boot identity is treated as no record"
out="$(from "$ONE" down 2>&1)"
check_eq "$?" 0 "a guest with an unverified record can still be stopped"
finish vm-worktree-stale
