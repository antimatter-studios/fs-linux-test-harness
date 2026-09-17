#!/usr/bin/env bash
#
# run.sh — the VM-free self-test: syntax, lint, and every test file.
# `chore check` runs this; so does CI's `unit` job.
#
# Both shellcheck and ruby are REQUIRED. A lint step that is skipped when its
# tool is absent reports the same green as one that ran.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$REPO" || exit 1
failed=0

step() { printf '\n== %s\n' "$1"; }

shells="$(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')"

step "bash -n"
for f in $shells; do
    bash -n "$f" || { echo "syntax error: $f"; failed=1; }
done
[ "$failed" = 0 ] && echo "ok    $(echo "$shells" | wc -w | tr -d ' ') files parse"

step "shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "FAIL  shellcheck is required: apt-get install shellcheck / brew install shellcheck"
    failed=1
else
    # shellcheck disable=SC2086  # word splitting of the file list is intended
    if shellcheck -x $shells; then
        echo "ok    shellcheck $(shellcheck --version | sed -n 's/^version: //p') is clean"
    else
        failed=1
    fi
fi

step "ruby -c vagrant/Vagrantfile"
if ! command -v ruby >/dev/null 2>&1; then
    echo "FAIL  ruby is required"
    failed=1
else
    ruby -c vagrant/Vagrantfile || failed=1
fi

for t in config slot vm session engine-vagrant deadline vagrantfile generic; do
    step "tests/$t.sh"
    bash "tests/$t.sh" || failed=1
done

echo
if [ "$failed" = 0 ]; then
    echo "check: all passed"
else
    echo "check: FAILED" >&2
fi
exit "$failed"
