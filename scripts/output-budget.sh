#!/usr/bin/env bash
#
# output-budget.sh — run a command quietly, keep everything, and refuse a run
# that prints more than it is allowed to.
#
#   output-budget.sh --log FILE [--max-lines N] [--max-bytes N] [--tail N]
#                    [--label TEXT] -- COMMAND [ARG...]
#
#   --log FILE     where the whole run is written (created; its directory too)
#   --max-lines N  refuse a run whose output exceeds N lines   (default: none)
#   --max-bytes N  refuse a run whose output exceeds N bytes   (default: none)
#   --tail N       lines of the log to print when the command fails. DEFAULT 0:
#                  a failure prints the verdict, the log path and the command's
#                  own status, and nothing else. Set it (or FLTH_FAIL_TAIL) when
#                  a person is watching and wants the assertion on screen.
#   --label TEXT   what to call the run in the summary line (default: the command)
#   --verbose      stream the output as it happens as well as logging it;
#                  also set by FLTH_VERBOSE=1. Budgets are still enforced.
#
# WHY A BUDGET IS A TEST. A passing run that prints three thousand lines hides
# the twenty that matter, and every reader pays for it: a person scrolling, a
# CI log viewer, and an agent working in the repository, which re-reads its
# whole transcript on each step and so pays for one verbose run many times
# over. Measured on this constellation: 4,661M cache-read tokens against 9.5M
# of output, and command output was the largest single contributor that a
# repository controls. "Keep it quiet" as a convention rots in a week; as a
# number that fails the build it does not.
#
# The budget is not a gag. Everything goes to --log and the path is printed, so
# nothing is lost by making the terminal quiet.
#
# WHY A FAILURE IS QUIET TOO, BY DEFAULT. Printing the tail is right for a
# person at a terminal and wrong for the reader who pays most: an agent
# re-reads its whole transcript on every later step, so forty lines of a panic
# cost it forty lines many times over — and they are rarely the forty it needs,
# because the assertion it wants is usually further up the log. One line naming
# the log lets it fetch exactly the part it wants, once. `--tail N`, or
# FLTH_FAIL_TAIL=N, brings the old behaviour back for whoever is watching.
#
# EXIT STATUS is the command's own, except that a breached budget exits 65
# when the command itself succeeded — a run that passed but would not fit is
# still a failure, and one you can tell apart from a failing suite.
set -uo pipefail

LOG=""; MAX_LINES=0; MAX_BYTES=0; TAIL="${FLTH_FAIL_TAIL:-0}"; LABEL=""
VERBOSE="${FLTH_VERBOSE:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --log)       shift; LOG="${1:-}" ;;
        --max-lines) shift; MAX_LINES="${1:-0}" ;;
        --max-bytes) shift; MAX_BYTES="${1:-0}" ;;
        --tail)      shift; TAIL="${1:-0}" ;;
        --label)     shift; LABEL="${1:-}" ;;
        --verbose|-v) VERBOSE=1 ;;
        --)          shift; break ;;
        -h|--help)   sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "output-budget.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

[ $# -gt 0 ] || { echo "output-budget.sh: no command (use -- COMMAND ...)" >&2; exit 2; }
[ -n "$LOG" ] || { echo "output-budget.sh: --log is required" >&2; exit 2; }
[ -n "$LABEL" ] || LABEL="$1"

mkdir -p "$(dirname "$LOG")" || exit 2

# The command's own status, not the pipeline's. `tee` succeeds while a suite
# fails, and a step written as `cmd | tee log` reports tee — which is how a red
# suite reads green, and why the test floors in these repositories exist.
if [ "$VERBOSE" = 1 ]; then
    # A pipeline, and the COMMAND's status taken from PIPESTATUS — not tee's,
    # which is the failure this script exists to prevent. Process substitution
    # was the other candidate and is wrong here: the log is still being written
    # when the next line measures it.
    "$@" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
else
    "$@" > "$LOG" 2>&1
    rc=$?
fi

lines=$(wc -l < "$LOG" | tr -d ' ')
bytes=$(wc -c < "$LOG" | tr -d ' ')

if [ "$rc" -ne 0 ]; then
    echo "$LABEL: FAILED (exit $rc) — $lines lines in $LOG" >&2
    # Verbose already streamed the run, so repeating its tail says nothing new.
    if [ "$VERBOSE" != 1 ] && [ "$TAIL" -gt 0 ]; then
        echo "--- last $TAIL lines of $LOG" >&2
        tail -n "$TAIL" "$LOG" >&2
    fi
    exit "$rc"
fi

over=""
[ "$MAX_LINES" -gt 0 ] && [ "$lines" -gt "$MAX_LINES" ] && over="$lines lines (budget $MAX_LINES)"
if [ "$MAX_BYTES" -gt 0 ] && [ "$bytes" -gt "$MAX_BYTES" ]; then
    [ -n "$over" ] && over="$over, "
    over="$over$bytes bytes (budget $MAX_BYTES)"
fi

if [ -n "$over" ]; then
    echo "$LABEL: passed, but printed $over" >&2
    echo "             Quiet the run, or raise the budget deliberately — see the" >&2
    echo "             output section of the consumer test contract." >&2
    echo "             Full output: $LOG" >&2
    exit 65
fi

printf '%s: ok (%s lines, %s bytes) — %s\n' "$LABEL" "$lines" "$bytes" "$LOG"
exit 0
