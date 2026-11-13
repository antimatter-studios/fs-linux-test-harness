#!/usr/bin/env bash
#
# parallel-suites.sh — tests/run.sh runs the test files several at once, and still
# prints each one's output whole, in the order of the files (#215).
#
# The macOS VM-free job ran the files one after another in 12 to 14 of its 15
# minutes, and one run was cancelled at the limit with no verdict. Most of a file's
# time is waiting, on stand-in boots and bounded retries, so files that run side by
# side finish in a fraction of it. Nothing is left out to get there: every file
# still runs, and a failing one still fails the run. `run_suites` (tests/lib.sh) is
# what run.sh calls; here it runs stand-in files.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

if ! declare -F run_suites >/dev/null; then
    bad "tests/lib.sh defines run_suites <jobs> <file...>"
    finish parallel-suites
fi

suite() {
    # suite <name> <seconds> <status>
    printf '#!/usr/bin/env bash\necho "%s starts"\ncommand -p sleep %s\necho "%s ends"\nexit %s\n' "$1" "$2" "$1" "$3" > "$SANDBOX/$1.sh"
}
suite one 2 0
suite two 2 0
suite three 2 0

start=$SECONDS
out="$(run_suites 3 "$SANDBOX/one.sh" "$SANDBOX/two.sh" "$SANDBOX/three.sh")"
rc=$?
took=$((SECONDS - start))
check_eq "$rc" 0 "three passing files pass"
check_eq "$(( took < 5 ))" 1 "three files of 2 s each run side by side, in ${took} s"
expected="== $SANDBOX/one.sh
one starts
one ends

== $SANDBOX/two.sh
two starts
two ends

== $SANDBOX/three.sh
three starts
three ends"
check_eq "$(printf '%s\n' "$out" | sed '/^$/d')" "$(printf '%s\n' "$expected" | sed '/^$/d')" \
    "each file's output is printed whole, under its name, in the order of the files"

suite fails 1 1
out="$(run_suites 3 "$SANDBOX/one.sh" "$SANDBOX/fails.sh" "$SANDBOX/two.sh")"
rc=$?
check_eq "$rc" 1 "a failing file fails the run"
check_contains "$out" "fails ends" "and its output is printed"
check_contains "$out" "two ends" "as is every file's after it"

start=$SECONDS
out="$(run_suites 1 "$SANDBOX/one.sh" "$SANDBOX/two.sh")"
check_eq "$(( SECONDS - start >= 4 ))" 1 "one at a time when asked for one"

finish parallel-suites
