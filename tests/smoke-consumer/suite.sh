#!/usr/bin/env bash
#
# suite.sh [pass|corrupt] — the smoke consumer's test entry point.
#
# Runs on the HOST with the VM up (fs-linux-test-harness [test] command),
# and does what a filesystem driver's oracle suite does: stage input in
# the shared directory, have the real kernel's tooling build and check an
# image in the guest, and collect the results back on the host.
#
# `corrupt` flips one byte of file data inside the image before the
# content check. It MUST fail — it is how CI proves a broken suite turns
# the pipeline red rather than quietly green.
set -euo pipefail

mode="${1:-pass}"
case "$mode" in pass | corrupt) ;; *) echo "usage: suite.sh [pass|corrupt]" >&2; exit 2 ;; esac

share="$FLTH_SHARE_HOST"
rm -rf "$share/payload" "$share/results"
mkdir -p "$share/payload/dir"

# Input, made on the host.
head -c 1048576 /dev/urandom > "$share/payload/payload.bin"
printf 'hello from the host\n' > "$share/payload/dir/hello.txt"

guest_script="$("$FLTH_VM" put "$(dirname "$0")/guest-suite.sh")"
set +e
"$FLTH_VM" run "bash $guest_script $mode"
rc=$?
set -e

# Collected on the host, whatever the guest said.
echo "--- results collected from $share/results"
ls -l "$share/results" 2>/dev/null || true
for f in cmp.log e2fsck.log verdict; do
    [ -f "$share/results/$f" ] && { echo "--- $f"; cat "$share/results/$f"; }
done

if [ "$rc" -ne 0 ]; then
    echo "suite: the guest suite failed (exit $rc)" >&2
    exit "$rc"
fi

# The host checks what came back rather than taking the guest's word:
# the verdict, and the ext4 superblock magic (0xEF53 at byte 1080).
[ "$(cat "$share/results/verdict")" = pass ] || { echo "suite: verdict is not pass" >&2; exit 1; }
magic="$(od -An -tx1 -j1080 -N2 "$share/results/fs.img" | tr -d ' \n')"
[ "$magic" = 53ef ] || { echo "suite: fs.img has no ext4 magic (got $magic)" >&2; exit 1; }
cmp "$share/payload/payload.bin" "$share/results/dumped.bin"
echo "suite: pass"
