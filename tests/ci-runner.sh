#!/usr/bin/env bash
# Runner routing must respect the user-only pool and retain hosted fallbacks.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
require_tool ruby 'install ruby / brew install ruby' || { finish ci-runner; exit 1; }
require_tool jq 'install jq / brew install jq' || { finish ci-runner; exit 1; }

# These jobs cannot safely use an early capacity prediction: the first job has
# no predecessor, and the others start after the real VM jobs have finished.
for job in changes ci-ok release; do
    label="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"][ARGV[1]]["runs-on"]' "$REPO/.github/workflows/ci.yml" "$job")"
    check_eq "$label" ubuntu-latest "$job uses a hosted runner even for a merge-queue bot push"
done
label="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["smoke-x86_64"]["runs-on"]' "$REPO/.github/workflows/ci.yml")"
check_eq "$label" ubuntu-latest 'the real VM smoke keeps a KVM-capable hosted runner'

PICK="$REPO/scripts/pick-ci-runner.sh"
if [ ! -x "$PICK" ]; then
    bad 'scripts/pick-ci-runner.sh exists and is executable'
    finish ci-runner
    exit 1
fi
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GATE_CALLS"
printf '%s' "$GATE_REPLY"
exit "$GATE_EXIT"
STUB
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH"
export GATE_CALLS="$SANDBOX/calls" GATE_REPLY=antimatter-vps-linux-x64 GATE_EXIT=0
export GITHUB_ACTOR=christhomas GITHUB_TRIGGERING_ACTOR=christhomas
export GITHUB_REPOSITORY_OWNER=antimatter-studios GITHUB_EVENT_PATH="$SANDBOX/event.json"
printf '%s\n' '{"sender":{"login":"christhomas"},"pull_request":{"user":{"login":"christhomas"}}}' > "$GITHUB_EVENT_PATH"
check_pick() {
    local label rc
    : > "$GATE_CALLS"
    label="$("$PICK" 2> "$SANDBOX/stderr")"; rc=$?
    check_eq "$rc" 0 "$2 returns a usable routing decision"
    check_eq "$label" "$1" "$2"
}
check_pick antimatter-vps-linux-x64 'the allowed user can use available VPS capacity'
args="$(cat "$GATE_CALLS")"
check_contains "$args" '--max-time
10' 'the gate request has a ten-second total deadline'
check_contains "$args" '--connect-timeout
3' 'the gate request bounds connection setup'
check_contains "$args" '--data-urlencode
actor=christhomas' 'the actor is URL encoded'
check_contains "$args" '--data-urlencode
author=christhomas' 'the PR author is URL encoded'
check_contains "$args" '--data-urlencode
org=antimatter-studios' 'the repository owner selects the pool'

export GATE_REPLY=ubuntu-latest
check_pick ubuntu-latest 'a busy pool selects GitHub'
export GATE_REPLY=antimatter-vps-linux-x64 GATE_EXIT=28
check_pick ubuntu-latest 'a timeout discards even a partial preferred label'
export GATE_EXIT=22
check_pick ubuntu-latest 'an HTTP failure uses GitHub'
export GATE_EXIT=0
for answer in '' 'macos-15' '{"runner":"antimatter-vps-linux-x64"}' $'antimatter-vps-linux-x64\nrunner=hostile'; do
    export GATE_REPLY="$answer"
    check_pick ubuntu-latest 'an empty, unexpected or multiline answer uses GitHub'
done
export GATE_REPLY=antimatter-vps-linux-x64
for identity in actor triggering sender author; do
    export GITHUB_ACTOR=christhomas GITHUB_TRIGGERING_ACTOR=christhomas
    printf '%s\n' '{"sender":{"login":"christhomas"},"pull_request":{"user":{"login":"christhomas"}}}' > "$GITHUB_EVENT_PATH"
    case "$identity" in
        actor) export GITHUB_ACTOR=contributor ;;
        triggering) export GITHUB_TRIGGERING_ACTOR=contributor ;;
        sender) printf '%s\n' '{"sender":{"login":"github-merge-queue[bot]"}}' > "$GITHUB_EVENT_PATH" ;;
        author) printf '%s\n' '{"sender":{"login":"christhomas"},"pull_request":{"user":{"login":"contributor"}}}' > "$GITHUB_EVENT_PATH" ;;
    esac
    check_pick ubuntu-latest "an unapproved $identity stays hosted"
    check_eq "$(cat "$GATE_CALLS")" '' 'a refused identity never asks the gate for capacity'
done
export GITHUB_ACTOR=christhomas GITHUB_TRIGGERING_ACTOR=christhomas
printf '%s\n' '{"sender":{"login":"christhomas"}}' > "$GITHUB_EVENT_PATH"
check_pick antimatter-vps-linux-x64 'a user tag push without a PR author can use the gate'
printf '%s\n' '{}' > "$GITHUB_EVENT_PATH"
check_pick antimatter-vps-linux-x64 'events with no optional sender or author match the hook'
printf '%s\n' 'not JSON' > "$GITHUB_EVENT_PATH"
check_pick ubuntu-latest 'a malformed event stays hosted'
for payload in null '[]' true 42; do
    printf '%s\n' "$payload" > "$GITHUB_EVENT_PATH"
    check_pick ubuntu-latest 'a non-object event stays hosted'
done
export GITHUB_EVENT_PATH="$SANDBOX/missing.json"
check_pick ubuntu-latest 'a missing event stays hosted'
export GITHUB_EVENT_PATH="$SANDBOX/event.json"
printf '%s\n' '{}' > "$GITHUB_EVENT_PATH"
export GITHUB_ACTOR=
check_pick ubuntu-latest 'an absent actor stays hosted'
export GITHUB_ACTOR=christhomas GITHUB_TRIGGERING_ACTOR=
check_pick ubuntu-latest 'an absent triggering actor stays hosted'
export GITHUB_TRIGGERING_ACTOR=christhomas GITHUB_REPOSITORY_OWNER=unrelated
check_pick ubuntu-latest 'an unknown organization stays hosted'
check_eq "$(cat "$GATE_CALLS")" '' 'an unknown organization never queries the pool'

finish ci-runner
