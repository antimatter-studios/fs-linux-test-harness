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
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for wf in ci.yml macos-host.yml; do
    block="$(awk '/^concurrency:/{f=1;next} f&&/^[^ ]/{exit} f{sub(/^[ \t]+/,""); print}' "$REPO/.github/workflows/$wf")"
    check_contains "$block" "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" \
        "$wf cancels only a pull request's superseded run"
    check_contains "$block" "github.event.pull_request.number || github.sha" \
        "$wf gives each push a concurrency group of its own"
done

finish ci-concurrency
