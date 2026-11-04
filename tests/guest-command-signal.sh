#!/usr/bin/env bash
#
# guest-command-signal.sh -- a signal to a session stops the guest command it
# started, and only that command, when the VM stays up (#139).
#
# Real vm.sh, real session, real engine. The stand-ins are `vagrant`, a QEMU found
# by its command line, and `ssh`, which puts the guest's shell in a session of its
# own, as sshd does, so no signal on the host reaches it. Its stdin is a relay that
# ends with the client, as the channel does. tests/smoke.sh holds this on a real VM.
#
# What is pinned:
#   - on each path that keeps the VM up, the guest command ends within a bound,
#     and another session's command in that guest keeps running;
#   - a command that ignores TERM ends too, and so does what it moved to another
#     process group, as `timeout` does;
#   - KILL to the host side stops it, since nothing on the host can act after that;
#   - a call that ends on its own keeps its status, its output and an empty stdin,
#     prints nothing of the machinery, and leaves what it started in the background.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMPDIR="${FLTH_TEST_SOCKET_ROOT:-/tmp}" new_sandbox
require_guest_bash || exit 1

mkdir -p "$SANDBOX/harness"
cp -R "$REPO/scripts" "$REPO/vagrant" "$SANDBOX/harness/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/harness/scripts/host-tools.sh"
chmod +x "$SANDBOX/harness/scripts/host-tools.sh"
VM="$SANDBOX/harness/scripts/vm.sh"
export VM

# The guest's fixed paths, in this copy only: its shell runs on this host.
export GUEST="$SANDBOX/guest"
mkdir -p "$GUEST"
sed -e "s|^FLTH_GUEST_HOLD_MARKER=.*|FLTH_GUEST_HOLD_MARKER=\"$GUEST/held\"|" \
    -e "s|^FLTH_GUEST_REARM_STAMP=.*|FLTH_GUEST_REARM_STAMP=\"$GUEST/rearmed\"|" \
    "$REPO/scripts/lib/common.sh" > "$SANDBOX/harness/scripts/lib/common.sh"

BIN="$SANDBOX/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"
ln -s "$BASH" "$BIN/bash"
# QEMU's stand-in has to be found by its command line, and a real VM on this host
# must not be what pgrep answers with.
printf '#!/bin/sh\nexit 1\n' > "$BIN/pgrep"
printf '#!/bin/sh\nexit 0\n' > "$BIN/shutdown"
cat > "$BIN/vagrant" <<'STUB'
#!/bin/sh
[ "$1" = ssh-config ] && echo 'Host default'
exit 0
STUB
cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
case " $* " in *' -N '* | *' -O '*) exit 0 ;; esac
perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or exit 127' "$FLTH_TEST_GUEST_BASH" -s < <(cat)
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

CONSUMER="$SANDBOX/consumer"
make_consumer "$CONSUMER" guest-command-signal
CONSUMER="$(cd "$CONSUMER" && pwd -P)"
export FLTH_CONFIG="$CONSUMER/fs-linux-test-harness.toml"
cd "$CONSUMER" || exit 1

identity="$("$VM" config | sed -n 's/^identity=//p')"
machine="$("$VM" config | sed -n 's/^machine=//p')"
mkdir -p "$identity"
# The VM is up and already carries this setup script, so nothing boots.
sha="$(shasum -a 256 setup.sh 2>/dev/null || sha256sum setup.sh)"
printf '%s\n' "${sha%% *}" > "$machine/setup.sha256"
QEMU_PID="$SANDBOX/qemu.pid"
perl -MPOSIX -e '
    exit 0 if fork;
    POSIX::setsid();
    open STDIN, "<", "/dev/null";
    open STDOUT, ">", "/dev/null";
    open STDERR, ">", "/dev/null";
    open my $pid, ">", $ARGV[1] or exit 1;
    print {$pid} "$$\n";
    close $pid;
    exec { "/bin/sh" } "qemu-system-stub", "-c", "while :; do /bin/sleep 1; done", "$ARGV[0]/disk";
' "$identity" "$QEMU_PID"
until [ -s "$QEMU_PID" ]; do /bin/sleep 0.05; done

