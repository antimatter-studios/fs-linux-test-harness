#!/usr/bin/env bash
#
# boot-kernel-diagnostics.sh — when a `vm` call in tests/boot-kernel.sh goes
# wrong, the failing run says what that call printed and how it exited (#210).
#
# tests/boot-kernel.sh keeps its own output to one line per check, so the
# stderr of its `vm up` / `vm down` calls is not shown on a pass. It once
# failed because an `up` ended before it booted, and nothing in that run said
# why: every such call sent its stderr to /dev/null and its exit status was
# not kept.
#
# boot-kernel.sh is run here unmodified, from a copy of the repository whose
# vm.sh fails its third `up` -- the first after the setup changes, the one
# that stopped in #210 -- with a message and a status of its own. No VM is
# involved: boot-kernel.sh stubs the engine itself.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

FAULT="vm: injected fault 7f3a: up stopped before it booted"
COUNTER="$SANDBOX/up-count"

# copy_repo <dir>: the files boot-kernel.sh reads, as the repository has them.
copy_repo() {
    mkdir -p "$1/tests"
    cp "$REPO/tests/lib.sh" "$REPO/tests/boot-kernel.sh" "$1/tests/"
    cp -R "$REPO/scripts" "$REPO/vagrant" "$1/"
}

CLEAN="$SANDBOX/clean"
copy_repo "$CLEAN"

FAULTY="$SANDBOX/faulty"
copy_repo "$FAULTY"
# The fault runs before anything else in vm.sh, so the third `up` stops
# before it reaches the engine, as the one in #210 did.
{
    sed -n 1p "$REPO/scripts/vm.sh"
    cat <<EOF
if [ "\${1:-}" = up ]; then
    n=\$(( \$(cat "$COUNTER" 2>/dev/null || echo 0) + 1 ))
    echo "\$n" > "$COUNTER"
    if [ "\$n" = 3 ]; then
        echo "$FAULT" >&2
        exit 3
    fi
fi
EOF
    sed 1d "$REPO/scripts/vm.sh"
} > "$FAULTY/scripts/vm.sh"
chmod +x "$FAULTY/scripts/vm.sh"

# has <output> <text> <what>: a check that names what was missing without
# reciting the whole run each time; a failure prints the run once, below.
has() {
    if printf '%s\n' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (the run lacked '$2')"; fi
}

faulty="$(bash "$FAULTY/tests/boot-kernel.sh" 2>&1)"
rc=$?
check_eq "$([ "$rc" -ne 0 ] && echo failed || echo passed)" failed "boot-kernel.sh fails when an up stops before it boots"
has "$faulty" "FAIL  a changed setup is applied from the kernel the disk already runs" \
    "the failing check is the boot after the setup changed, as in #210"
has "$faulty" "$FAULT" "the failing run shows what that up printed on stderr"
has "$faulty" "vm up: exit 3" "and the status it exited with"

clean="$(bash "$CLEAN/tests/boot-kernel.sh" 2>&1)"
rc=$?
check_eq "$rc" 0 "boot-kernel.sh passes when every up boots"
if printf '%s\n' "$clean" | grep -qF -- "[vm]"; then
    bad "and a passing run still prints one line per check, with no vm output (it printed '[vm]')"
else
    ok "and a passing run still prints one line per check, with no vm output"
fi

if [ "$fails" -gt 0 ]; then
    printf '%s\n' "the run with the failing up printed:" "$faulty" | sed '2,$s/^/  | /'
    printf '%s\n' "the run with no failure printed:" "$clean" | sed '2,$s/^/  | /'
fi

finish boot-kernel-diagnostics
