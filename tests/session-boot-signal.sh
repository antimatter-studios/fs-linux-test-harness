#!/usr/bin/env bash
#
# session-boot-signal.sh -- a boot that did not finish is not a VM to keep (#134).
#
# QEMU daemonizes early in `vagrant up`, and the shares are mounted late. A signal
# between the two ends the boot and leaves QEMU, so a guest stays up with /share
# and /repo never mounted. Measured on arm64 macOS: `vm.sh run` then exits 0 with
# both directories empty, because the guest answers and the state reads running.
#
# Real vm.sh, real session, real engine. Only what would need a host's provider is
# a stand-in: `vagrant up` starts QEMU in a session of its own, and has the shares
# only if it gets to its end. `ssh` answers a probe with what the guest would find.
# tests/session-vm-daemons.sh holds the daemons of a boot that did finish, on every
# path that keeps its VM; tests/smoke.sh holds that on a real guest.
#
# What is pinned:
#   - a session signalled during a boot leaves no guest behind, through
#     FLTH_KEEP_VM=1, a hold, another live session and another worktree, and the
#     next call boots one that has its shares;
#   - a guest left by a boot with no session to clean up is not taken as booted:
#     `up` and `run` replace it, `exec` refuses it, `reap` stops it;
#   - an `up` waiting for the signalled boot gets a guest with its shares;
#   - a boot still under way is left alone, and one that finished is kept.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMPDIR="${FLTH_TEST_SOCKET_ROOT:-/tmp}" new_sandbox

mkdir -p "$SANDBOX/harness"
cp -R "$REPO/scripts" "$REPO/vagrant" "$SANDBOX/harness/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/harness/scripts/host-tools.sh"
chmod +x "$SANDBOX/harness/scripts/host-tools.sh"
VM="$SANDBOX/harness/scripts/vm.sh"
export VM

BIN="$SANDBOX/bin"
export STUB="$SANDBOX/stub"
mkdir -p "$BIN" "$STUB"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"
ln -s "$BASH" "$BIN/bash"
# QEMU's stand-in has to be found by its command line, and a real VM on this
# host must not be what pgrep answers with.
printf '#!/bin/sh\nexit 1\n' > "$BIN/pgrep"
cat > "$BIN/ssh" <<'STUB'
#!/bin/sh
# Up to the end of the script, not of stdin: `vm.sh run` and `vm.sh exec` hold
# stdin open while they live, and end their script with this line.
script=""
while IFS= read -r line; do
    script="$script$line
"
    [ "$line" != 'exit "$flth_status"' ] || break
done
case "$script" in
    *share-probe*)
        if [ -e "$STUB/shares" ]; then echo shares-mounted; else echo shares-missing; fi
        ;;
esac
exit 0
STUB
# $STUB/boot says where a boot stops until the file changes or a signal comes:
#   before-qemu         a disposable boot, before QEMU starts
#   after-qemu          a disposable boot, with QEMU up and the shares not mounted
#   persist-after-qemu  a provisioning boot, at the same point
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
hold_boot() {
    : > "$STUB/booting"
    while [ "$(cat "$STUB/boot" 2>/dev/null)" = "$1" ]; do sleep 0.1; done
}
case "$1" in
    status) echo '1,default,state,stopped' ;;
    ssh-config) echo 'Host default' ;;
    up)
        echo "$$" > "$STUB/vagrant.pid"
        boot="$(cat "$STUB/boot" 2>/dev/null)"
        trap 'exit 143' TERM
        if [ "$boot" = before-qemu ] && [ "${FLTH_VM_DISPOSABLE:-}" = 1 ]; then
            hold_boot "$boot"
        fi
        perl -MPOSIX -e '
            exit 0 if fork;
            POSIX::setsid();
            exit 0 if fork;
            open STDIN, "<", "/dev/null";
            open STDOUT, ">", "/dev/null";
            open STDERR, ">", "/dev/null";
            open my $pid, ">", "$ENV{STUB}/qemu.pid" or exit 1;
            print {$pid} "$$\n";
            close $pid;
            exec { "/bin/sh" } "qemu-system-stub", "-c", q{n=0; while kill -0 "$FLTH_TEST_PID" 2>/dev/null && [ "$n" -lt 3600 ]; do sleep 1; n=$((n + 1)); done}, "$ARGV[0]/disk";
        ' "$VAGRANT_DOTFILE_PATH"
        until [ -s "$STUB/qemu.pid" ]; do sleep 0.05; done
        case "$boot:${FLTH_VM_DISPOSABLE:-}" in
            after-qemu:1 | persist-after-qemu:0) hold_boot "$boot" ;;
        esac
        : > "$STUB/shares"
        ;;
    halt)
        rm -f "$STUB/shares"
        if [ -s "$STUB/qemu.pid" ]; then
            kill -KILL "$(cat "$STUB/qemu.pid")" 2>/dev/null
            rm -f "$STUB/qemu.pid"
        fi
        ;;
