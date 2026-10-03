#!/usr/bin/env bash
#
# session-run.sh — `vm.sh session <command...>`: a command run inside a
# session, so the VM it boots comes down and the machine-wide slot is
# released when it ends, however it ends (#37).
#
# THE LEAK THIS CLOSES. A consumer's test process boots the VM itself
# (`vm.sh up` from its first oracle call), and the slot that boot takes
# is ONE FOR THE WHOLE MACHINE. Release was left to chore's `after_all`
# reaper, which only runs inside a chore invocation of that consumer, so
# a tier run any other way (`scripts/test.sh`, `cargo test` by hand)
# exited with the VM idle and the slot held, and every other repository
# queued behind it until the guest's idle deadline.
#
# Driven through the real vm.sh, vm-slot.sh and vm-session.sh over the
# stub engine. The command is a stand-in that does what an oracle test
# process does: `vm.sh up`, then passes, fails, or waits to be killed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
# Before make_stub_harness puts its no-op `sleep` first on PATH: a test
# that waits to be killed has to really wait.
REAL_SLEEP="$(command -v sleep)"
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
# The public spelling, which execs vm-session.sh with the command.
RUN=("$VM" session)

C="$SANDBOX/consumer"
make_consumer "$C" run-test
MACHINE="$FLTH_CACHE_DIR/machines/run-test"
OUT="$SANDBOX/out"
mkdir -p "$OUT"

