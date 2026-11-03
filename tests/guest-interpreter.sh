#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

require_guest_bash || exit 1
selected="$FLTH_TEST_GUEST_BASH"

out="$(FLTH_TEST_GUEST_BASH="$SANDBOX/missing-bash" bash "$REPO/tests/run.sh" 2>&1)"
check_eq "$?" 1 "a missing guest interpreter fails the suite"
check_contains "$out" "guest scripts need Bash 4.2 or newer" "the failure names the guest interpreter requirement"
check_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1 "the missing interpreter is reported once, before any suite runs"

printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/old-bash"
chmod +x "$SANDBOX/old-bash"
out="$(FLTH_TEST_GUEST_BASH="$SANDBOX/old-bash" bash "$REPO/tests/run.sh" 2>&1)"
check_eq "$?" 1 "an interpreter without the deadline printf fails the suite"
check_contains "$out" "FLTH_TEST_GUEST_BASH" "the failure names how to select a capable interpreter"
check_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1 "an incompatible interpreter is also reported once"

out="$(require_guest_bash 2>&1)"
check_eq "$?|$out" '0|' "a capable guest interpreter passes without output"
check_eq "$FLTH_TEST_GUEST_BASH" "$selected" "the selected guest interpreter is preserved"
out="$("$selected" -c 'printf -v now "%(%s)T" -1; case "$now" in (""|*[!0-9]*) exit 1 ;; esac')"
check_eq "$?|$out" '0|' \
    "the selected interpreter really executes the deadline time conversion"

finish guest-interpreter
