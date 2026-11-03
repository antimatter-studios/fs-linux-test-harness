#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

RUBY_TEST="$SANDBOX/check.rb"
cat > "$RUBY_TEST" <<'RUBY'
require ARGV.fetch(0)
abort 'multiplexed calls were refused' unless ExecCost.reused?(100, 200)
abort 'an equal-cost fresh connection passed' if ExecCost.reused?(150, 150)
abort 'a small timing fluctuation passed' if ExecCost.reused?(190, 200)
abort 'the 20% boundary passed' if ExecCost.reused?(160, 200)
abort 'a failed VM call was accepted' if ExecCost.run('/usr/bin/false', ARGV.fetch(1))
RUBY
out="$(ruby "$RUBY_TEST" "$REPO/tests/exec-cost.rb" "$SANDBOX" 2>&1)"
check_eq "$?" 1 "a failed VM call fails the cost measurement"
check_contains "$out" 'vm.sh exec true failed; timing is not a successful call' \
    "reuse comparisons pass and a failed call is named, not timed as success"

finish exec-cost
