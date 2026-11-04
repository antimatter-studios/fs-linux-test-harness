#!/usr/bin/env bash
#
# shared-guest-run.sh — a run on a shared guest (#153): its own random root on the
# guest's disk, its own mounts, and the end of it touching nothing of another run's.
# lib/guest-run.sh runs here under the stub engine, with the guest's mount commands
# logged, not run. tests/smoke.sh holds a real guest to the same promises.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
export FLTH_SLOT_WAIT=0
VM="$STUB_HARNESS/scripts/vm.sh"
SESSION="$STUB_HARNESS/scripts/vm-session.sh"
TOOLS="$FLTH_TEST_STUB/guest-tools"
ROOTS="$FLTH_TEST_STUB/guest-lib/runs"

SRC="$(cd "$SANDBOX" && pwd -P)/src"
make_consumer "$SRC/one" run-one
make_consumer "$SRC/two" run-two
mkdir -p "$FLTH_TEST_STUB/guest-repo" "$FLTH_TEST_STUB/guest-proc"

one() { (cd "$SRC/one" && FLTH_SHARED_ROOT="$SRC" "$VM" "$@"); }
# A second suite of the same tree. Suites of other consumers are in shared-guest-join.sh.
two() { one "$@"; }
other_tree() { (cd "$SRC/two" && FLTH_SHARED_ROOT="$SRC" "$VM" "$@"); }

# A process of the run $1, in the guest. Orphaned, so it is gone once it is killed.
guest_process() {
    local pid
    pid="$(/bin/sleep 300 >/dev/null 2>&1 & echo $!)"
    mkdir -p "$FLTH_TEST_STUB/guest-proc/$pid/ns"
    ln -s "mnt:[$1]" "$FLTH_TEST_STUB/guest-proc/$pid/ns/mnt"
    printf '%s\n' "$pid"
}
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }

# A stand-in for a session: a process registered with a run, as vm-session.sh does.
SUITES=""
begin_suite() {
    # begin_suite <one|two>: sets SUITE and RUN
    /bin/sleep 300 >/dev/null 2>&1 &
    SUITE=$!
    SUITES="$SUITES $SUITE"
    RUN="$("$1" run-id)"
    (FLTH_RUN_ID="$RUN" "$1" session-begin "$SUITE") 2>/dev/null
}
# shellcheck disable=SC2329  # the trap below calls it
cleanup() {
    local pid
    for pid in $SUITES; do kill -KILL "$pid" 2>/dev/null; done
    for pid in "$FLTH_TEST_STUB"/guest-proc/*; do kill -KILL "${pid##*/}" 2>/dev/null; done
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

one up >/dev/null 2>&1
check_eq "$?" 0 "a boot succeeds"
check_contains "$(cat "$TOOLS")" "mount --make-private" "the boot prepares the guest for runs"

begin_suite one; A=$SUITE; RUN_A=$RUN
begin_suite two; B=$SUITE; RUN_B=$RUN
case "$RUN_A" in *worktree*) bad "a session's run is its own, not the worktree's" ;; *) ok "a session's run is its own, not the worktree's" ;; esac
differs() { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3"; fi; }
differs "$RUN_A" "$RUN_B" "two sessions have two runs"
check_eq "$(FLTH_RUN_ID="$RUN_A" one run-id)" "$RUN_A" "a session inside a session belongs to the same run"
differs "$(FLTH_RUN_ID="$RUN_A" other_tree run-id)" "$RUN_A" "another tree's run is not inherited"
first="$(one run-id)"
differs "$first" "$(one run-id)" "each new run's id is drawn afresh"

root_a="$(FLTH_RUN_ID="$RUN_A" one exec 'echo "$FLTH_RUN_ROOT"')"
check_eq "$?" 0 "a call runs in its run"
check_eq "$root_a" "$ROOTS/$RUN_A" "with its root on the guest's disk under a random name"
root_b="$(FLTH_RUN_ID="$RUN_B" two exec 'echo "$FLTH_RUN_ROOT"')"
check_eq "$root_b" "$ROOTS/$RUN_B" "and another suite's root is another directory"
FLTH_RUN_ID="$RUN_A" one exec 'exit 7' 2>/dev/null
check_eq "$?" 7 "a call's status is the command's"
check_eq "$(FLTH_RUN_ID="$RUN_A" one exec 'printf "%s" "it'"'"'s"')" "it's" "and a command's quoting survives the way in"
# (The stub engine's rewrite of /cache reaches /var/cache too, so that line ends in it.)
for place in "tmp /tmp" "var-tmp /var/tmp" "var-cache /var/" "mnt /mnt"; do
    check_contains "$(cat "$TOOLS")" "mount --bind $root_a/${place% *} ${place#* }" "the run has ${place#* } to itself"
done
check_eq "$(grep -c "unshare --mount=$FLTH_TEST_STUB/guest-runs/ns/$RUN_A " "$TOOLS" | tr -d ' ')" 1 "only a run's first call makes its namespace"

before="$(grep -c '^unshare' "$TOOLS" | tr -d ' ')"
check_eq "$(one exec 'echo "$FLTH_RUN_ROOT"')" "$ROOTS/$(shared_id="$(one exec 'basename "$FLTH_RUN_ROOT"')"; echo "$shared_id")" "a call outside any session has a run too"
case "$(one exec 'echo "$FLTH_RUN_ROOT"')" in
    *-worktree) ok "the worktree's standing run" ;;
    *) bad "the worktree's standing run" ;;
