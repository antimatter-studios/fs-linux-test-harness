#!/usr/bin/env bash
#
# agents-core.sh — rust-fs-core's scripts/agents-core-check.sh, run in place,
# passes this repository's
# AGENTS.md, and REFUSES a modified, unmarked, mis-declared or absent one.
# A gate that cannot fail is indistinguishable from no gate.
#
# The checker runs against copies of the guide in a sandbox, so the committed AGENTS.md
# is never edited, even by a test killed halfway.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

CHECK="$REPO/../rust-fs-core/scripts/agents-core-check.sh"
if [ ! -f "$CHECK" ] || [ ! -f "$REPO/AGENTS.md" ]; then
    bad "../rust-fs-core/scripts/agents-core-check.sh and AGENTS.md exist (chore siblings)"
    finish agents-core
fi

check_eq "$(FS_CORE_CALLER="$REPO" bash "$CHECK" >/dev/null 2>&1; echo $?)" 0 "the committed AGENTS.md carries the shared block, unmodified"
check_eq "$(grep -c '^@AGENTS.md$' "$REPO/CLAUDE.md" 2>/dev/null | tr -d ' ')" 1 "CLAUDE.md imports AGENTS.md"

# run_on <awk program|ABSENT> — the checker against an edited copy.
run_on() {
    local tree="$SANDBOX/t$RANDOM$RANDOM"
    mkdir -p "$tree"
    [ "$1" = ABSENT ] || awk "$1" "$REPO/AGENTS.md" > "$tree/AGENTS.md"
    FS_CORE_CALLER="$tree" bash "$CHECK" >/dev/null 2>&1
    echo $?
}

check_eq "$(run_on 1)" 0 "an unedited copy passes, so the refusals below are the edits'"
check_eq "$(run_on '!done && /^## Claiming work$/ { print $0 " "; done = 1; next } 1')" 1 \
    "one trailing space inside the block is refused"
check_eq "$(run_on '!/BEGIN SHARED BLOCK/')" 1 "a missing BEGIN marker is refused"
check_eq "$(run_on '!/END SHARED BLOCK/')" 1 "a missing END marker is refused"
check_eq "$(run_on '{ sub(/sha256:[0-9a-f]+/, "sha256:" sprintf("%064d", 0)) } 1')" 1 \
    "a BEGIN marker declaring another digest is refused"
check_eq "$(run_on ABSENT)" 1 "an absent AGENTS.md is refused"

finish agents-core
