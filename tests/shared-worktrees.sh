#!/usr/bin/env bash
#
# shared-worktrees.sh — every consumer uses the one shared guest, and nobody has to
# say so (#220). Every checkout of a consumer, main or worktree, wherever git put
# it, runs there at once, each run on its own tree, attached to the guest while it
# runs (#222). There is no host directory to set or derive, and no tree is refused
# for where it is.
#
# The checkouts are made by git itself, as an agent makes them.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tool git "install git" || finish shared-worktrees
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
BOX="$(cd "$SANDBOX" && pwd -P)"
MACHINE="$FLTH_CACHE_DIR/machines/shared-debian-12"
CALLS="$FLTH_TEST_STUB/calls"

git_quiet() { git -c user.name=t -c user.email=t@example.invalid "$@" >/dev/null 2>&1; }

MAIN="$BOX/projects/consumer"
make_consumer "$MAIN" worktrees
git_quiet init "$MAIN"
git_quiet -C "$MAIN" add -A
git_quiet -C "$MAIN" commit -m init
NEAR="$BOX/projects/worktrees/consumer/w1"
FAR="$BOX/elsewhere/entirely/w2"
git_quiet -C "$MAIN" worktree add "$NEAR" -b w1
git_quiet -C "$MAIN" worktree add "$FAR" -b w2
check_eq "$([ -f "$NEAR/fs-linux-test-harness.toml" ] && [ -f "$FAR/fs-linux-test-harness.toml" ] && echo made)" made \
    "git made both worktrees"

config_of() { (cd "$1" && "$VM" config 2>&1); }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

for tree in "$MAIN" "$NEAR" "$FAR"; do
    out="$(config_of "$tree")"
    check_eq "$(field "$out" machine)" "$MACHINE" "${tree#"$BOX"/}: the shared machine, named for its guest, with nothing set"
    check_lacks "$out" "shared.root" "${tree#"$BOX"/}: and no host directory the guest sees at boot"
done

# Three checkouts of one consumer, two of them worktrees and one far from the rest,
# run on one guest at once, each on its own tree. A VM of the consumer's own mounted
# one of them and refused the others (#112, #220); a boot-time root refused the far one.
for tree in "$MAIN" "$NEAR" "$FAR"; do
    (cd "$tree" && "$VM" run true) >/dev/null 2>"$SANDBOX/err"
    check_eq "$?" 0 "${tree#"$BOX"/}: a call runs ($(tail -n 1 "$SANDBOX/err"))"
    check_contains "$(cat "$CALLS")" "$tree" "${tree#"$BOX"/}: on its own tree, attached to the guest"
    check_lacks "$(cat "$SANDBOX/err")" "mounted at" "${tree#"$BOX"/}: with no refusal naming another checkout"
done
check_eq "$(grep -c '^up$' "$CALLS" | tr -d ' ')" 1 "one boot served all three"
check_eq "$(grep -c '^attach ' "$CALLS" | tr -d ' ')" 3 "and attached three trees"

(cd "$FAR" && FLTH_SHARED_ROOT="$BOX/projects" "$VM" exec true) >/dev/null 2>&1
check_eq "$?" 0 "FLTH_SHARED_ROOT, set to a directory the tree is not under, is not read"

# The same answer through the consumer-facing task.
if require_chore; then
    cat > "$NEAR/chores.yml" <<CHORES
version: '3'
includes:
  vm:
    taskfile: $STUB_HARNESS/vm.chores.yml
CHORES
    cp "$REPO/vm.chores.yml" "$STUB_HARNESS/vm.chores.yml"
    out="$(cd "$NEAR" && chore vm:config 2>&1)"
    check_eq "$(field "$out" machine)" "$MACHINE" "chore vm:config reports the shared machine"
    check_contains "$out" "run.standing=" "and the run a call outside any session uses"
else
    bad "chore vm:config could not be checked"
fi

finish shared-worktrees
