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
VM="$STUB_HARNESS/scripts/vm.sh"
TOOLS="$FLTH_TEST_STUB/guest-tools"
export SETUP_LOG="$SANDBOX/setup.log"

SRC="$(cd "$SANDBOX" && pwd -P)/src"
make_consumer "$SRC/one" join-one
make_consumer "$SRC/deep/two" join-two
make_consumer "$SRC/cached" join-cached '[cache]' 'size = "2G"'
make_consumer "$SANDBOX/elsewhere" join-elsewhere
mkdir -p "$FLTH_TEST_STUB/guest-repo/one" "$FLTH_TEST_STUB/guest-proc"

one() { (cd "$SRC/one" && "$VM" "$@"); }
two() { (cd "$SRC/deep/two" && "$VM" "$@"); }
# A consumer's standing run, whose id is its device's tag.
standing() { "$1" config | sed -n 's/^run.standing=//p'; }
setups() { grep -c "setup ran for $1" "$SETUP_LOG" 2>/dev/null | tr -d ' '; }
ups() { stub_calls | grep -c '^up' | tr -d ' '; }

one up 2>/dev/null
check_eq "$?" 0 "the first consumer boots the guest"
check_eq "$(ups)" 1 "with one boot"
check_lacks "$(stub_calls)" "up --persist" "and no provisioning boot: the disk carries nobody's setup"
check_eq "$(setups join-one)" 1 "its setup runs"
check_contains "$(cat "$TOOLS")" "unshare --mount --propagation private bash" "in a namespace of its own"
check_contains "$(cat "$TOOLS")" "mount -t virtiofs $(standing one) $FLTH_TEST_STUB/guest-repo" "and its own tree, the run's device (#222)"
check_contains "$(cat "$TOOLS")" "mount --bind $FLTH_TEST_STUB/guest-repo/.vm-share /share" "with its own share, in that tree"

two up 2>/dev/null
check_eq "$?" 0 "the second consumer joins"
check_eq "$(ups)" 1 "with no boot of its own"
check_eq "$(setups join-two)" 1 "its setup runs when it first joins"
check_eq "$(setups join-one)" 1 "and the first one's does not run again"
check_contains "$(cat "$TOOLS")" "mount -t virtiofs $(standing two) $FLTH_TEST_STUB/guest-repo" "its tree is its own device, wherever its tree is"
check_contains "$(cat "$TOOLS")" "flock -n 9" "and setups take turns"
# By the line: a re-arm logs `shutdown ...`, which is no stop.
check_eq "$(stub_calls | grep -c '^down')" 0 "and nothing stops the guest for it"

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
check_contains "$(cat "$TOOLS")" "mount -t virtiofs $(standing two) $FLTH_TEST_STUB/guest-repo" "each run has its own tree at the path it expects"
check_lacks "$(two status)" "mounted" "and status does not call the other a foreign tree"
check_eq "$(two share)" "$SRC/deep/two/.vm-share" "a consumer's share is still its own on the host"
check_contains "$(two config)" "run.standing=$(standing two)" "and config names the run its calls outside a session use"

# A DECLARED CACHE is a directory of the guest's, per consumer.
cached() { (cd "$SRC/cached" && "$VM" "$@"); }
: > "$TOOLS"
cached up 2>/dev/null
check_eq "$?" 0 "a consumer that declares a cache joins"
check_contains "$(cat "$TOOLS")" "mount --bind $FLTH_TEST_STUB/guest-lib/caches/join-cached " "and has it in a directory of the guest's"
check_eq "$(cached exec 'echo cached')" cached "its calls run"
check_eq "$([ -e "$FLTH_TEST_STUB/cache" ] && echo disk)" "" "and the machine carries nobody's cache disk"
check_contains "$(cached config)" "cache.guest=/cache" "and config names where the run finds it"

