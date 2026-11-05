#!/usr/bin/env bash
#
# session-vm-daemons.sh -- what a boot leaves running on the host belongs to the
# VM, not to the command that happened to boot it (#130).
#
# A signal to a session ends every descendant of its command by signalling the
# command's process group (#117). A macOS provider starts `virtiofsd` and
# `notify-forwarder` from `vagrant up` and they stay in Vagrant's group, so when
# Vagrant ran in the command's group that signal also stopped them, and a VM that
# stayed up afterwards lost /share and /repo. QEMU daemonizes, so it never did.
#
# Real vm.sh, real session, real engine. Only what would need a host's provider
# is a stand-in: `vagrant up` starts the daemons the way the plugins do, with a
# plain spawn in its own group, and QEMU in a session of its own. tests/smoke.sh
# holds the guest's side of this on a real VM.
#
# What is pinned:
#   - on every path that leaves the VM up, the daemons survive and every
#     descendant of the command still ends, within the session's own bound;
#   - on the path that brings it down, and at a normal end, nothing is left,
#     although the provider's halt does not stop the forwarders itself;
#   - a guest that powered itself off leaves no forwarder when its session ends;
#   - both ways the plugin records a watcher are read, and a pid in that record
#     that is no forwarder is left alone;
#   - a boot still running when the signal arrives is still stopped, through a
#     Vagrant that ignores TERM too, and nothing it started is left behind.
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
: > "$STUB/forwarders"
# Every host takes the path the daemons exist on, and every script the shell
# under test, whatever is first on PATH.
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"
ln -s "$BASH" "$BIN/bash"
# QEMU's stand-in has to be found by its command line, and a real VM on this
# host must not be what pgrep answers with.
printf '#!/bin/sh\nexit 1\n' > "$BIN/pgrep"
cat > "$BIN/ssh" <<'STUB'
#!/bin/sh
cat > /dev/null
exit 0
STUB
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    status) echo '1,default,state,stopped' ;;
    ssh-config) echo 'Host default' ;;
    up)
        echo "$$" > "$STUB/vagrant.pid"
        # Measured: the session reached virtiofsd only by KILL, five seconds on.
        ( trap '' HUP INT TERM; exec sleep 300 ) &
        echo "$!" > "$STUB/virtiofsd.pid"
        # As the plugin records them, appended across boots. Named, because a pid
        # in that file may since have gone to something else.
        ( exec -a notify-forwarder-stub sleep 300 ) &
        echo "$!" > "$STUB/notify-forwarder.pid"
        echo "$!" >> "$STUB/forwarders"
        mkdir -p "$VAGRANT_DOTFILE_PATH/machines/default/qemu"
        if [ -e "$STUB/record-identity" ]; then
            # From plugin 0.7.7: a pid, then what the plugin compares before it signals.
            echo "$! {\"identity\":\"Wed Nov  4 12:00:00 2026 notify-forwarder-stub\"}" \
                >> "$VAGRANT_DOTFILE_PATH/machines/default/qemu/notify_watcher_host_pid"
        else
            echo "$!" >> "$VAGRANT_DOTFILE_PATH/machines/default/qemu/notify_watcher_host_pid"
        fi
        # A process outside the terminal's foreground group that reads the
        # terminal is stopped, so a boot must not be holding one as its stdin.
        if [ /dev/fd/0 -ef /dev/null ]; then echo null; else echo other; fi > "$STUB/stdin"
        boot="$(cat "$STUB/boot" 2>/dev/null)"
        case "$boot" in
            hang) trap 'echo TERM > "$STUB/vagrant-term"; exit 143' TERM ;;
            stubborn) trap 'echo TERM > "$STUB/vagrant-term"' TERM ;;
        esac
        case "$boot" in
            hang | stubborn)
                : > "$STUB/booting"
                while kill -0 "$FLTH_TEST_PID" 2>/dev/null; do sleep 1; done
                ;;
        esac
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
        ;;
    halt)
        # QEMU and virtiofsd, from the provider's own records. Not the forwarders:
        # the plugin stops them from a hook before GracefulHalt, which the macOS
        # provider's halt does not use, so a real halt leaves them running.
        for name in qemu virtiofsd; do
            [ -s "$STUB/$name.pid" ] || continue
            kill -KILL "$(cat "$STUB/$name.pid")" 2>/dev/null
            rm -f "${STUB:?}/${name:?}.pid"
        done
        ;;
esac
exit 0
STUB
chmod +x "$BIN/uname" "$BIN/pgrep" "$BIN/ssh" "$BIN/vagrant"
export PATH="$BIN:$PATH"

