#!/usr/bin/env bash
#
# Nothing tests/tree-watchdog.sh started is left when it exits, whether it passes,
# fails or is interrupted (#302). Its stand-in suites run in process groups of their
# own, so no signal to the test reaches them. Left behind they ran for days, each
# starting ten processes a second.
#
# Each run gets a temporary directory of its own, so every sandbox path it makes
# holds this test's mark. A run is held with a stand-in suite live: the hook below,
# read through BASH_ENV, stops tree-watchdog at the statement after its first suite
# has started, and then either fails it or lets an INT reach it there.
#
# This test keeps its own sandbox and trap: it must clean up after a run that leaks.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Short, and one mark for everything under it.
ROOT="$(mktemp -d /tmp/flthl.XXXXXX)" || exit 1
MARK="${ROOT##*/}"
GROUPS_SEEN=""

# The live processes whose command line holds the mark. The mark reaches awk through
# its environment, so awk's own command line does not hold it.
holders() {
    command -p ps -A -ww -o pid=,pgid=,stat=,args= |
        LEAK_MARK="$MARK" command -p awk '$3 !~ /Z/ && index($0, ENVIRON["LEAK_MARK"])'
}

# The live processes of the groups seen while a run was held: what a suite forked,
# such as its guest loop, holds no sandbox path on its command line.
group_members() {
    command -p ps -A -ww -o pid=,pgid=,stat=,args= |
        LEAK_GROUPS=" $GROUPS_SEEN " command -p awk '$3 !~ /Z/ && index(ENVIRON["LEAK_GROUPS"], " " $2 " ")'
}

kill_leftovers() {
    local pid
    for pid in $( { holders; group_members; } | command -p awk '{ print $1 }'); do
        kill -KILL "$pid" 2>/dev/null
    done
}
# shellcheck disable=SC2329  # called by the trap below
clean_up() {
    kill_leftovers
    rm -rf "$ROOT"
}
trap clean_up EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$ROOT/hold.sh" <<'HOOK'
leak_hold() {
    [ "${0##*/}" = tree-watchdog.sh ] || return 0
    # Only this shell is held: nothing it starts reads this file.
    unset BASH_ENV
    [ "$1" = 'gone=$SUITE_PID' ] || return 0
    : > "$LEAK_DIR/held"
    local n=0
    while [ ! -e "$LEAK_DIR/go" ] && [ "$n" -lt 1200 ]; do
        /bin/sleep 0.1
        n=$((n + 1))
    done
    exit 1
}
trap 'leak_hold "$BASH_COMMAND"' DEBUG
HOOK

RUN=""
RUN_DIR=""
start_run() {
    # start_run <name> [hook file]: a run of tree-watchdog in a group of its own
    RUN_DIR="$ROOT/$1"
    mkdir -p "$RUN_DIR"
    set -m
    TMPDIR="$ROOT" LEAK_DIR="$RUN_DIR" BASH_ENV="${2:-}" \
        "${DEFAULT_INT[@]}" bash "$REPO/tests/tree-watchdog.sh" > "$RUN_DIR/log" 2>&1 &
    RUN=$!
    set +m
}

# Bounded: a run that does not end fails this and does not hang it. Sets STATUS.
wait_for_run() {
    local n=0
    while kill -0 "$RUN" 2>/dev/null && [ "$n" -lt 3000 ]; do
        /bin/sleep 0.1
        n=$((n + 1))
    done
    if kill -0 "$RUN" 2>/dev/null; then
        kill -KILL -- "-$RUN" 2>/dev/null
        { wait "$RUN"; } 2>/dev/null
        STATUS=stuck
        return 0
    fi
    { wait "$RUN"; } 2>/dev/null
    STATUS=$?
}

# Waits for the hold, and records the groups of everything holding the mark.
wait_until_held() {
    # wait_until_held <label>
    local n=0
    while [ ! -e "$RUN_DIR/held" ] && kill -0 "$RUN" 2>/dev/null && [ "$n" -lt 2400 ]; do
        /bin/sleep 0.1
        n=$((n + 1))
    done
    if [ -e "$RUN_DIR/held" ]; then
        ok "$1: the run is held with a stand-in suite live"
    else
        bad "$1: the run was never held, so this says nothing ($(tail -n 5 "$RUN_DIR/log"))"
    fi
    check_contains "$(holders)" "gone.started" "$1: the suite's command line holds the sandbox path"
    GROUPS_SEEN="$(holders | command -p awk '{ print $2 }' | sort -u | tr '\n' ' ')"
}

check_nothing_left() {
    # check_nothing_left <label>
    local n=0
    # A killed process stays listed until it is reaped.
    while [ -n "$(holders; group_members)" ] && [ "$n" -lt 50 ]; do
        /bin/sleep 0.1
        n=$((n + 1))
    done
    check_eq "$(holders)" "" "$1: no process with the sandbox path on its command line remains"
    check_eq "$(group_members)" "" "$1: nothing the suites forked remains"
    kill_leftovers
    GROUPS_SEEN=""
}

start_run pass
wait_for_run
check_eq "$STATUS" 0 "passing run: tree-watchdog passes"
[ "$STATUS" = 0 ] || tail -n 20 "$RUN_DIR/log"
check_nothing_left "passing run"

start_run fail "$ROOT/hold.sh"
wait_until_held "failing run"
: > "$RUN_DIR/go"
wait_for_run
check_eq "$STATUS" 1 "failing run: tree-watchdog fails"
check_nothing_left "failing run"

start_run interrupt "$ROOT/hold.sh"
wait_until_held "interrupted run"
kill -INT -- "-$RUN" 2>/dev/null
wait_for_run
check_eq "$STATUS" 130 "interrupted run: tree-watchdog ends by the INT"
check_nothing_left "interrupted run"

# A test that replaces the sandbox's EXIT trap loses the cleanup. It adds to it with
# at_exit instead.
replaced=""
for f in "$REPO"/tests/*.sh; do
    case "$f" in */lib.sh) continue ;; esac
    grep -q '^[^#]*new_sandbox$' "$f" || continue
    grep -q '^[[:space:]]*trap .*[[:space:]]EXIT$' "$f" && replaced="$replaced ${f##*/}"
done
check_eq "$replaced" "" "no test replaces the sandbox's EXIT trap"

finish sandbox-leaks