esac
exit 0
STUB
chmod +x "$BIN/uname" "$BIN/pgrep" "$BIN/ssh" "$BIN/vagrant"
export PATH="$BIN:$PATH"

NAME=session-boot-signal
ONE="$SANDBOX/worktree-one"
TWO="$SANDBOX/worktree-two"
make_consumer "$ONE" "$NAME"
make_consumer "$TWO" "$NAME"
ONE="$(cd "$ONE" && pwd -P)"
TWO="$(cd "$TWO" && pwd -P)"
MACHINE="$FLTH_CACHE_DIR/machines/$NAME"
export UP_FROM=""

# The session's command: boots the VM, and then keeps working.
cat > "$SANDBOX/command.sh" <<'COMMAND'
#!/usr/bin/env bash
: > "$CASE/started"
if [ -n "$UP_FROM" ]; then
    (cd "$UP_FROM" && FLTH_CONFIG="$UP_FROM/fs-linux-test-harness.toml" "$VM" up) || exit 7
else
    "$VM" up || exit 7
fi
: > "$CASE/ready"
sleep 300 &
wait
COMMAND

alive() {
    local state
    [ -n "$1" ] || return 1
    state="$(ps -o stat= -p "$1" 2>/dev/null)"
    case "$state" in '' | *Z*) return 1 ;; esac
    return 0
}
pid_of() { cat "$STUB/$1.pid" 2>/dev/null; }
wait_until() {
    # wait_until <tenths of a second> <command...>
    local tries="$1" n=0
    shift
    until "$@"; do
        [ "$n" -lt "$tries" ] || return 1
        sleep 0.1
        n=$((n + 1))
    done
}
# shellcheck disable=SC2329  # wait_until calls these by name
file_exists() { [ -e "$1" ]; }
# shellcheck disable=SC2329
dead() { ! alive "$1"; }
slot_holder() { awk -F'\t' '{print $2}' "$FLTH_STATE_DIR/slot.lock/holder" 2>/dev/null; }
vm_in() { (cd "$1" && shift && FLTH_CONFIG="$PWD/fs-linux-test-harness.toml" "$VM" "$@"); }

SESSION=""
start_session() {
    # start_session <case name> <worktree>
    export CASE="$SANDBOX/$1"
    mkdir -p "$CASE"
    set -m
    (cd "$2" && exec "$VM" session "$BASH" "$SANDBOX/command.sh") > "$CASE/log" 2>&1 &
    SESSION=$!
    set +m
}

# Signals the session and leaves STATUS. The watchdog only stops a session that
# would otherwise hold the suite: how long one takes is not what is held here.
signal_session() {
    start_watchdog 120 "$CASE/timeout" "$SESSION"
    kill -TERM "$SESSION" 2>/dev/null
    wait "$SESSION"
    STATUS=$?
    stop_watchdog
}

wait_for_boot_to_stop_short() {
    # wait_for_boot_to_stop_short <label>: the boot has reached where $STUB/boot says
    if wait_until 600 file_exists "$STUB/booting"; then
        ok "$1: the boot is under way"
    else
        bad "$1: the boot never got there ($(cat "$CASE/log" 2>/dev/null))"
    fi
}

check_no_guest() {
    # check_no_guest <label> <QEMU pid>
    if dead "$2"; then
        ok "$1: no guest is left without its shares"
    else
        bad "$1: a guest was left running without its shares (pid $2)"
    fi
    vm_in "$ONE" status > /dev/null 2>&1
    check_eq "$?" 1 "$1: the VM reads as down"
    check_eq "$(slot_holder)" "" "$1: the slot is given back"
}

check_probe_finds_shares() {
    # check_probe_finds_shares <label> <worktree>
    local out
    out="$(vm_in "$2" run share-probe 2>/dev/null)"
    check_eq "$?" 0 "$1: run succeeds"
    check_eq "$out" shares-mounted "$1: run finds the shares in the guest"
}