# A CONSUMER'S BUILD STATE OUTLIVES ITS RUNS. /var/cache is where a suite keeps its
# target directory, so a second run does not build from nothing. It is the consumer's,
# on the guest's own disk, and only one run of a consumer has it at a time: a second
# run at once has its own, because two cannot share a target directory safely.
keep="$FLTH_TEST_STUB/guest-lib/consumers"
new_suite() {
    /bin/sleep 300 >/dev/null 2>&1 &
    SUITE=$!
    SUITES="$SUITES $SUITE"
    RUN="$("$1" run-id)"
    (FLTH_RUN_ID="$RUN" "$1" session-begin "$SUITE") 2>/dev/null
}
SUITES=""
# shellcheck disable=SC2329  # the trap below calls it
stop_suites() {
    local pid
    for pid in $SUITES; do kill -KILL "$pid" 2>/dev/null; done
    rm -rf "$SANDBOX"
}
trap stop_suites EXIT
: > "$TOOLS"
new_suite one; first=$SUITE; first_run=$RUN
FLTH_RUN_ID="$first_run" one exec true
check_contains "$(cat "$TOOLS")" "mount --bind $keep/join-one/var-cache /var/" "a run has its consumer's /var/cache"
echo built > "$keep/join-one/var-cache/target"
new_suite one; second=$SUITE; second_run=$RUN
: > "$TOOLS"
FLTH_RUN_ID="$second_run" one exec true
check_contains "$(cat "$TOOLS")" "mount --bind $FLTH_TEST_STUB/guest-lib/runs/$second_run/var-cache /var/" "a second run at once has its own"
new_suite two; other=$SUITE; other_run=$RUN
: > "$TOOLS"
FLTH_RUN_ID="$other_run" two exec true
check_contains "$(cat "$TOOLS")" "mount --bind $keep/join-two/var-cache /var/" "another consumer has its own"
: > "$TOOLS"
two exec true
check_lacks "$(cat "$TOOLS")" "$keep/join-two/var-cache" "a call outside any session does not take it"
one session-end "$first" 2>/dev/null
check_eq "$(cat "$keep/join-one/var-cache/target" 2>/dev/null)" built "what a run built outlives it"
one session-end "$second" 2>/dev/null
two session-end "$other" 2>/dev/null
new_suite one; third=$SUITE; third_run=$RUN
: > "$TOOLS"
FLTH_RUN_ID="$third_run" one exec true
check_contains "$(cat "$TOOLS")" "mount --bind $keep/join-one/var-cache /var/" "the next run has it back"
# A RUN'S END FREES WHAT IT HELD BEFORE IT DELETES ITS ROOT, which can take minutes. A
# suite restarted during that takes the consumer's /var/cache, not an empty one.
real_find="$(command -v find)"
cat > "$FLTH_TEST_STUB/bin/find" <<STUB
#!/bin/sh
case "\$*" in
    *-delete*) ls "$FLTH_TEST_STUB/guest-runs" > "$FLTH_TEST_STUB/state-at-delete" ;;
esac
exec "$real_find" "\$@"
STUB
chmod +x "$FLTH_TEST_STUB/bin/find"
new_suite one; ending=$SUITE; ending_run=$RUN
FLTH_RUN_ID="$ending_run" one exec true
one session-end "$ending" 2>/dev/null
check_lacks "$(cat "$FLTH_TEST_STUB/state-at-delete")" "ready.$ending_run" "a run is over before its root starts to go"
rm -f "$FLTH_TEST_STUB/bin/find"

# A suite killed outright holds it only until the next run registers.
kill -KILL "$third"
wait "$third" 2>/dev/null
new_suite one; fourth=$SUITE; fourth_run=$RUN
: > "$TOOLS"
FLTH_RUN_ID="$fourth_run" one exec true
check_contains "$(cat "$TOOLS")" "mount --bind $keep/join-one/var-cache /var/" "and a killed run's is free for the next"
one session-end "$fourth" 2>/dev/null

# A TREE ANYWHERE ON THE HOST joins: its run attaches it (#222).
(cd "$SANDBOX/elsewhere" && "$VM" up) >/dev/null 2>&1
check_eq "$?" 0 "a consumer in a directory nothing else is in joins"

# A NEW BOOT starts from a disk with nobody's setup on it.
one down 2>/dev/null
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "the guest stops"
before="$(setups join-two)"
one up 2>/dev/null
check_eq "$(setups join-one)" 2 "the next boot's first consumer runs its setup again"
check_eq "$(setups join-two)" "$before" "and nobody else's"
two up 2>/dev/null
check_eq "$(setups join-two)" "$((before + 1))" "until that one joins"

finish shared-guest-join
