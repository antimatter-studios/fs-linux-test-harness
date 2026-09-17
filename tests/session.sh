#!/usr/bin/env bash
#
# session.sh — what scripts/vm-session.sh does to the exit status of the
# script that sources it.
#
# The rule was backwards once: a failing teardown must fail an otherwise
# successful script, because a VM that would not stop is the condition
# the trap exists to prevent. `vm.sh` is stubbed; the assertions are on
# exit status and on whether teardown was asked for.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

H="$SANDBOX/harness/scripts"
mkdir -p "$H/lib"
cp "$REPO/scripts/vm-session.sh" "$H/"
cp "$REPO/scripts/lib/config.sh" "$H/lib/"
make_consumer "$SANDBOX/consumer" session-test
LOG="$SANDBOX/down.log"

stub_down() {
    # stub_down <exit status of `vm.sh down`>
    printf '#!/usr/bin/env bash\n[ "$1" = down ] && { echo "down config=$FLTH_CONFIG" >> "%s"; exit %s; }\nexit 0\n' "$LOG" "$1" > "$H/vm.sh"
    chmod +x "$H/vm.sh"
}
work() {
    # work <body> — a consumer script that sources the session
    printf '#!/usr/bin/env bash\nset -euo pipefail\n. "%s/vm-session.sh"\ncd /\n%s\n' "$H" "$1" > "$SANDBOX/consumer/work.sh"
    chmod +x "$SANDBOX/consumer/work.sh"
}
run_work() { : > "$LOG"; (cd "$SANDBOX/consumer" && ./work.sh) >/dev/null 2>&1; }

check_case() {
    # check_case <down status> <body status> <expected> <what>
    stub_down "$1"; work "exit $2"; run_work
    check_eq "$?" "$3" "$4"
}
check_case 0 0 0 "work succeeds, teardown succeeds: success"
check_case 0 3 3 "work fails, teardown succeeds: the work's status"
check_case 1 0 1 "work succeeds, teardown FAILS: the script fails"
check_case 1 3 3 "both fail: the work's status wins"

stub_down 0; work "false; echo not reached"; run_work
check_eq "$?" 1 "a set -e abort keeps its status"
check_eq "$(grep -c down "$LOG" | tr -d ' ')" 1 "and teardown still ran"
check_contains "$(cat "$LOG")" "config=$(cd "$SANDBOX/consumer" && pwd -P)/fs-linux-test-harness.toml" \
    "the consumer was resolved when sourced, although the script changed directory"

stub_down 1; work "exit 0"; : > "$LOG"
out="$(cd "$SANDBOX/consumer" && FLTH_KEEP_VM=1 ./work.sh 2>&1)"
check_eq "$?" 0 "FLTH_KEEP_VM=1 leaves the status alone"
check_eq "$(grep -c down "$LOG" | tr -d ' ')" 0 "and never calls teardown"
check_contains "$out" "leaving the VM running, as asked" "and says so"

mkdir -p "$SANDBOX/noconsumer"
printf '#!/usr/bin/env bash\nset -euo pipefail\n. "%s/vm-session.sh"\necho reached\n' "$H" > "$SANDBOX/noconsumer/work.sh"
out="$(cd "$SANDBOX/noconsumer" && bash work.sh 2>&1)"
check_eq "$?" 1 "sourcing with no consumer config fails the script at once"
check_lacks "$out" "reached" "before any work runs"

finish session