# Whatever a case or a failed check left running goes, so the next case starts
# clean and the suite leaves nothing on the host.
clean_up() {
    local name pid
    vm_in "$ONE" down > /dev/null 2>&1
    for name in vagrant qemu; do
        pid="$(pid_of "$name")"
        [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null
    done
    rm -f "${STUB:?}/vagrant.pid" "${STUB:?}/qemu.pid" "${STUB:?}/booting" "${STUB:?}/boot" "${STUB:?}/shares"
}

# --- A session signalled during a boot, on each path that would keep a VM.

signalled_during_boot() {
    # signalled_during_boot <label> <worktree>; SESSION_SETUP names a function run
    # once the boot is under way.
    local label="$1" worktree="$2" qemu
    echo after-qemu > "$STUB/boot"
    start_session "$label" "$worktree"
    wait_for_boot_to_stop_short "$label"
    qemu="$(pid_of qemu)"
    if alive "$qemu"; then
        ok "$label: QEMU is up"
    else
        bad "$label: QEMU is not up, so this case is not the one it means to be"
    fi
    [ -z "${SESSION_SETUP:-}" ] || "$SESSION_SETUP"
    signal_session
    check_eq "$STATUS" 143 "$label: the session exits 143"
    check_no_guest "$label" "$qemu"
    rm -f "$STUB/boot"
    check_probe_finds_shares "$label: the next call" "$ONE"
    clean_up
}

# The disk is provisioned once, so that the cases below stop on a disposable boot.
vm_in "$ONE" up > "$SANDBOX/first-up.log" 2>&1
check_eq "$?" 0 "the first up provisions the disk ($(tail -n 1 "$SANDBOX/first-up.log"))"
clean_up

export FLTH_KEEP_VM=1
signalled_during_boot keep "$ONE"
unset FLTH_KEEP_VM

# shellcheck disable=SC2329  # signalled_during_boot calls it through SESSION_SETUP
hold_it() { vm_in "$ONE" hold > /dev/null 2>&1; }
SESSION_SETUP=hold_it
signalled_during_boot held "$ONE"
SESSION_SETUP=""

sleep 300 &
other=$!
vm_in "$ONE" session-begin "$other"
signalled_during_boot other-session "$ONE"
kill -KILL "$other" 2>/dev/null
wait "$other" 2>/dev/null

UP_FROM="$ONE"
signalled_during_boot other-worktree "$TWO"
UP_FROM=""

# With nothing to keep it for, as #130 measured.
signalled_during_boot plain "$ONE"

# --- Before QEMU has started there is no guest, and the slot still comes back.

export FLTH_KEEP_VM=1
echo before-qemu > "$STUB/boot"
start_session before-qemu "$ONE"
wait_for_boot_to_stop_short before-qemu
signal_session
check_eq "$STATUS" 143 "before-qemu: the session exits 143"
check_eq "$(pid_of qemu)" "" "before-qemu: QEMU never started"
check_eq "$(slot_holder)" "" "before-qemu: the slot is given back"
unset FLTH_KEEP_VM
clean_up

# --- A provisioning boot: nothing on its disk is recorded as provisioned.

export FLTH_KEEP_VM=1
rm -f "$MACHINE/base.sha256"
echo persist-after-qemu > "$STUB/boot"
start_session provisioning "$ONE"
wait_for_boot_to_stop_short provisioning
qemu="$(pid_of qemu)"
signal_session
check_eq "$STATUS" 143 "provisioning: the session exits 143"
check_no_guest provisioning "$qemu"
if [ ! -e "$MACHINE/base.sha256" ]; then
    ok "provisioning: the disk is not recorded as provisioned"
else
    bad "provisioning: the disk is recorded as provisioned by a boot that did not finish"
fi
unset FLTH_KEEP_VM
rm -f "$STUB/boot"
check_probe_finds_shares "provisioning: the next call" "$ONE"
clean_up

# --- No session to clean up: the guest stays, and nothing takes it as booted.

export CASE="$SANDBOX/no-session"
mkdir -p "$CASE"
stopped_up() {
    echo after-qemu > "$STUB/boot"
    rm -f "$STUB/booting"
    set -m
    (cd "$ONE" && exec "$VM" up) > "$CASE/log" 2>&1 &
    up_pid=$!
    set +m
    wait_for_boot_to_stop_short no-session
    kill -KILL -- "-$up_pid" 2>/dev/null
    wait "$up_pid" 2>/dev/null
    wait_until 100 dead "$(pid_of vagrant)" || true
    rm -f "$STUB/boot"
}
stopped_up
qemu="$(pid_of qemu)"
if alive "$qemu"; then
    ok "no session: the guest is still there"
else
    bad "no session: the guest went, so the checks below say nothing"
fi
out="$(vm_in "$ONE" status 2>&1)"
check_contains "$out" "did not finish" "no session: status says the boot did not finish"
out="$(vm_in "$ONE" exec share-probe 2>&1)"
check_eq "$?" 1 "no session: exec refuses the guest"
check_contains "$out" "did not finish" "no session: and says why"
check_lacks "$out" shares-missing "no session: and runs nothing there"
check_probe_finds_shares "no session: run" "$ONE"
if dead "$qemu"; then
    ok "no session: run replaced the guest"
else
    bad "no session: run used the guest of a boot that did not finish"
fi
clean_up

stopped_up
qemu="$(pid_of qemu)"
vm_in "$ONE" up > /dev/null 2>&1
check_eq "$?" 0 "no session: up succeeds"
if dead "$qemu" && [ -e "$STUB/shares" ]; then
    ok "no session: up replaced the guest with one that has its shares"
else
    bad "no session: up took the guest of a boot that did not finish as booted"
fi
clean_up

stopped_up
qemu="$(pid_of qemu)"
vm_in "$ONE" hold > /dev/null 2>&1
vm_in "$ONE" reap > /dev/null 2>&1
check_no_guest "no session: reap" "$qemu"
clean_up

# --- An `up` waiting for the signalled boot gets a guest with its shares.

echo after-qemu > "$STUB/boot"
start_session waiting-first "$ONE"
wait_for_boot_to_stop_short waiting
first="$SESSION"
first_vagrant="$(pid_of vagrant)"
qemu="$(pid_of qemu)"
start_session waiting-second "$ONE"
second="$SESSION"
second_case="$CASE"
if wait_until 300 file_exists "$second_case/started"; then
    ok "waiting: the second session's command has started"
else
    bad "waiting: the second session's command never started"
fi
kill -TERM "$first" 2>/dev/null
wait_until 300 dead "$first_vagrant" || bad "waiting: the first boot's vagrant did not end"
rm -f "$STUB/boot"
wait "$first"
check_eq "$?" 143 "waiting: the first session exits 143"
if wait_until 600 file_exists "$second_case/ready"; then
    ok "waiting: the second session's up finished"
else
    bad "waiting: the second session's up never finished ($(cat "$second_case/log"))"
fi
if dead "$qemu"; then
    ok "waiting: the guest of the boot that did not finish has gone"
else
    bad "waiting: the second session took the guest of a boot that did not finish"
fi
check_probe_finds_shares "waiting: the second session" "$ONE"
export CASE="$second_case"
SESSION="$second"
signal_session
check_eq "$STATUS" 143 "waiting: the second session exits 143"
check_no_guest "waiting: at the end" "$(pid_of qemu)"
clean_up

# --- A boot still under way is left alone by whatever else ends beside it.

echo after-qemu > "$STUB/boot"
start_session booting "$ONE"
wait_for_boot_to_stop_short booting
booting="$SESSION"
booting_case="$CASE"
qemu="$(pid_of qemu)"
vm_in "$ONE" reap > /dev/null 2>&1
if alive "$qemu"; then
    ok "booting: reap leaves a boot that is under way"
else
    bad "booting: reap stopped a boot that was under way"
fi
(cd "$ONE" && FLTH_KEEP_VM=1 "$VM" session true) > /dev/null 2>&1
check_eq "$?" 0 "booting: another session ends beside it"
if alive "$qemu"; then
    ok "booting: and leaves it"
else
    bad "booting: and stopped a boot that was under way"
fi
rm -f "$STUB/boot"
if wait_until 600 file_exists "$booting_case/ready"; then
    ok "booting: the boot finishes"
else
    bad "booting: the boot never finished ($(cat "$booting_case/log"))"
fi
check_probe_finds_shares "booting: the guest" "$ONE"
export CASE="$booting_case"
SESSION="$booting"
signal_session
check_eq "$STATUS" 143 "booting: the session exits 143"
check_no_guest "booting: at the end" "$qemu"
clean_up

# --- A boot that finished is still kept.

export FLTH_KEEP_VM=1
start_session finished "$ONE"
if wait_until 600 file_exists "$CASE/ready"; then
    ok "finished: the boot finishes"
else
    bad "finished: the boot never finished ($(cat "$CASE/log"))"
fi
qemu="$(pid_of qemu)"
signal_session
check_eq "$STATUS" 143 "finished: the session exits 143"
if alive "$qemu"; then
    ok "finished: FLTH_KEEP_VM=1 keeps the VM"
else
    bad "finished: FLTH_KEEP_VM=1 did not keep a VM whose boot finished"
fi
unset FLTH_KEEP_VM
check_probe_finds_shares "finished: the kept guest" "$ONE"
if alive "$qemu"; then
    ok "finished: run uses the guest it was given"
else
    bad "finished: run replaced a guest whose boot finished"
fi
clean_up

finish session-boot-signal
