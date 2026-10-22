#!/usr/bin/env bash
#
# ci-concurrency.sh — every commit on main gets a whole run.
#
# With `cancel-in-progress: true` for every event, a merge cancelled the run
# of the merge before it, and ci-ok went red on jobs that were cancelled, not
# broken: a red mark on a commit nobody finished testing. GitHub also keeps one
# pending run per concurrency group, so a third merge cancels a second one still
# queued even with cancelling off. So a push is a group of its own, keyed by its
# commit, and only a pull request's superseded run is cancelled.
#
# Not a pull request titled "red:" either (agent-core v8). It holds only its
# failing test and its run is the red evidence, so the push that adds the fix
# must not cancel it. Each push to it is a group of its own commit, for the
# same pending-run reason as a push to main, and none is cancelled.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for wf in ci.yml macos-host.yml; do
    block="$(awk '/^concurrency:/{f=1;next} f&&/^[^ ]/{exit} f{sub(/^[ \t]+/,""); print}' "$REPO/.github/workflows/$wf")"
    check_contains "$block" "cancel-in-progress: \${{ github.event_name == 'pull_request' && !startsWith(github.event.pull_request.title, 'red:') }}" \
        "$wf cancels only a pull request's superseded run, never a red: pull request's"
    check_contains "$block" "github.event.pull_request.number || github.sha" \
        "$wf gives each push a concurrency group of its own"
    check_contains "$block" "startsWith(github.event.pull_request.title, 'red:') && format('-red-{0}', github.event.pull_request.head.sha) || ''" \
        "$wf gives each push to a red: pull request a group of its own commit"
done

finish ci-concurrency
