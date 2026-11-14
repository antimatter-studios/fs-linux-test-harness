#!/usr/bin/env bash
# A runner admission belongs to the child job and the current run attempt.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
require_tool ruby 'install ruby / brew install ruby' || { finish ci-runner-context; exit 1; }
require_tool jq 'install jq / brew install jq' || { finish ci-runner-context; exit 1; }
workflow="$REPO/.github/workflows/ci.yml"
check_eq "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["changes"]["steps"].last["id"]' "$workflow")" runner \
    'the pick is the last step before child jobs are queued'
check_eq "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["unit"]["needs"]' "$workflow")" changes \
    'unit admission has no intervening dependency'
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GATE_CALLS"
printf '%s\n' antimatter-vps-linux-x64
STUB
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" GATE_CALLS="$SANDBOX/calls"
export GITHUB_ACTOR=christhomas GITHUB_TRIGGERING_ACTOR=christhomas
export GITHUB_REPOSITORY_OWNER=antimatter-studios GITHUB_EVENT_PATH="$SANDBOX/event.json"
export GITHUB_RUN_ID=123456789 GITHUB_RUN_ATTEMPT=2
printf '%s\n' '{"sender":{"login":"christhomas"}}' > "$GITHUB_EVENT_PATH"
check_eq "$("$REPO/scripts/pick-ci-runner.sh" 2> "$SANDBOX/stderr")" antimatter-vps-linux-x64 \
    'a bound pick selects the available private runner'
args="$(cat "$GATE_CALLS")"
check_contains "$args" '--data-urlencode
run=123456789' 'the request names the workflow run'
check_contains "$args" '--data-urlencode
attempt=2' 'a rerun gets its own admission attempt'
check_contains "$args" '--data-urlencode
job=unit' 'the request names the child job, rather than changes'
finish ci-runner-context
