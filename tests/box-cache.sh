#!/usr/bin/env bash
#
# box-cache.sh — the Vagrant box cache is saved from main, where every merge
# queue run and pull request can restore it.
#
# GitHub scopes a cache to the ref that saved it and that ref's base branch. A
# merge queue run saves under its own gh-readonly-queue ref, which no other
# queue run can read, so when main holds no entry every queue run downloads the
# box again from the catalog, and fails when the catalog is down (#148). The
# save therefore lives in a workflow that runs on main, on every push and on a
# schedule (an entry nothing reads for seven days is evicted), and the smoke
# jobs only restore, so queue refs stop filling the cache with entries that
# nothing else can read.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

save="$REPO/.github/workflows/box-cache.yml"
ci="$REPO/.github/workflows/ci.yml"

if [ -f "$save" ]; then
    ok "the box cache has a workflow of its own"
    wf="$(cat "$save")"
else
    bad "no ${save#"$REPO"/} saves the box cache from main"
    wf=""
fi

check_contains "$wf" "branches: [main]" "the save runs on pushes to main"
check_contains "$wf" "schedule:" "the save also runs on a schedule, so the entry is read before eviction"
check_contains "$wf" "uses: actions/cache/restore@v4" "the save first looks for the entry it would write"
check_contains "$wf" "uses: actions/cache/save@v4" "the save writes the entry with actions/cache/save"
check_contains "$wf" "if: steps.restore.outputs.cache-hit != 'true'" "the save fetches and writes only on a miss"
check_contains "$wf" "github.ref == 'refs/heads/main'" "the save writes only from main"
check_contains "$wf" "path: ~/.vagrant.d/boxes" "the save caches the directory the smoke jobs restore"
check_contains "$wf" "key: \${{ steps.vm-host.outputs.box-cache-key }}" \
    "the save uses the key ci-setup-linux.sh derives from the Vagrantfile's pin"
check_contains "$wf" "scripts/ci-setup-linux.sh" "the save installs Vagrant the way every consumer does"
check_lacks "$wf" "--box-version 2" "the box version is read from the Vagrantfile, not written into the workflow"

# The guests the smoke jobs boot are the guests whose boxes are saved.
smoke_guests="$(sed -n 's/^ *guest: \[\(.*\)\]$/\1/p' "$ci" | head -1)"
save_guests="$(printf '%s\n' "$wf" | sed -n 's/^ *guest: \[\(.*\)\]$/\1/p' | head -1)"
check_eq "$save_guests" "$smoke_guests" "the save covers every guest the smoke jobs boot"

# The smoke jobs restore and never save, so a queue ref adds no entry.
smoke="$(awk '/^  smoke-x86_64:/ { on = 1; print; next } on && /^  [a-z]/ { on = 0 } on' "$ci")"
# smoke_uses <text> <what> — the smoke job holds the line, without reciting the job.
smoke_uses() { if grep -qF -- "$1" <<<"$smoke"; then ok "$2"; else bad "$2 (no '$1' in smoke-x86_64)"; fi; }
smoke_uses "uses: actions/cache/restore@v4" "the smoke jobs restore the box cache"
if grep -qF "uses: actions/cache@v4" <<<"$smoke"; then
    bad "the smoke jobs save a box cache under their own ref (actions/cache@v4 in smoke-x86_64)"
else
    ok "the smoke jobs do not save a box cache under their own ref"
fi

finish box-cache
