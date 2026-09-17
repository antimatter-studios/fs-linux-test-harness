#!/usr/bin/env bash
#
# in-guest-suite.sh [pass|corrupt] — the smoke consumer's suite, run
# INSIDE the VM (the [test] guest_command, driven by `vm.sh guest-test`).
#
# The host-side entry point (suite.sh) stages input on the share and asks
# the guest to do the filesystem work. This one IS the guest: it runs
# from /repo, where the harness mounts the consumer repository, and does
# the staging itself — the shape a driver repository uses on a host that
# cannot run its Linux suite natively.
set -euo pipefail

mode="${1:-pass}"
case "$mode" in pass | corrupt) ;; *) echo "usage: in-guest-suite.sh [pass|corrupt]" >&2; exit 2 ;; esac

echo "in-guest suite: $PWD as $(id -un) on $(uname -sm)"
[ -f ./guest-suite.sh ] ||
    { echo "in-guest suite: the consumer repository is not mounted here" >&2; exit 1; }

share=/share
rm -rf "$share/payload"
mkdir -p "$share/payload/dir"
head -c 1048576 /dev/urandom > "$share/payload/payload.bin"
printf 'hello from the guest\n' > "$share/payload/dir/hello.txt"

bash ./guest-suite.sh "$mode"
