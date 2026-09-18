#!/usr/bin/env bash
#
# output-budget.sh — the budget refuses a loud run, and never hides a failing
# one.
#
# The script exists because "keep the output quiet" as a convention lasts about
# a week. The properties worth pinning are the ones that make it safe to rely
# on: the COMMAND's status is what escapes (a `| tee` that reported tee's status
# is the defect that makes a red suite read green), a failure shows the tail
# rather than the budget complaint, and a passing-but-loud run is told apart
# from a failing one by its own exit code.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

B="$REPO/scripts/output-budget.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

run() { # run <log-name> <args...> -- prints combined output, sets $rc
    local log="$work/$1"; shift
    out="$("$B" --log "$log" "$@" 2>&1)"; rc=$?
}

# ---------------------------------------------------------------- within
run a.log --max-lines 5 --label demo -- sh -c 'echo one; echo two'
check_eq "$rc" 0 "a run inside its budget succeeds"
check_contains "$out" "demo: ok (2 lines" "and says what it printed"
check_contains "$out" "$work/a.log" "and names the log"

# ------------------------------------------------------------- over lines
run b.log --max-lines 2 --label demo -- sh -c 'for i in 1 2 3 4; do echo "line$i"; done'
check_eq "$rc" 65 "a passing run over its line budget exits 65"
check_contains "$out" "printed 4 lines (budget 2)" "and says by how much"
check_eq "$(wc -l < "$work/b.log" | tr -d ' ')" 4 "while the log still holds everything"

# ------------------------------------------------------------- over bytes
run c.log --max-bytes 4 --label demo -- sh -c 'echo 12345678'
check_eq "$rc" 65 "a byte budget is enforced too"

# ------------------------------------------------- a failure is not a budget
# The command's status must escape unchanged, and the tail must be shown: a
# failing run that printed only the budget complaint would be worse than no
# budget at all.
run d.log --max-lines 1 --tail 2 --label demo -- sh -c 'echo noise; echo "the real error"; exit 3'
check_eq "$rc" 3 "a failing command exits with ITS status, not the budget's"
check_contains "$out" "the real error" "and its tail is shown"
case "$out" in
    *"budget"*) bad "a failure does not complain about the budget" ;;
    *) ok "a failure does not complain about the budget" ;;
esac

# ------------------------------------------------------------------ verbose
run e.log --label demo --verbose -- sh -c 'echo streamed'
check_eq "$rc" 0 "verbose succeeds"
check_contains "$out" "streamed" "and streams the output"
check_eq "$(cat "$work/e.log")" "streamed" "while still writing the log"

run f.log --label demo --verbose -- sh -c 'echo oops; exit 7'
check_eq "$rc" 7 "verbose reports the command's status, not tee's"

export FLTH_VERBOSE=1
out="$("$B" --log "$work/g.log" --max-lines 1 --label demo -- sh -c 'echo a; echo b' 2>&1)"; rc=$?
check_eq "$rc" 65 "verbose does not exempt a run from its budget"
unset FLTH_VERBOSE

# ------------------------------------------------------------------ misuse
out="$("$B" --max-lines 1 -- true 2>&1)"; rc=$?
check_eq "$rc" 2 "a missing --log is refused"
out="$("$B" --log "$work/h.log" 2>&1)"; rc=$?
check_eq "$rc" 2 "a missing command is refused"

# ------------------------------------------------------- no budget, no limit
run i.log --label demo -- sh -c 'for i in $(seq 200); do echo "$i"; done'
check_eq "$rc" 0 "without a budget a long run is allowed"

finish output-budget