ONE="$SANDBOX/worktree-one"
TWO="$SANDBOX/worktree-two"
make_consumer "$ONE" session-vm-daemons
make_consumer "$TWO" session-vm-daemons
ONE="$(cd "$ONE" && pwd -P)"
TWO="$(cd "$TWO" && pwd -P)"
export UP_FROM=""

# The session's command: boots the VM, and starts a descendant of its own.
cat > "$SANDBOX/command.sh" <<'COMMAND'
#!/usr/bin/env bash
ps -o pgid= -p "$$" | tr -d ' ' > "$CASE/command.pgid"
if [ -n "$UP_FROM" ]; then
    (cd "$UP_FROM" && FLTH_CONFIG="$UP_FROM/fs-linux-test-harness.toml" "$VM" up) || exit 7
else
    "$VM" up || exit 7
fi
[ "${HOLD_AFTER_UP:-0}" = 0 ] || "$VM" hold || exit 8
if [ "${POWERS_OFF:-0}" != 0 ]; then
    # What the host sees of a guest that powers itself off: QEMU is gone, and
    # nothing asked Vagrant to stop anything.
    qemu="$(cat "$STUB/qemu.pid")"
    kill -KILL "$qemu"
    while kill -0 "$qemu" 2>/dev/null; do sleep 0.05; done
fi
[ "${ENDS_ITSELF:-0}" = 0 ] || exit 0
sleep 300 &
echo "$!" > "$CASE/descendant"
: > "$CASE/ready"
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
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
# shellcheck disable=SC2329  # wait_until calls these by name
group_has_members() {
    [ -n "$1" ] && ps -eo pgid=,stat= | awk -v want="$1" '$1 == want && $2 !~ /Z/ { found = 1 } END { exit !found }'
}
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
# shellcheck disable=SC2329
file_exists() { [ -e "$1" ]; }
dead() { ! alive "$1"; }
# shellcheck disable=SC2329
forwarders_gone() {
    local pid
    while read -r pid; do
        ! alive "$pid" || return 1
    done < "$STUB/forwarders"
}
# shellcheck disable=SC2329
group_is_empty() { ! group_has_members "$1"; }

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

# Signals the session and leaves STATUS and ELAPSED; bounded by a watchdog, so a
# session that will not end fails here instead of holding the suite.
signal_session() {
    local delivery="$1" started
    start_watchdog 25 "$CASE/timeout" "$SESSION"
    started=$SECONDS
    case "$delivery" in
        process) kill -TERM "$SESSION" 2>/dev/null ;;
        group) kill -TERM -- "-$SESSION" 2>/dev/null ;;
    esac
    wait "$SESSION"
    STATUS=$?
    ELAPSED=$((SECONDS - started))
    stop_watchdog
}

# Which half failed: a session that outlasted its bound, or one the watchdog stopped.
check_session_bound() {
    # check_session_bound <label>
    if [ -e "$CASE/timeout" ]; then
        bad "$1: the watchdog stopped the session after $ELAPSED seconds"
    elif [ "$ELAPSED" -ge 20 ]; then
        bad "$1: the session took $ELAPSED seconds, and its bound is 20"
    else
        ok "$1: the session ends within its bound"
    fi
}

