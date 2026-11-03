#!/usr/bin/env bash
#
# vm-worktree.sh -- a machine is named for its project, so every worktree of a
# repository shares one, while the guest's /repo is the worktree that booted it
# (#112). A command from another worktree would run against the wrong source,
# so it fails naming the worktree the guest has mounted, and it does not stop
# that worktree's VM on the way out.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"

ONE="$SANDBOX/worktree-one"
TWO="$SANDBOX/worktree-two"
make_consumer "$ONE" vm-worktree '[test]' 'guest_command = "./in-guest.sh"'
make_consumer "$TWO" vm-worktree '[test]' 'guest_command = "./in-guest.sh"'
ONE="$(cd "$ONE" && pwd -P)"
TWO="$(cd "$TWO" && pwd -P)"
MACHINE="$FLTH_CACHE_DIR/machines/vm-worktree"
MARKER="$SANDBOX/ran-in-guest"

from() { local dir="$1"; shift; (cd "$dir" && "$VM" "$@"); }
state() { cat "$FLTH_TEST_STUB/state"; }
exists() { if [ -e "$1" ]; then echo present; else echo absent; fi; }

check_refused() {
    local what="$1" status="$2" output="$3"
    check_eq "$status" 1 "$what from another worktree fails"
    check_contains "$output" "$ONE" "$what names the worktree the guest has mounted"
    check_contains "$output" "$TWO" "$what names the worktree it ran from"
}

out="$(from "$ONE" up 2>&1)"
check_eq "$?" 0 "the first worktree boots the machine"
out="$(from "$ONE" run "touch '$MARKER'" 2>&1)"
check_eq "$?" 0 "the worktree the guest mounts runs commands"
check_eq "$(exists "$MARKER")" present "and they reach the guest"
rm "$MARKER"

ln -s "$ONE" "$SANDBOX/worktree-link"
out="$(from "$SANDBOX/worktree-link" run true 2>&1)"
check_eq "$?" 0 "the same worktree through a symlink is the same worktree"

out="$(from "$TWO" run "touch '$MARKER'" 2>&1)"
check_refused run "$?" "$out"
check_eq "$(exists "$MARKER")" absent "run from another worktree never reaches the guest"

out="$(from "$TWO" exec "touch '$MARKER'" 2>&1)"
check_refused exec "$?" "$out"
check_eq "$(exists "$MARKER")" absent "exec from another worktree never reaches the guest"

printf 'payload\n' > "$SANDBOX/payload"
out="$(from "$TWO" put "$SANDBOX/payload" 2>&1)"
check_refused put "$?" "$out"

out="$(from "$TWO" up 2>&1)"
check_refused up "$?" "$out"

out="$(from "$TWO" hold 2>&1)"
check_refused hold "$?" "$out"
check_eq "$(exists "$MACHINE/keep-running")" absent "hold from another worktree holds nothing"

out="$(from "$TWO" provision 2>&1)"
check_refused provision "$?" "$out"
check_eq "$(state)" running "provision from another worktree does not stop the VM"

out="$(from "$TWO" guest-test 2>&1)"
check_refused guest-test "$?" "$out"
check_eq "$(state)" running "the session that ends does not stop the other worktree's VM"

out="$(from "$TWO" session "$VM" run true 2>&1)"
check_eq "$?" 1 "a session's command from another worktree fails"
check_contains "$out" "$ONE" "the session's command names the worktree the guest has mounted"
check_eq "$(state)" running "that session's end leaves the other worktree's VM running"
check_contains "$out" "left running" "and says so"

out="$(from "$TWO" reap 2>&1)"
check_eq "$(state)" running "reap from another worktree leaves its VM running"
check_contains "$out" "$ONE" "reap names the worktree it left the VM to"

out="$(from "$TWO" status 2>&1)"
check_eq "$?" 0 "status still answers from another worktree"
check_contains "$out" "$ONE" "status names the worktree the guest has mounted"

out="$(from "$ONE" down 2>&1)"
check_eq "$?" 0 "the first worktree stops its VM"
out="$(from "$TWO" run "touch '$MARKER'" 2>&1)"
check_eq "$?" 0 "another worktree boots the machine once it has stopped"
check_eq "$(exists "$MARKER")" present "and its commands reach its guest"
out="$(from "$ONE" run true 2>&1)"
check_eq "$?" 1 "the record follows the latest boot"
check_contains "$out" "$TWO" "so the first worktree is now the one refused"

# A VM booted by a harness that kept no record: which worktree it mounts is not
# known, so the record's absence cannot be a refusal.
rm "$MACHINE/mounted-worktree"
out="$(from "$ONE" run true 2>&1)"
check_eq "$?" 0 "a running VM with no record is joined as before"
out="$(from "$ONE" down 2>&1)"
check_eq "$?" 0 "and can be stopped"
finish vm-worktree
