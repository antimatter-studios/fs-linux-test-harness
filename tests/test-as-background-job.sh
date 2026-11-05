#!/usr/bin/env bash
#
# A test file run as a background job with job control off inherits INT and QUIT
# ignored, and Bash cannot trap or reset a signal ignored on entry. A case that sends
# INT must not depend on how the file was started, or it fails with nothing wrong in
# what it tests, which is how #173 read as a failure under load.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

caught_int() { bash -c 'trap "exit 7" INT; kill -INT "$$"; exit 0'; }

( trap '' INT; caught_int )
check_eq "$?" 0 "a shell started with INT ignored cannot trap it, which is the trouble"
( trap '' INT; "${DEFAULT_INT[@]}" bash -c 'trap "exit 7" INT; kill -INT "$$"; exit 0' )
check_eq "$?" 7 "one started through DEFAULT_INT can"

# Every test that sends INT to what it starts goes through it.
for file in up-signals session-run session; do
    check_contains "$(cat "$REPO/tests/$file.sh")" 'DEFAULT_INT[@]' "tests/$file.sh starts its run with INT at its default"
done

finish test-as-background-job
