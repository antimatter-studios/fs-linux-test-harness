#!/usr/bin/env bash
# Private and hosted Linux unit runners must use the same Ubuntu release.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
require_tool ruby 'install ruby / brew install ruby' || { finish ci-runner-os; exit 1; }
require_tool jq 'install jq / brew install jq' || { finish ci-runner-os; exit 1; }
workflow="$REPO/.github/workflows/ci.yml"
label="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0])["jobs"]["unit"]["runs-on"]' "$workflow")"
check_contains "$label" "needs.changes.outputs.linux_runner || 'ubuntu-24.04'" \
    'a missing pick keeps Linux units on Ubuntu 24.04'
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GATE_CALLS"
printf '%s\n' "$GATE_REPLY"
exit "$GATE_EXIT"
STUB
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" GATE_CALLS="$SANDBOX/calls"
export GITHUB_ACTOR=christhomas GITHUB_TRIGGERING_ACTOR=christhomas
export GITHUB_REPOSITORY_OWNER=antimatter-studios GITHUB_EVENT_PATH="$SANDBOX/event.json"
printf '%s\n' '{"sender":{"login":"christhomas"}}' > "$GITHUB_EVENT_PATH"
export GATE_REPLY=ubuntu-24.04 GATE_EXIT=0
check_eq "$("$REPO/scripts/pick-ci-runner.sh" 2> "$SANDBOX/stderr")" ubuntu-24.04 \
    'the gate can select the pinned hosted release'
check_contains "$(cat "$GATE_CALLS")" '--data-urlencode
fallback=ubuntu-24.04' 'the gate is asked for the same Ubuntu release as the VPS image'
export GATE_REPLY=ubuntu-latest
check_eq "$("$REPO/scripts/pick-ci-runner.sh" 2> "$SANDBOX/stderr")" ubuntu-24.04 \
    'a moving hosted label cannot change the unit OS'
check_contains "$(cat "$SANDBOX/stderr")" 'unexpected response' \
    'the moving hosted label is outside the allowlist'
export GATE_REPLY=antimatter-vps-linux-x64 GATE_EXIT=28
check_eq "$("$REPO/scripts/pick-ci-runner.sh" 2> "$SANDBOX/stderr")" ubuntu-24.04 \
    'a gate failure keeps the pinned Ubuntu release'
export GITHUB_ACTOR=contributor
check_eq "$("$REPO/scripts/pick-ci-runner.sh" 2> "$SANDBOX/stderr")" ubuntu-24.04 \
    'a refused identity keeps the pinned Ubuntu release'
finish ci-runner-os
