#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

gh_calls="$SANDBOX/gh-calls"
gh_finished_runs="$SANDBOX/gh-finished-runs"
gh_forced_runs="$SANDBOX/gh-forced-runs"
: > "$gh_finished_runs"
: > "$gh_forced_runs"
cat > "$SANDBOX/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
    "repo view")
        printf '%s\n' antimatter-studios/fs-linux-test-harness
        ;;
    "pr view")
        if [ "${GH_TARGET_STATE:-OPEN}" = OPEN ]; then
            printf '%s\n' feature/target
        fi
        ;;
    "pr list")
        printf '%s\n' \
            $'123\tfeature/target\tmain' \
            $'124\tfeature/child\tfeature/target' \
            $'125\tfeature/grandchild\tfeature/child' \
            $'126\tfeature/unrelated\tmain'
        ;;
    "run list")
        branch=
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --branch ]; then
                branch="$2"
                break
            fi
            shift
        done
        [ -z "${GH_NO_RUNS:-}" ] || exit 0
        case "$branch" in
            feature/target) printf '%s\n' 100 150 ;;
            feature/child) printf '%s\n' 200 ;;
            feature/grandchild) printf '%s\n' 300 ;;
            *) ;;
        esac
        ;;
    "run cancel")
        if [ "$4" = --force ]; then
            printf '%s\n' "$3" >> "$GH_FORCED_RUNS"
        elif [ "$3" = 150 ] || [ -n "${GH_CANCEL_ENDS_ALL:-}" ]; then
            printf '%s\n' "$3" >> "$GH_FINISHED_RUNS"
        fi
        ;;
    "run view")
        if grep -qx "$3" "$GH_FORCED_RUNS" "$GH_FINISHED_RUNS"; then
            printf '%s\n' completed
        else
            printf '%s\n' in_progress
        fi
        ;;
    *)
        exit 2
        ;;
esac
STUB
chmod +x "$SANDBOX/gh"
export GH_CALLS="$gh_calls"
export GH_FINISHED_RUNS="$gh_finished_runs"
export GH_FORCED_RUNS="$gh_forced_runs"
export PATH="$SANDBOX:$PATH"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/sleep"
chmod +x "$SANDBOX/sleep"

script="$REPO/scripts/cancel-pr-pipelines.sh"
# /bin/bash is the host's own interpreter: Bash 3.2 on macOS, where an empty
# array under set -u is an error that a newer Bash does not raise.
output="$(/bin/bash "$script" 123 2>&1)"
check_contains "$output" 'Affected pull requests: #123 #124 #125' \
    "the target PR and stacked descendants are identified"
check_contains "$output" 'Cancelled workflow run 100' \
    "the target PR's active workflow is cancelled"
check_contains "$output" 'Cancelled workflow run 200' \
    "the child PR's active workflow is cancelled"
check_contains "$output" 'Cancelled workflow run 300' \
    "the grandchild PR's active workflow is cancelled"
check_contains "$output" 'Requested cancellation for workflow run 150' \
    "normal cancellation is requested first"
check_lacks "$output" '126' "an unrelated PR is left alone"
check_eq "$(grep -c '^run cancel ' "$gh_calls")" 7 \
    "obsolete runs are normally cancelled before unresolved ones are forced"
check_eq "$(grep -c '^run cancel .*--force' "$gh_calls")" 3 \
    "only workflows still active after normal cancellation are force-cancelled"
check_contains "$(cat "$gh_calls")" \
    'select(.status != "completed")' "completed historical runs are excluded"

# Every run ends on the normal request: none is left to force, so the list of
# unresolved runs is empty (an error under set -u on Bash 3.2 if expanded bare).
printf '' > "$gh_calls"
: > "$gh_finished_runs"
: > "$gh_forced_runs"
output="$(GH_CANCEL_ENDS_ALL=1 /bin/bash "$script" 123 2>&1)"
check_eq "$?" 0 "runs that end on the normal request leave nothing to force"
check_contains "$output" 'Requested cancellation for workflow run 300' \
    "each run is still asked to cancel"
check_lacks "$(cat "$gh_calls")" '--force' \
    "no workflow is force-cancelled when normal cancellation ended them all"
check_lacks "$output" 'Cancelled workflow run' \
    "only force-cancelled runs are reported as cancelled"

# Nothing active: no pull request has a queued or running workflow.
printf '' > "$gh_calls"
output="$(GH_NO_RUNS=1 /bin/bash "$script" 123 2>&1)"
check_eq "$?" 0 "a stack with nothing running is not an error"
check_contains "$output" 'No queued or running workflows to cancel.' \
    "an idle stack is reported as idle"
check_lacks "$(cat "$gh_calls")" 'run cancel' "an idle stack causes no cancellation"

printf '' > "$gh_calls"
if GH_TARGET_STATE=CLOSED /bin/bash "$script" 123 > "$SANDBOX/closed.out" 2>&1; then
    bad "a closed PR is refused"
else
    check_contains "$(cat "$SANDBOX/closed.out")" 'PR #123 is not open' \
        "a closed PR is refused before run cancellation"
fi
check_lacks "$(cat "$gh_calls")" 'run cancel' \
    "a closed PR causes no workflow cancellation"

finish cancel-pr-pipelines