# Whatever a case leaves behind, so a failing run holds no process.
LEFT="$SANDBOX/left"
: > "$LEFT"
# shellcheck disable=SC2329  # called by the trap below
clean_up() {
    local pid
    while read -r pid; do
        [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
    done < "$LEFT"
    kill -KILL "$(cat "$QEMU_PID" 2>/dev/null)" 2>/dev/null || true
}
trap 'clean_up; rm -rf "$SANDBOX"' EXIT

alive() {
    local state
    [ -n "$1" ] || return 1
    state="$(ps -o stat= -p "$1" 2>/dev/null)"
    case "$state" in '' | *Z*) return 1 ;; esac
    return 0
}

# How long a guest command gets to end, in the units of the guest's own loop: it
# counts 50 ticks of 0.1 seconds before KILL, so a slow machine slows both.
LIMIT_TICKS=150
ended_within_limit() {
    local ticks=0
    while alive "$1"; do
        [ "$ticks" -lt "$LIMIT_TICKS" ] || return 1
        command -p sleep 0.1
        ticks=$((ticks + 1))
    done
}

wait_for_file() {
    local ticks=0
    until [ -s "$1" ]; do
        [ "$ticks" -lt 200 ] || return 1
        command -p sleep 0.05
        ticks=$((ticks + 1))
    done
}

# The guest command, one per kind. Each records the shell's PID and its child's.
guest_command() {
    # guest_command <kind> <dir>
    case "$1" in
        plain)
            printf 'echo $$ > %s/shell; /bin/sleep 300 & echo $! > %s/child; wait' "$2" "$2"
            ;;
        stubborn)
            printf 'trap "echo TERM > %s/term" TERM; echo $$ > %s/shell; /bin/sleep 300 & echo $! > %s/child; while :; do wait; done' "$2" "$2" "$2"
            ;;
        moved)
            # A child in a process group of its own, as `timeout` makes for itself.
            printf 'echo $$ > %s/shell; set -m; /bin/sleep 300 & echo $! > %s/child; set +m; wait' "$2" "$2"
            ;;
    esac
}

SESSION=""
start_session() {
    # start_session <case dir> <guest kind> [vm.sh subcommand]
    local dir="$1" kind="$2" sub="${3:-run}" command
    mkdir -p "$dir"
    command="$(guest_command "$kind" "$dir")"
    set -m
    "$VM" session "$BASH" -c '"$1" "$2" "$3"' flth-session "$VM" "$sub" "$command" > "$dir/log" 2>&1 &
    SESSION=$!
    set +m
    if wait_for_file "$dir/shell" && wait_for_file "$dir/child"; then
        ok "$(basename "$dir"): the guest command started"
    else
        bad "$(basename "$dir"): the guest command never started: $(cat "$dir/log")"
    fi
    cat "$dir/shell" "$dir/child" >> "$LEFT" 2>/dev/null
}

check_stopped() {
    # check_stopped <case dir>
    local label name
    label="$(basename "$1")"
    for name in shell child; do
        if ended_within_limit "$(cat "$1/$name" 2>/dev/null)"; then
            ok "$label: the guest command's $name has ended"
        else
            bad "$label: the guest command's $name is still running"
        fi
    done
}

check_running() {
    # check_running <case dir> <why>
    local name
    for name in shell child; do
        if alive "$(cat "$1/$name" 2>/dev/null)"; then
            ok "$2: its $name is still running"
        else
            bad "$2: its $name has ended"
        fi
    done
}

# TERM to the session's process, with FLTH_KEEP_VM=1, beside another session.
export FLTH_KEEP_VM=1
kept="$SANDBOX/kept"
other="$SANDBOX/other"
start_session "$kept" plain
kept_session=$SESSION
start_session "$other" plain
other_session=$SESSION
kill -TERM "$kept_session"
wait "$kept_session"
check_eq "$?" 143 "FLTH_KEEP_VM=1: the session exits 143"
check_stopped "$kept"
check_running "$other" "the other session's command"
if alive "$(cat "$QEMU_PID")"; then ok "FLTH_KEEP_VM=1: the VM stays up"; else bad "FLTH_KEEP_VM=1: the VM stopped"; fi

# TERM to the other session's group, through `exec`, which guest-test uses.
kill -TERM -- "-$other_session"
wait "$other_session"
check_eq "$?" 143 "another live session: a signal to its group exits 143"
check_stopped "$other"

