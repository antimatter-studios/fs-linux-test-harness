#!/usr/bin/env bash
#
# session-run.sh — `vm.sh session <command...>`: a command run inside a
# session, so it is one run on the shared guest, ended when the command ends,
# however it ends (#37, #220).
#
# A consumer's test process boots the guest itself (`vm.sh up` from its first
# oracle call). Run as a session, the command is on the list of suites using the
# guest while it lives, so nothing stops the guest under it, and its run is
# cleaned up and taken off the list when it ends. The guest stays up for the
# next run: `chore vm:down` stops it when nobody is using it.
#
# Driven through the real vm.sh and vm-session.sh over the stub engine. The
# command is a stand-in that does what an oracle test process does: `vm.sh up`,
# then passes, fails, or waits to be killed.
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
MACHINE="$FLTH_CACHE_DIR/machines/shared-debian-12"
OUT="$SANDBOX/out"
mkdir -p "$OUT"

vm_state() { cat "$FLTH_TEST_STUB/state"; }
reset() {
    rm -rf "$MACHINE/sessions" "$MACHINE/keep-running" "${OUT:?}"/*
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
# that moment: a stop that ran before the command had finished would show
# up as `stopped` there.
cat > "$C/oracle.sh" <<EOF
#!/usr/bin/env bash
"$VM" up >/dev/null 2>&1 || exit 1
find "$MACHINE/sessions" -type f 2>/dev/null | wc -l | tr -d ' ' > "$OUT/sessions-during"
trap 'cat "$FLTH_TEST_STUB/state" > "$OUT/state-when-killed"; exit 143' TERM
echo "\$\$" > "$OUT/pid"
case "\$1" in
    pass) exit 0 ;;
    fail) exit 101 ;;
    hang)
        "$REAL_SLEEP" 30 & wait \$!
        ;;
    sleep) exec "$REAL_SLEEP" 30 ;;
esac
EOF
chmod +x "$C/oracle.sh"

run() { (cd "$C" && "${RUN[@]}" "$@") >/dev/null 2>&1; }

expect_ended() {
    # expect_ended <how the run ended>
    check_eq "$(vm_state)" running "$1: the guest it booted stays up for the next run"
    check_eq "$(sessions)" 0 "$1: and the run is off the list of suites using it"
}

# --- a run that passes, and one that fails ------------------------------

reset
run ./oracle.sh pass
check_eq "$?" 0 "a passing command: the run exits 0"
check_eq "$(cat "$OUT/sessions-during" 2>/dev/null)" 1 "the command ran inside a session the reaper can see"
expect_ended "a passing command"

reset
run ./oracle.sh fail
check_eq "$?" 101 "a failing command: the run keeps its status"
expect_ended "a failing command"

reset
run -- ./oracle.sh pass
check_eq "$?" 0 "a leading -- is taken as the end of the runner's options"
expect_ended "a command after --"

# --- the command is run as given ----------------------------------------

reset
got="$(cd "$C" && printf 'from stdin\n' | "${RUN[@]}" bash -c 'read -r l; printf "[%s]" "$@" "$l"' flth-arg one "two words" 'a;b' 2>/dev/null)"
check_eq "$got" "[one][two words][a;b][from stdin]" \
    "arguments reach the command exactly, and so does stdin"

# --- a run that is killed -----------------------------------------------

# Waits for the stand-in to have booted the VM, then sends the signal.
start_hang() {
    # start_hang <mode>; sets $pid to the runner's pid
    local monitor=0
    case "$-" in *m*) monitor=1 ;; esac
    set -m
    (cd "$C" && exec "${DEFAULT_INT[@]}" "${RUN[@]}" ./oracle.sh "$1") >/dev/null 2>&1 &
    pid=$!
    [ "$monitor" = 1 ] || set +m
    local tries=0
    # A boot takes more than 10 seconds at a load average of 300. Only a failure
    # waits this out, and it says so rather than signalling a run with no command.
    until [ -s "$OUT/pid" ] || [ "$tries" -ge 2400 ]; do
        "$REAL_SLEEP" 0.05; tries=$((tries + 1))
    done
    [ -s "$OUT/pid" ] || bad "the command never started, so the case after this says nothing"
}

# TERM to the runner alone — `kill <pid>`, a supervisor that signals the
# process it started. The command must be told, and the run must last
# until the command has finished with it: bash runs an EXIT trap the
# moment TERM ends it, with a foreground child still running, and a run
# ended under a live test process leaves its later calls outside any run.
reset
start_hang hang
kill -TERM "$pid" 2>/dev/null
wait "$pid"
check_eq "$?" 143 "killed by TERM: the run's status is 128+15"
check_eq "$(cat "$OUT/state-when-killed" 2>/dev/null)" running \
    "the command was passed the TERM, and the VM was still up when it handled it"
check_eq "$(command_left)" gone \
    "and the command is not left running"
expect_ended "a run killed by TERM"

# INT to the runner: the command must not be ignoring it. bash starts a
# background job with INT and QUIT ignored when job control is off, which
# would make Ctrl-C forwarded to a test binary do nothing.
reset
start_hang sleep
interrupt_started=$SECONDS
kill -INT "$pid" 2>/dev/null
wait "$pid"
check_eq "$?" 130 "killed by INT: the command is interrupted, and the run's status is 128+2"
if [ "$((SECONDS - interrupt_started))" -lt 10 ]; then
    ok "SIGINT interrupts the 30-second command instead of waiting for it to finish"
else
    bad "SIGINT interrupts the 30-second command instead of waiting for it to finish"
fi
check_eq "$(command_left)" gone \
    "and the command is not left running"
expect_ended "a run killed by INT"

# TERM to the whole process group, as Ctrl-C, a CI cancel or a timeout
# sends it. Job control gives the background run a group of its own.
reset
set -m
start_hang hang
set +m
kill -TERM -- "-$pid" 2>/dev/null
wait "$pid"
check_eq "$?" 143 "its process group killed by TERM: the run's status is 128+15"
expect_ended "a process group killed by TERM"

# --- what the session must not do ---------------------------------------

# A VM held with `chore vm:up` is a person's, not the run's (#36).
reset
(cd "$C" && "$VM" up && "$VM" hold) >/dev/null 2>&1
run ./oracle.sh pass
check_eq "$?" 0 "a run beside a held VM succeeds"
check_eq "$(vm_state)" running "and leaves the held VM running"
check_eq "$([ -f "$MACHINE/keep-running" ] && echo held)" held "and held"
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

# And a run whose boot never came up still ends cleanly.
reset
echo 3 > "$FLTH_TEST_STUB/up_failures"
run ./oracle.sh pass
check_eq "$?" 1 "a run whose boot failed fails"
check_eq "$(sessions)" 0 "and leaves no session marker"
rm -f "$FLTH_TEST_STUB/up_failures"

# --- no session where no VM can run -------------------------------------

# In the guest the command IS in the VM; on a host that cannot run one
# (a CI runner with no KVM) there is nothing to bring down. Either way the
# command runs as it would have without the runner, and the harness asks
# the engine nothing — a session there would be about a VM that could
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