esac
check_eq "$(grep -c '^unshare' "$TOOLS" | tr -d ' ')" "$((before + 1))" "made once"

# guest-test's copy of the tree.
: > "$TOOLS"
FLTH_RUN_ID="$RUN_A" one guest-tree 2>/dev/null
check_eq "$?" 0 "a run takes its own copy of its tree"
check_contains "$(cat "$TOOLS")" "tar -C $FLTH_TEST_STUB/guest-repo/one --exclude-caches-all --exclude=./tmp --exclude=./.vm-share -cf - ." "leaving behind caches, scratch and the share"
check_contains "$(cat "$TOOLS")" "mount --bind $root_a/tree $FLTH_TEST_STUB/guest-repo" "mounted where the suite looks"
check_eq "$(readlink "$root_a/tree/.vm-share")" /share "the share stays reachable by the name it had"
: > "$TOOLS"
FLTH_RUN_ID="$RUN_A" one guest-tree 2>/dev/null
check_eq "$(cat "$TOOLS")" "" "taken once"

# THE END OF A RUN stops its commands, and nobody else's.
p_a="$(guest_process "$RUN_A")"
p_b="$(guest_process "$RUN_B")"
printf '/dev/loop3 111\n' > "$FLTH_TEST_STUB/losetup_list"
touch "$root_a/image"
# shellcheck disable=SC2012  # the one thing both hosts' tools print the same way
inode="$(ls -i "$root_a/image" | awk '{print $1}')"
printf '/dev/loop3 %s\n/dev/loop4 1\n' "$inode" > "$FLTH_TEST_STUB/losetup_list"
: > "$TOOLS"
one session-end "$A" 2>/dev/null
check_eq "$?" 0 "a suite's session ends"
check_eq "$(alive "$p_a")" gone "its run's commands stop"
check_eq "$(alive "$p_b")" alive "another run's commands do not"
check_eq "$([ -e "$root_a" ] && echo left)" "" "its root is deleted"
check_eq "$([ -d "$root_b" ] && echo kept)" kept "another run's root is not"
check_contains "$(cat "$TOOLS")" "losetup -d /dev/loop3" "a loop device backed by its root is detached"
check_lacks "$(cat "$TOOLS")" "losetup -d /dev/loop4" "and one backed by something else is not"
check_lacks "$(cat "$TOOLS")" "umount $FLTH_TEST_STUB/guest-runs/ns/$RUN_B" "and another run's namespace stays"

# A session inside a session: the run lasts as long as the outer one.
begin_suite one; O=$SUITE; RUN_O=$RUN
/bin/sleep 300 >/dev/null 2>&1 &
N=$!; SUITES="$SUITES $N"
(FLTH_RUN_ID="$RUN_O" one session-begin "$N") 2>/dev/null
FLTH_RUN_ID="$RUN_O" one exec true
p_o="$(guest_process "$RUN_O")"
one session-end "$N" 2>/dev/null
check_eq "$(alive "$p_o")" alive "the end of an inner session leaves the run"
one session-end "$O" 2>/dev/null
check_eq "$(alive "$p_o")" gone "the end of the outer one ends it"