group="$SANDBOX/group-exec"
start_session "$group" plain exec
kill -TERM -- "-$SESSION"
wait "$SESSION"
check_eq "$?" 143 "exec: the session exits 143"
check_stopped "$group"

# A command that ignores TERM.
stubborn="$SANDBOX/stubborn"
start_session "$stubborn" stubborn
kill -TERM -- "-$SESSION"
wait "$SESSION"
check_stopped "$stubborn"
check_eq "$(cat "$stubborn/term" 2>/dev/null)" TERM "stubborn: the command was asked first, with TERM"

# A child that moved to a process group of its own.
moved="$SANDBOX/moved"
start_session "$moved" moved
kill -TERM "$SESSION"
wait "$SESSION"
check_stopped "$moved"

# A held VM, with no FLTH_KEEP_VM: the session's end leaves it up.
unset FLTH_KEEP_VM
"$VM" hold > /dev/null 2>&1
held="$SANDBOX/held"
start_session "$held" plain
kill -TERM "$SESSION"
wait "$SESSION"
check_eq "$?" 143 "held: the session exits 143"
check_stopped "$held"
if alive "$(cat "$QEMU_PID")"; then ok "held: the VM stays up"; else bad "held: the VM stopped"; fi
rm -f "$machine/keep-running" "$GUEST/held"
export FLTH_KEEP_VM=1

# KILL to the host side, which no trap on the host can answer: what a session
# sends to its command's group when TERM did not end it. A group of its own, so
# that the signal reaches this call and nothing of the test.
killed="$SANDBOX/killed"
mkdir -p "$killed"
set -m
"$VM" run "$(guest_command plain "$killed")" > "$killed/log" 2>&1 &
killed_call=$!
set +m
if wait_for_file "$killed/shell" && wait_for_file "$killed/child"; then
    ok "killed: the guest command started"
else
    bad "killed: the guest command never started: $(cat "$killed/log")"
fi
cat "$killed/shell" "$killed/child" >> "$LEFT" 2>/dev/null
kill -KILL -- "-$killed_call"
wait "$killed_call" 2>/dev/null
check_stopped "$killed"

# TERM to `vm.sh run` and nothing else: ssh is left alive, and sees the host side go.
direct="$SANDBOX/direct"
mkdir -p "$direct"
"$VM" run "$(guest_command plain "$direct")" > "$direct/log" 2>&1 &
direct_call=$!
if wait_for_file "$direct/shell" && wait_for_file "$direct/child"; then
    ok "direct: the guest command started"
else
    bad "direct: the guest command never started: $(cat "$direct/log")"
fi
cat "$direct/shell" "$direct/child" >> "$LEFT" 2>/dev/null
kill -TERM "$direct_call"
wait "$direct_call" 2>/dev/null
check_stopped "$direct"

# A call that ends on its own.
ended="$SANDBOX/ended"
mkdir -p "$ended"
"$VM" run "echo out; echo err >&2; cat; echo stdin-read; exit 7" > "$ended/out" 2> "$ended/err"
check_eq "$?" 7 "a call that ends keeps its status"
check_eq "$(cat "$ended/out")" $'out\nstdin-read' "and its stdout, with an empty stdin"
check_eq "$(cat "$ended/err")" err "and its stderr, with nothing of the machinery"

"$VM" run "/bin/sleep 300 > /dev/null 2>&1 < /dev/null & echo \$! > $ended/daemon" > "$ended/daemon.log" 2>&1
check_eq "$?" 0 "a call that starts something in the background ends"
cat "$ended/daemon" >> "$LEFT" 2>/dev/null
command -p sleep 1
if alive "$(cat "$ended/daemon" 2>/dev/null)"; then
    ok "and what it started is left running: the call ended, nothing signalled it"
else
    bad "what a finished call started in the background was stopped"
fi

# Many short calls, which is how a test process uses the guest.
n=0
loud=""
while [ "$n" -lt 20 ]; do
    out="$("$VM" exec 'echo fast' 2>&1)" || loud="status $?"
    [ "$out" = fast ] || loud="$loud [$out]"
    n=$((n + 1))
done
check_eq "$loud" "" "twenty short calls each print only what the command printed"

finish guest-command-signal
