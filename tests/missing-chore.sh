#!/usr/bin/env bash
#
# missing-chore.sh — a test that needs chore, run where there is none, fails
# naming what installs it.
#
# Some tests drive a real `chore`. A guest has none unless a consumer's setup
# installs it, and the reaper tests that did failed there with "chore: command
# not found" and a check about a status, which names nothing to install (#182).
# A test that cannot run fails, and says what would let it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

# path_without <tool> — PATH with every directory holding <tool> replaced by
# links to everything else in it, so the rest of each directory still runs.
path_without() {
    local tool="$1" dir entry shadow out="" n=0 IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || continue
        if [ -e "$dir/$tool" ]; then
            n=$((n + 1))
            shadow="$SANDBOX/without-$tool/$n"
            mkdir -p "$shadow"
            for entry in "$dir"/*; do
                [ "${entry##*/}" = "$tool" ] || ln -s "$entry" "$shadow/"
            done
            dir="$shadow"
        fi
        out="$out${out:+:}$dir"
    done
    printf '%s\n' "$out"
}

bare="$(path_without chore)"
check_eq "$(PATH="$bare" command -v chore)" "" "the PATH for these runs has no chore"
check_contains "$(PATH="$bare" command -v bash)" "bash" "and still has everything else"

# says <text> — whether the run's output holds <text>, so a failure prints a
# word and the run's last line rather than the whole run three times.
says() { case "$out" in *"$1"*) echo yes ;; *) echo no ;; esac; }

t=shared-worktrees
out="$(PATH="$bare" bash "$REPO/tests/$t.sh" 2>&1)"
rc=$?
last="$(printf '%s' "$out" | tail -n 1)"
check_eq "$([ "$rc" -ne 0 ] && echo failed)" failed "tests/$t.sh fails without chore ($last)"
check_eq "$(says 'chore is required')" yes "tests/$t.sh says chore is what it lacks"
check_eq "$(says '.github/actions/install-chore')" yes "tests/$t.sh names what installs chore"
check_eq "$(says 'command not found')" no "tests/$t.sh does not run on into a command it does not have"

finish missing-chore