# A SUITE KILLED OUTRIGHT: what it left is cleaned up when it is dropped.
kill -KILL "$B"
wait "$B" 2>/dev/null
out="$(one status)"
check_lacks "$out" "pid $B" "a killed suite is off the list"
check_eq "$(alive "$p_b")" gone "and what it left running in the guest is stopped"
check_eq "$([ -e "$root_b" ] && echo left)" "" "and its root is deleted"

# A LOST GUEST TAKES EVERY SUITE WITH IT, and says so.
begin_suite two; L=$SUITE
one exec 'exit 255' 2>"$SANDBOX/lost"
check_eq "$?" 255 "a lost connection keeps its status"
check_contains "$(cat "$SANDBOX/lost")" "every suite using it lost it too: run-one (pid $L)" "and names the suites a crash took with it"
one session-end "$L" 2>/dev/null
touch "$FLTH_TEST_STUB/guest_answers"
one exec 'exit 255' 2>"$SANDBOX/lost"
check_lacks "$(cat "$SANDBOX/lost")" "every suite" "a guest that still answers lost nobody"

# A REAL SESSION, through vm-session.sh.
cat > "$SRC/one/work.sh" <<SCRIPT
#!/usr/bin/env bash
. "$SESSION"
echo "\$FLTH_RUN_ID" > "$SANDBOX/run-seen"
"$VM" exec 'echo "\$FLTH_RUN_ROOT"' > "$SANDBOX/root-seen"
SCRIPT
(cd "$SRC/one" && FLTH_SHARED_ROOT="$SRC" bash work.sh) 2>/dev/null
check_eq "$?" 0 "a script that sources the session runs"
check_eq "$(cat "$SANDBOX/root-seen")" "$ROOTS/$(cat "$SANDBOX/run-seen")" "and its calls land in the run it was given"
check_eq "$([ -e "$(cat "$SANDBOX/root-seen")" ] && echo left)" "" "which ends with it"

# guest-test goes through all of it.
printf '[test]\nguest_command = "echo guest-suite"\n' >> "$SRC/one/fs-linux-test-harness.toml"
: > "$TOOLS"
out="$(cd "$SRC/one" && FLTH_SHARED_ROOT="$SRC" "$VM" guest-test 2>/dev/null)"
check_eq "$?" 0 "guest-test passes"
check_contains "$out" guest-suite "and runs the suite"
check_contains "$(cat "$TOOLS")" "--exclude-caches-all" "from its own copy of the tree"

# A SIGNAL TO THE SESSION ALONE stops guest-test and test, not only a signal to its
# whole process group: the session must not be waiting on a foreground command.
for kind in 'guest_command' 'command'; do
    printf '[project]\nname = "run-signal"\n\n[setup]\nscript = "setup.sh"\n\n[test]\n%s = "/bin/sleep 120"\n' "$kind" > "$SRC/one/signal.toml"
    task="guest-test"
    if [ "$kind" = command ]; then task="test"; fi
    (cd "$SRC/one" && FLTH_CONFIG="$SRC/one/signal.toml" FLTH_SHARED_ROOT="$SRC" exec "$VM" "$task") >/dev/null 2>&1 &
    runner=$!
    tries=0
    until [ -f "$FLTH_CACHE_DIR/machines/shared-debian-12/sessions/$runner" ] || [ "$tries" -ge 100 ]; do
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    /bin/sleep 1
    t0=$SECONDS
    kill -TERM "$runner"
    wait "$runner"
    check_eq "$?" 143 "a TERM to $task's session alone ends it with the signal's status"
    if [ "$((SECONDS - t0))" -lt 30 ]; then
        ok "and does not wait for the suite ($task)"
    else
        bad "and does not wait for the suite ($task): it took $((SECONDS - t0))s"
    fi
done

# A CONSUMER THAT DOES NOT OPT IN: its calls go as they went.
one down >/dev/null 2>&1
: > "$TOOLS"
(cd "$SRC/one" && "$VM" up) >/dev/null 2>&1
: > "$FLTH_TEST_STUB/scripts"
out="$(cd "$SRC/one" && "$VM" exec 'echo private')"
check_eq "$out" private "with the setting off a call runs"
check_lacks "$(cat "$FLTH_TEST_STUB/scripts")" "run.sh" "and goes through no run"
check_eq "$(cat "$TOOLS")" "" "and no mount or namespace is touched"

finish shared-guest-run
