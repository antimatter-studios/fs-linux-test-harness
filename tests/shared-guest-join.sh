#!/usr/bin/env bash
#
# shared-guest-join.sh — consumers joining one shared guest (#153): one boot, each
# consumer's own tree and share, and each one's [setup] running when it first joins.
# The guest's mount commands are logged, not run. The real proof that two real
# consumers pass side by side is recorded on the pull request, and tests/smoke.sh
# holds a real guest to the mounts.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
export FLTH_SLOT_WAIT=0
VM="$STUB_HARNESS/scripts/vm.sh"
TOOLS="$FLTH_TEST_STUB/guest-tools"
export SETUP_LOG="$SANDBOX/setup.log"

SRC="$(cd "$SANDBOX" && pwd -P)/src"
make_consumer "$SRC/one" join-one
make_consumer "$SRC/deep/two" join-two
make_consumer "$SRC/cached" join-cached '[cache]' 'size = "2G"'
make_consumer "$SANDBOX/elsewhere" join-elsewhere
mkdir -p "$FLTH_TEST_STUB/guest-repo/one" "$FLTH_TEST_STUB/guest-proc"

one() { (cd "$SRC/one" && FLTH_SHARED_ROOT="$SRC" "$VM" "$@"); }
two() { (cd "$SRC/deep/two" && FLTH_SHARED_ROOT="$SRC" "$VM" "$@"); }
setups() { grep -c "setup ran for $1" "$SETUP_LOG" 2>/dev/null | tr -d ' '; }
ups() { stub_calls | grep -c '^up' | tr -d ' '; }

one up 2>/dev/null
check_eq "$?" 0 "the first consumer boots the guest"
check_eq "$(ups)" 1 "with one boot"
check_lacks "$(stub_calls)" "up --persist" "and no provisioning boot: the disk carries nobody's setup"
check_eq "$(setups join-one)" 1 "its setup runs"
check_contains "$(cat "$TOOLS")" "unshare --mount --propagation private bash" "in a namespace of its own"
check_contains "$(cat "$TOOLS")" "mount --bind /share/one/.vm-share /share" "with its own share"
check_contains "$(cat "$TOOLS")" "mount --bind $FLTH_TEST_STUB/guest-repo/one $FLTH_TEST_STUB/guest-repo" "and its own tree"

two up 2>/dev/null
check_eq "$?" 0 "the second consumer joins"
check_eq "$(ups)" 1 "with no boot of its own"
check_eq "$(setups join-two)" 1 "its setup runs when it first joins"
check_eq "$(setups join-one)" 1 "and the first one's does not run again"
check_contains "$(cat "$TOOLS")" "mount --bind /share/deep/two/.vm-share /share" "its share is its own, wherever its tree is"
check_contains "$(cat "$TOOLS")" "flock -n 9" "and setups take turns"
check_lacks "$(stub_calls)" "down" "and nothing stops the guest for it"

two up 2>/dev/null
check_eq "$(setups join-two)" 1 "joining again does not run it again"
printf '\necho "setup changed for $FLTH_PROJECT" >> "$SETUP_LOG"\n' >> "$SRC/deep/two/setup.sh"
two up 2>/dev/null
check_eq "$(grep -c 'setup changed for join-two' "$SETUP_LOG" | tr -d ' ')" 1 "a changed setup runs when it joins next"
check_eq "$(ups)" 1 "in the running guest"
two provision 2>/dev/null
check_eq "$?" 0 "provision succeeds on a shared guest"
check_eq "$(grep -c 'setup changed for join-two' "$SETUP_LOG" | tr -d ' ')" 2 "and runs the setup in place"
check_eq "$(ups)" 1 "without stopping the guest"

# Every consumer's calls run, each with its own tree.
: > "$TOOLS"
check_eq "$(one exec 'echo one')" one "the first consumer's calls run"
check_eq "$(two exec 'echo two')" two "and so do the second's, where a private VM would refuse them"
check_contains "$(cat "$TOOLS")" "mount --bind $FLTH_TEST_STUB/guest-repo/deep/two $FLTH_TEST_STUB/guest-repo" "each run has its own tree at the path it expects"
check_lacks "$(two status)" "mounted" "and status does not call the other a foreign tree"
check_eq "$(two share)" "$SRC/deep/two/.vm-share" "a consumer's share is still its own on the host"
check_contains "$(two config)" "shared.root=$SRC" "and config names what the guest can see"

# A DECLARED CACHE is a directory of the guest's, per consumer.
cached() { (cd "$SRC/cached" && FLTH_SHARED_ROOT="$SRC" "$VM" "$@"); }
: > "$TOOLS"
cached up 2>/dev/null
check_eq "$?" 0 "a consumer that declares a cache joins"
check_contains "$(cat "$TOOLS")" "mount --bind $FLTH_TEST_STUB/guest-lib/caches/join-cached " "and has it in a directory of the guest's"
check_eq "$(cached exec 'echo cached')" cached "its calls run"
check_contains "$(cached config)" "cache.size=none" "and the machine carries nobody's cache disk"

# A TREE THE GUEST CANNOT SEE is refused, naming the setting.
out="$(cd "$SANDBOX/elsewhere" && FLTH_SHARED_ROOT="$SRC" "$VM" up 2>&1)"
check_eq "$?" 1 "a consumer outside FLTH_SHARED_ROOT is refused"
check_contains "$out" "is not under FLTH_SHARED_ROOT" "and told why"
out="$(cd "$SRC/one" && FLTH_SHARED_ROOT="$SRC/not-there" "$VM" status 2>&1)"
check_eq "$?" 1 "a FLTH_SHARED_ROOT that is not a directory is refused"

# A NEW BOOT starts from a disk with nobody's setup on it.
one down 2>/dev/null
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "the guest stops"
before="$(setups join-two)"
one up 2>/dev/null
check_eq "$(setups join-one)" 2 "the next boot's first consumer runs its setup again"
check_eq "$(setups join-two)" "$before" "and nobody else's"
two up 2>/dev/null
check_eq "$(setups join-two)" "$((before + 1))" "until that one joins"

# ONLY THE SETTING CHANGES ANY OF THIS.
one down 2>/dev/null
: > "$TOOLS"
stub_reset_calls
stub_state absent
(cd "$SRC/one" && "$VM" up) 2>/dev/null
check_contains "$(stub_calls)" "up --persist" "with the setting off a boot provisions as it did"
check_eq "$(cat "$TOOLS")" "" "and touches no mount"
check_contains "$(cd "$SRC/one" && "$VM" config)" "shared.root=none" "and config says so"

finish shared-guest-join