# Whatever a failed check left running goes, so the next case starts clean and
# the suite leaves nothing on the host.
clean_up() {
    local name pid group
    (cd "$ONE" && "$VM" down) > /dev/null 2>&1
    for name in vagrant qemu notify-forwarder virtiofsd; do
        pid="$(pid_of "$name")"
        [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null
    done
    while read -r pid; do
        kill -KILL "$pid" 2>/dev/null
    done < "$STUB/forwarders"
    pid="$(cat "$CASE/descendant" 2>/dev/null)"
    [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null
    group="$(cat "$CASE/command.pgid" 2>/dev/null)"
    [ -z "$group" ] || kill -KILL -- "-$group" 2>/dev/null
    rm -f "${STUB:?}/vagrant.pid" "${STUB:?}/qemu.pid" "${STUB:?}/notify-forwarder.pid" \
        "${STUB:?}/virtiofsd.pid" "${STUB:?}/booting" "${STUB:?}/boot" "${STUB:?}/vagrant-term"
}

# The session ended, the VM stayed: the daemons are where it needs them, and
# everything of the command's is gone.
vm_stays_up() {
    # vm_stays_up <label> <delivery> <worktree>
    local label="$1" delivery="$2" worktree="$3" name group pid
    start_session "$label" "$worktree"
    if wait_until 300 file_exists "$CASE/ready"; then
        ok "$label: the command booted the VM"
    else
        bad "$label: the command never finished booting ($(cat "$CASE/log"))"
    fi
    group="$(cat "$CASE/command.pgid" 2>/dev/null)"
    for name in virtiofsd notify-forwarder; do
        pid="$(pid_of "$name")"
        if [ -n "$pid" ] && [ "$(pgid_of "$pid")" != "$group" ]; then
            ok "$label: $name is out of the command's process group"
        else
            bad "$label: $name is in the command's process group ($(pgid_of "$pid"))"
        fi
    done
    pid="$(cat "$CASE/descendant" 2>/dev/null)"
    signal_session "$delivery"
    check_eq "$STATUS" 143 "$label: the session exits 143"
    check_session_bound "$label"
    if dead "$pid"; then
        ok "$label: the command's descendant has ended"
    else
        bad "$label: the command's descendant survived (pid $pid)"
    fi
    for name in qemu virtiofsd notify-forwarder; do
        if alive "$(pid_of "$name")"; then
            ok "$label: $name still runs"
        else
            bad "$label: $name was stopped under a VM that stayed up"
        fi
    done
    (cd "$worktree" && "$VM" status) > /dev/null 2>&1
    check_eq "$?" 0 "$label: the VM stays up"
    (cd "$ONE" && "$VM" down) > /dev/null 2>&1
    check_eq "$?" 0 "$label: a later down stops it"
    if wait_until 30 forwarders_gone; then
        ok "$label: and the forwarders with it"
    else
        bad "$label: a forwarder outlived the down"
    fi
    clean_up
}

# --- The paths that leave the VM up.

export FLTH_KEEP_VM=1
vm_stays_up keep-process process "$ONE"
vm_stays_up keep-group group "$ONE"
unset FLTH_KEEP_VM

export HOLD_AFTER_UP=1
vm_stays_up held process "$ONE"
unset HOLD_AFTER_UP

sleep 300 &
other=$!
(cd "$ONE" && "$VM" session-begin "$other")
vm_stays_up other-session process "$ONE"
kill -KILL "$other" 2>/dev/null
wait "$other" 2>/dev/null

UP_FROM="$ONE"
vm_stays_up other-worktree process "$TWO"
UP_FROM=""

# --- The path that brings it down: nothing is left, as before.

start_session teardown "$ONE"
if wait_until 300 file_exists "$CASE/ready"; then
    ok "teardown: the command booted the VM"
else
    bad "teardown: the command never finished booting ($(cat "$CASE/log"))"
fi
qemu="$(pid_of qemu)"
virtiofsd="$(pid_of virtiofsd)"
forwarder="$(pid_of notify-forwarder)"
descendant="$(cat "$CASE/descendant" 2>/dev/null)"
signal_session process
check_eq "$STATUS" 143 "teardown: the session exits 143"
for pid in "$qemu" "$virtiofsd" "$forwarder" "$descendant"; do
    if wait_until 30 dead "$pid"; then
        ok "teardown: pid $pid has ended"
    else
        bad "teardown: pid $pid outlived the session"
    fi
done
(cd "$ONE" && "$VM" status) > /dev/null 2>&1
check_eq "$?" 1 "teardown: the VM is down"
if wait_until 30 forwarders_gone; then
    ok "teardown: no forwarder is left"
else
    bad "teardown: a forwarder outlived the session"
fi
clean_up

# --- And a command that simply ends.

export ENDS_ITSELF=1
start_session normal-end "$ONE"
wait "$SESSION"
check_eq "$?" 0 "normal end: the session keeps the command's status"
if [ -z "$(pid_of qemu)$(pid_of virtiofsd)" ]; then
    ok "normal end: the VM and virtiofsd were stopped"
else
    bad "normal end: QEMU or virtiofsd is left"
fi
if wait_until 30 forwarders_gone; then
    ok "normal end: no forwarder is left"
else
    bad "normal end: a forwarder outlived the session"
fi
unset ENDS_ITSELF
clean_up

# A pid in the plugin's record may belong to something else by now.

sleep 300 &
unrelated=$!
mkdir -p "$FLTH_CACHE_DIR/machines/session-vm-daemons/vagrant/machines/default/qemu"
echo "$unrelated" >> "$FLTH_CACHE_DIR/machines/session-vm-daemons/vagrant/machines/default/qemu/notify_watcher_host_pid"
(cd "$ONE" && "$VM" down) > /dev/null 2>&1
if alive "$unrelated"; then
    ok "an unrelated process with a recorded pid is left alone"
else
    bad "an unrelated process with a recorded pid was stopped"
fi
kill -KILL "$unrelated" 2>/dev/null
wait "$unrelated" 2>/dev/null

# --- The record as plugin 0.7.7 writes it: "<pid> {json}", one watcher a line. A
# line the harness cannot read must not lose the watcher: it removes the record
# afterwards, so the plugin's own hook has nothing left to stop (#82).

record="$FLTH_CACHE_DIR/machines/session-vm-daemons/vagrant/machines/default/qemu/notify_watcher_host_pid"
for action in down destroy; do
    ( exec -a notify-forwarder-stub sleep 300 ) &
    recorded=$!
    sleep 300 &
    unrelated=$!
    mkdir -p "${record%/*}"
    {
        printf '%s {"identity":"Wed Nov  4 12:00:00 2026 notify-forwarder-stub"}\n' "$recorded"
        printf '%s {"identity":"Wed Nov  4 12:00:00 2026 notify-forwarder-stub"}\n' "$unrelated"
    } >> "$record"
    (cd "$ONE" && "$VM" "$action") > /dev/null 2>&1
    if wait_until 30 dead "$recorded"; then
        ok "$action: a watcher recorded with its identity is stopped"
    else
        bad "$action: a watcher recorded with its identity outlived it"
    fi
    if alive "$unrelated"; then
        ok "$action: an unrelated process recorded with an identity is left alone"
    else
        bad "$action: an unrelated process recorded with an identity was stopped"
    fi
    kill -KILL "$recorded" "$unrelated" 2>/dev/null
    wait "$recorded" 2>/dev/null
    wait "$unrelated" 2>/dev/null
done

# --- A guest that powers itself off: the session finds no QEMU and halts nothing,
# so nothing else stops what the boot left running (#135).

export ENDS_ITSELF=1 POWERS_OFF=1
for format in pid identity; do
    label="powered off, $format record"
    if [ "$format" = identity ]; then : > "$STUB/record-identity"; fi
    start_session "powered-off-$format" "$ONE"
    wait "$SESSION"
    check_eq "$?" 0 "$label: the session keeps the command's status"
    if dead "$(pid_of qemu)"; then
        ok "$label: QEMU had gone before the session ended"
    else
        bad "$label: QEMU is still running"
    fi
    if wait_until 30 forwarders_gone; then
        ok "$label: no forwarder is left"
    else
        bad "$label: a forwarder outlived the session"
    fi
    rm -f "${STUB:?}/record-identity"
    clean_up
done
unset ENDS_ITSELF POWERS_OFF

# --- A boot still running when the signal arrives is stopped, and nothing it
# started is left: there is no VM for it to serve.

boot_interrupted() {
    # boot_interrupted <hang|stubborn>
    local label="boot-$1" vagrant group virtiofsd forwarder name
    echo "$1" > "$STUB/boot"
    start_session "$label" "$ONE"
    if wait_until 300 file_exists "$STUB/booting"; then
        ok "$label: the boot is under way"
    else
        bad "$label: the boot never started ($(cat "$CASE/log"))"
    fi
    vagrant="$(pid_of vagrant)"
    virtiofsd="$(pid_of virtiofsd)"
    forwarder="$(pid_of notify-forwarder)"
    group="$(pgid_of "$vagrant")"
    signal_session process
    check_eq "$STATUS" 143 "$label: the session exits 143"
    check_session_bound "$label"
    check_eq "$(cat "$STUB/vagrant-term" 2>/dev/null)" TERM "$label: vagrant was given the signal"
    if [ "$group" = "$(cat "$CASE/command.pgid" 2>/dev/null)" ] || [ "$(cat "$STUB/stdin" 2>/dev/null)" = null ]; then
        ok "$label: vagrant holds no stdin it could be stopped for reading"
    else
        bad "$label: vagrant is outside the command's group with stdin it could be stopped for reading"
    fi
    if wait_until 30 dead "$vagrant"; then
        ok "$label: vagrant has ended"
    else
        bad "$label: vagrant outlived the session"
    fi
    for name in virtiofsd:"$virtiofsd" notify-forwarder:"$forwarder"; do
        if wait_until 30 dead "${name#*:}"; then
            ok "$label: ${name%%:*} has ended"
        else
            bad "$label: ${name%%:*} outlived the boot"
        fi
    done
    if wait_until 30 group_is_empty "$group"; then
        ok "$label: nothing is left in vagrant's process group"
    else
        bad "$label: vagrant's process group $group still has members"
    fi
    clean_up
}

boot_interrupted hang
boot_interrupted stubborn

finish session-vm-daemons
