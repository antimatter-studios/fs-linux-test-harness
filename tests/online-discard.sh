#!/usr/bin/env bash
#
# online-discard.sh -- vagrant/guest/online-discard.sh, which has the guest's
# root give the blocks it frees back to the disposable overlay (#105), run here
# against a stubbed `mount`. That it really shrinks the overlay is measured on a
# real guest by tests/smoke.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

SCRIPT="$REPO/vagrant/guest/online-discard.sh"

# run_discard <mount's exit status>
run_discard() {
    local box="$SANDBOX/run$RANDOM$RANDOM"
    mkdir -p "$box/bin"
    printf '#!/bin/sh\necho "$*" >> "%s/calls"\n[ "%s" = 0 ] || echo "mount: refused" >&2\nexit %s\n' "$box" "$1" "$1" > "$box/bin/mount"
    chmod +x "$box/bin/mount"
    out="$(PATH="$box/bin:/usr/bin:/bin" bash "$SCRIPT" 2>&1 </dev/null)"
    rc=$?
    calls="$(cat "$box/calls" 2>/dev/null)"
}

run_discard 0
check_eq "$rc" 0 "the root takes the option"
check_eq "$calls" "-o remount,discard /" "by remounting it, whatever filesystem it is"
check_eq "$out" "" "and a boot that went as it should prints nothing"

# A root that will not has an overlay that does not shrink, which matters only
# on a host short of disk. That is no reason to refuse every boot of it.
run_discard 32
check_eq "$rc" 0 "a root that refuses does not stop the boot"
check_contains "$out" "keeps every block" "and the boot says what that costs"
check_contains "$out" "mount: refused" "and why"

finish online-discard
