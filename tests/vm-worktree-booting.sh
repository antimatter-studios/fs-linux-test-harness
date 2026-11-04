#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
ONE="$SANDBOX/worktree-one"
TWO="$SANDBOX/worktree-two"
make_consumer "$ONE" vm-worktree-booting
make_consumer "$TWO" vm-worktree-booting
ONE="$(cd "$ONE" && pwd -P)"
TWO="$(cd "$TWO" && pwd -P)"
export FLTH_TEST_PENDING_GATE="$SANDBOX/pending-boot"
: > "$FLTH_TEST_PENDING_GATE"
up_function="$(
    . "$STUB_HARNESS/scripts/lib/engine.sh"
    declare -f engine_up | sed '1s/engine_up/original_engine_up/'
)"
printf '%s\n' "$up_function" >> "$STUB_HARNESS/scripts/lib/engine.sh"
cat >> "$STUB_HARNESS/scripts/lib/engine.sh" <<'ENGINE'
engine_up() {
    original_engine_up "$@" || return
    [ "${1:-}" != --persist ] || return 0
    : > "$FLTH_TEST_PENDING_GATE.reached"
    local tries=0
    while [ -f "$FLTH_TEST_PENDING_GATE" ] && [ "$tries" -lt 600 ]; do
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    [ ! -f "$FLTH_TEST_PENDING_GATE" ]
}
ENGINE
(cd "$ONE" && "$VM" up) >"$SANDBOX/boot.log" 2>&1 &
boot_pid=$!
tries=0
while [ ! -f "$FLTH_TEST_PENDING_GATE.reached" ] && [ "$tries" -lt 600 ] && kill -0 "$boot_pid" 2>/dev/null; do
    /bin/sleep 0.1
    tries=$((tries + 1))
done
check_eq "$(test -f "$FLTH_TEST_PENDING_GATE.reached" && echo reached)" reached "the guest is running before the boot call returns"
out="$(cd "$TWO" && "$VM" exec true 2>&1)"
check_eq "$?" 1 "another worktree is refused even before the boot call returns"
check_contains "$out" "$ONE" "the boot in progress identifies the worktree it is mounting"
out="$(cd "$ONE" && "$VM" exec true 2>&1)"
check_eq "$?" 1 "the booting worktree waits for its boot to finish"
check_contains "$out" "did not finish, or is still running" "and is told its boot is unfinished"
check_lacks "$out" "the other worktree's files" "not that another worktree is mounted"
rm "$FLTH_TEST_PENDING_GATE"
wait "$boot_pid"
check_eq "$?" 0 "the boot finishes after the gate is released"
out="$(cd "$ONE" && "$VM" exec true 2>&1)"
check_eq "$?" 0 "the booting worktree can use its guest once the boot finishes"
out="$(cd "$TWO" && "$VM" exec true 2>&1)"
check_eq "$?" 1 "the other worktree stays refused after the boot finishes"
machine="$FLTH_CACHE_DIR/machines/vm-worktree-booting"
saved_boot="$(cat "$machine/mounted-worktree-boot")"
rm "$machine/mounted-worktree-boot"
mkdir "$machine/up.lock"
printf '%s\n' "$$" > "$machine/up.lock/pid"
out="$(cd "$TWO" && "$VM" exec true 2>&1)"
check_eq "$?" 0 "an older harness's live lock without a pending worktree cannot authenticate a stale record"
printf '%s\n' "$TWO" > "$machine/up.lock/mounted-worktree"
out="$(cd "$TWO" && "$VM" exec true 2>&1)"
check_eq "$?" 0 "a pending worktree different from the record cannot authenticate it"
printf '%s\n' "$ONE" > "$machine/up.lock/mounted-worktree"
printf 'invalid\n' > "$machine/up.lock/pid"
out="$(cd "$TWO" && "$VM" exec true 2>&1)"
check_eq "$?" 0 "a pending record with a malformed lock owner is unknown"
printf '2147483647\n' > "$machine/up.lock/pid"
out="$(cd "$TWO" && "$VM" exec true 2>&1)"
check_eq "$?" 0 "a pending record whose lock owner died is unknown"
rm "$machine/up.lock/pid" "$machine/up.lock/mounted-worktree"
rmdir "$machine/up.lock"
printf '%s\n' "$saved_boot" > "$machine/mounted-worktree-boot"
out="$(cd "$ONE" && "$VM" down 2>&1)"
check_eq "$?" 0 "the booting worktree's guest is stopped"
finish vm-worktree-booting