slot_holder() { awk -F'\t' '{print $2}' "$FLTH_STATE_DIR/slot.lock/holder" 2>/dev/null; }
vm_state() { cat "$FLTH_TEST_STUB/state"; }
reset() {
    rm -rf "$FLTH_STATE_DIR/slot.lock" "$MACHINE/sessions" "$MACHINE/keep-running" "${OUT:?}"/*
    stub_state absent; stub_reset_calls
}
host_tools() { printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$STUB_HARNESS/scripts/host-tools.sh"; }
command_left() {
    local p
    p="$(cat "$OUT/pid" 2>/dev/null)"
    [ -n "$p" ] || { echo never-started; return; }
    if kill -0 "$p" 2>/dev/null; then echo alive; else echo gone; fi
}
sessions() { find "$MACHINE/sessions" -type f 2>/dev/null | wc -l | tr -d ' '; }

# What a test process does with the VM, then how it ends. It records the
# session markers it could see and, when it is killed, the VM's state at
# that moment: a teardown that ran before the command had finished would
# show up as `stopped` there.
cat > "$C/oracle.sh" <<EOF
#!/usr/bin/env bash
"$VM" up >/dev/null 2>&1 || exit 1
find "$MACHINE/sessions" -type f 2>/dev/null | wc -l | tr -d ' ' > "$OUT/sessions-during"
echo "\$\$" > "$OUT/pid"
case "\$1" in
    pass) exit 0 ;;
    fail) exit 101 ;;
    hang)
        trap 'cat "$FLTH_TEST_STUB/state" > "$OUT/state-when-killed"; exit 143' TERM
        "$REAL_SLEEP" 30 & wait \$!
        ;;
    sleep) exec "$REAL_SLEEP" 30 ;;
esac
EOF
chmod +x "$C/oracle.sh"

run() { (cd "$C" && "${RUN[@]}" "$@") >/dev/null 2>&1; }

expect_released() {
    # expect_released <how the run ended>
    check_eq "$(vm_state)" stopped "$1: the VM it booted is down afterwards"
    check_eq "$(slot_holder)" "" "$1: and the slot is free"
    check_eq "$(sessions)" 0 "$1: and no session marker is left behind"
}

# --- a run that passes, and one that fails ------------------------------

reset
run ./oracle.sh pass
check_eq "$?" 0 "a passing command: the run exits 0"
check_eq "$(cat "$OUT/sessions-during" 2>/dev/null)" 1 "the command ran inside a session the reaper can see"
expect_released "a passing command"

reset
run ./oracle.sh fail
check_eq "$?" 101 "a failing command: the run keeps its status"
expect_released "a failing command"

reset
run -- ./oracle.sh pass
check_eq "$?" 0 "a leading -- is taken as the end of the runner's options"
expect_released "a command after --"

# --- the command is run as given ----------------------------------------

reset
got="$(cd "$C" && printf 'from stdin\n' | "${RUN[@]}" bash -c 'read -r l; printf "[%s]" "$@" "$l"' flth-arg one "two words" 'a;b' 2>/dev/null)"
check_eq "$got" "[one][two words][a;b][from stdin]" \
    "arguments reach the command exactly, and so does stdin"

# --- a run that is killed -----------------------------------------------

# Waits for the stand-in to have booted the VM, then sends the signal.
start_hang() {
    # start_hang <mode>; sets $pid to the runner's pid
    (cd "$C" && exec "${RUN[@]}" ./oracle.sh "$1") >/dev/null 2>&1 &
    pid=$!
    local tries=0
    until [ -s "$OUT/pid" ] || [ "$tries" -ge 200 ]; do
        "$REAL_SLEEP" 0.05; tries=$((tries + 1))
    done
}

# TERM to the runner alone — `kill <pid>`, a supervisor that signals the
# process it started. The command must be told, and the VM must stay up
# until the command has finished with it: bash runs an EXIT trap the
# moment TERM ends it, with a foreground child still running, and a
# teardown under a live test process lets its next `vm.sh up` boot the VM
# again outside any session.
reset
start_hang hang
kill -TERM "$pid" 2>/dev/null
wait "$pid"
check_eq "$?" 143 "killed by TERM: the run's status is 128+15"
check_eq "$(cat "$OUT/state-when-killed" 2>/dev/null)" running \
    "the command was passed the TERM, and the VM was still up when it handled it"
check_eq "$(command_left)" gone \
    "and the command is not left running"
expect_released "a run killed by TERM"

# INT to the runner: the command must not be ignoring it. bash starts a
# background job with INT and QUIT ignored when job control is off, which
# would make Ctrl-C forwarded to a test binary do nothing.
reset
start_hang sleep
kill -INT "$pid" 2>/dev/null
wait "$pid"
check_eq "$?" 130 "killed by INT: the command is interrupted, and the run's status is 128+2"
check_eq "$(command_left)" gone \
    "and the command is not left running"
expect_released "a run killed by INT"

# TERM to the whole process group, as Ctrl-C, a CI cancel or a timeout
# sends it. Job control gives the background run a group of its own.
reset
set -m
start_hang hang
set +m
kill -TERM -- "-$pid" 2>/dev/null
wait "$pid"
check_eq "$?" 143 "its process group killed by TERM: the run's status is 128+15"
expect_released "a process group killed by TERM"

# --- what the session must not do ---------------------------------------

# Never free a slot another repository holds. The holder is fresh, so it
# is inside the boot grace and cannot be reclaimed; with no wait allowed,
# the command's boot is refused, and the run's teardown must leave that
# holder exactly where it was.
reset
mkdir -p "$FLTH_STATE_DIR/slot.lock"
printf '%s\t%s\t%s\t%s\n' "/elsewhere/vagrant" other "$(date +%s)" tok-other \
    > "$FLTH_STATE_DIR/slot.lock/holder"
(cd "$C" && FLTH_SLOT_WAIT=0 "${RUN[@]}" ./oracle.sh pass) >/dev/null 2>&1
check_eq "$?" 1 "a command whose boot was refused the slot fails"
check_eq "$(slot_holder)" other "and the other repository still holds the slot"

# A VM held with `chore vm:up` is a person's, not the run's (#36).
reset
(cd "$C" && "$VM" up && "$VM" hold) >/dev/null 2>&1
run ./oracle.sh pass
check_eq "$?" 0 "a run beside a held VM succeeds"
check_eq "$(vm_state)" running "and leaves the held VM running"
check_eq "$(slot_holder)" run-test "with the slot"
(cd "$C" && "$VM" down) >/dev/null 2>&1

reset
(cd "$C" && FLTH_KEEP_VM=1 "${RUN[@]}" ./oracle.sh pass) >/dev/null 2>&1
check_eq "$?" 0 "FLTH_KEEP_VM=1: the run succeeds"
check_eq "$(vm_state)" running "and the VM is left up, as asked"
(cd "$C" && "$VM" down) >/dev/null 2>&1

# A run whose tests never needed the VM — a unit tier, on a host that
# could have run one — ends without an engine call beyond the process
# check. Halting a machine that is not running is the engine's slowest
# answer (seconds of `vagrant halt` and `vagrant status`), and every tier
# a consumer runs would pay it.
reset
run bash -c 'exit 0'
check_eq "$?" 0 "a run that never boots the VM succeeds"
check_eq "$(stub_calls | grep -v '^prepare$')" "" "and its end asks the engine nothing beyond the process check"
check_eq "$(sessions)" 0 "and leaves no session marker"

# And a slot this machine took for a boot that never came up is still
# given back, on the process check's word that nothing is running.
reset
echo 3 > "$FLTH_TEST_STUB/up_failures"
run ./oracle.sh pass
check_eq "$?" 1 "a run whose boot failed fails"
check_eq "$(slot_holder)" "" "and the slot that boot took is free"
rm -f "$FLTH_TEST_STUB/up_failures"

# --- no session where no VM can run -------------------------------------

# In the guest the command IS in the VM; on a host that cannot run one
# (a CI runner with no KVM) there is nothing to bring down. Either way the
# command runs as it would have without the runner, and the harness asks
# the engine nothing — a teardown there would fail on a VM that could
# never have existed.
reset
out="$(cd "$C" && FLTH_GUEST=1 "${RUN[@]}" bash -c 'echo ran; exit 7' 2>&1)"
check_eq "$?" 7 "in the guest the command runs, with its own status"
check_eq "$out" ran "and nothing else is printed"
check_eq "$(stub_calls)" "" "and the engine is never asked anything"
check_eq "$(sessions)" 0 "and no session is recorded"

reset
host_tools 1
out="$(cd "$C" && "${RUN[@]}" bash -c 'echo ran; exit 7' 2>&1)"
check_eq "$?" 7 "on a host that cannot run the VM the command runs, with its own status"
check_eq "$out" ran "and nothing else is printed"
check_eq "$(stub_calls)" "" "and the engine is never asked anything"
host_tools 0

# --- usage --------------------------------------------------------------

out="$(cd "$C" && "${RUN[@]}" 2>&1)"
check_eq "$?" 2 "no command: exit 2"
check_contains "$out" "vm.sh session <command" "and the usage says how it is called"
check_eq "$(sessions)" 0 "and no session is begun"

mkdir -p "$SANDBOX/noconsumer"
out="$(cd "$SANDBOX/noconsumer" && "${RUN[@]}" bash -c 'echo reached' 2>&1)"
check_eq "$?" 1 "with no consumer config the run fails"
check_lacks "$out" "reached" "before the command runs"

finish session-run
