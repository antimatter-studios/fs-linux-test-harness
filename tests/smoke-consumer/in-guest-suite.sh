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
echo "in-guest build jobs: ${CARGO_BUILD_JOBS-unset}"
[ "${TMPDIR:-}" = /var/tmp/flth-tmp ] || { echo "unexpected TMPDIR: ${TMPDIR-unset}" >&2; exit 1; }
[ "$(stat -c %d "$TMPDIR")" = "$(stat -c %d "$FLTH_RUN_ROOT/var-tmp")" ] || { echo "TMPDIR is not on the run's disk" >&2; exit 1; }
[ "$(findmnt -n -o FSTYPE -T "$TMPDIR")" != tmpfs ] || { echo "TMPDIR is on tmpfs" >&2; exit 1; }
[ "$(findmnt -n -o FSTYPE -T /tmp)" != tmpfs ] || { echo "run /tmp is on tmpfs" >&2; exit 1; }
[ "$(nsenter -t 1 -m -- findmnt -n -o FSTYPE -T /tmp)" != tmpfs ] || { echo "base guest /tmp is on tmpfs" >&2; exit 1; }
[ "$(systemctl is-enabled tmp.mount 2>/dev/null || true)" = masked ] || { echo "base guest tmp.mount is not masked" >&2; exit 1; }
[ "$(nsenter -t 1 -m -- stat -c %d /tmp)" = "$(nsenter -t 1 -m -- stat -c %d /)" ] || { echo "base guest /tmp is not on the root disk" >&2; exit 1; }
scratch="$(mktemp "$TMPDIR/smoke.XXXXXX")"
printf '%s\n' "$FLTH_RUN_ROOT/var-tmp/flth-tmp" > /share/scratch-root
echo "in-guest scratch: $TMPDIR"
rm -f "$scratch"
[ -f ./guest-suite.sh ] ||
    { echo "in-guest suite: the consumer repository is not mounted here" >&2; exit 1; }

share=/share
rm -rf "$share/payload"
mkdir -p "$share/payload/dir"
head -c 1048576 /dev/urandom > "$share/payload/payload.bin"
printf 'hello from the guest\n' > "$share/payload/dir/hello.txt"

bash ./guest-suite.sh "$mode"
