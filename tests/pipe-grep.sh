#!/usr/bin/env bash
#
# pipe-grep.sh — no `grep -q` reads a pipeline (#286).
#
# Every script here runs under `pipefail`. `grep -q` stops reading at its
# first match, and a writer that writes again after that gets SIGPIPE, so
# the pipeline fails because the line WAS there. It depends on timing: it
# passed every local run and failed once on a loaded CI runner, in
# tests/guest-scratch.sh. engine-vagrant.sh learnt the same of `ps` in
# engine_alive. A pipeline's grep reads all of its input and sends what it
# matched to /dev/null instead.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A grep after a `|` whose options include q (-q, -qx, -Eq, --quiet ...).
PATTERN='\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*q|--quiet|--silent)'
hits="$(cd "$REPO" && grep -rnE "$PATTERN" scripts vagrant tests 2>/dev/null | grep -v '^tests/pipe-grep\.sh:')"
check_eq "$hits" "" "no grep -q reads a pipeline in scripts/, vagrant/ or tests/"

# The pattern itself is live: it finds each form it is meant to.
new_sandbox
sample="$SANDBOX/sample.sh"
printf '%s\n' \
    'a | grep -q x' \
    'b |grep -qx "y"' \
    'c | grep -Eq z' \
    'd | grep --quiet w' \
    'e | grep x >/dev/null' \
    'f; grep -q x file' > "$sample"
check_eq "$(grep -cE "$PATTERN" "$sample" | tr -d ' ')" 4 \
    "the guard finds piped -q, -qx, -Eq and --quiet, and passes a full read or a grep of a file"

finish pipe-grep
