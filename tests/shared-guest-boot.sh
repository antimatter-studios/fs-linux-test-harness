#!/usr/bin/env bash
#
# shared-guest-boot.sh — joining a shared guest that another boot set up differently
# (#153). A guest sees one host directory and carries one version of lib/guest-run.sh,
# both fixed when it boots. A join that disagrees with either would mount the wrong
# path or call the tool with the wrong words, so it is refused, naming the difference.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
export FLTH_SLOT_WAIT=0
VM="$STUB_HARNESS/scripts/vm.sh"
TOOL="$STUB_HARNESS/scripts/lib/guest-run.sh"
export SETUP_LOG="$SANDBOX/setup.log"
BASE="$(cd "$SANDBOX" && pwd -P)"
SRC="$BASE/src"
make_consumer "$SRC/one" boot-one
make_consumer "$SRC/two" boot-two
mkdir -p "$FLTH_TEST_STUB/guest-repo/one" "$FLTH_TEST_STUB/guest-repo/two" "$FLTH_TEST_STUB/guest-proc"
in_tree() { (cd "$SRC/$1" && shift && FLTH_SHARED_ROOT="$ROOT" "$VM" "$@"); }

ROOT="$SRC"
in_tree one up >/dev/null 2>&1
check_eq "$?" 0 "the first consumer boots the guest"
in_tree two up >/dev/null 2>&1
check_eq "$?" 0 "another with the same directory and the same harness joins"

ROOT="$BASE"
out="$(in_tree two up 2>&1)"
check_eq "$?" 1 "a join naming another FLTH_SHARED_ROOT is refused"
check_contains "$out" "booted with FLTH_SHARED_ROOT=$SRC" "naming what the guest sees"
check_contains "$out" "this call has $BASE" "and what this call has"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "and the guest stays up"

ROOT="$SRC"
printf '# another version\n' >> "$TOOL"
out="$(in_tree two up 2>&1)"
check_eq "$?" 1 "a join from a harness with another guest tool is refused"
check_contains "$out" "another version of the harness" "and says so"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "and the guest stays up"

# The record goes with the boot. The next one is free to differ.
in_tree one down >/dev/null 2>&1
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "a shutdown request stops the empty guest"
in_tree two up >/dev/null 2>&1
check_eq "$?" 0 "and the next boot carries the tool this harness has"
in_tree one up >/dev/null 2>&1
check_eq "$?" 0 "and others join it"

# A guest from a harness that kept no record cannot be vouched for.
rm -f "$FLTH_CACHE_DIR/machines/shared-debian-12/shared-boot"
out="$(in_tree two up 2>&1)"
check_eq "$?" 1 "a guest with no record is refused"
check_contains "$out" "no record" "and says so"

finish shared-guest-boot
