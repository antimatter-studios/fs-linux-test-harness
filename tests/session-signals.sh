#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

HARNESS="$SANDBOX/harness/scripts"
mkdir -p "$HARNESS/lib"
cp "$REPO/scripts/vm-session.sh" "$HARNESS/"
cp "$REPO/scripts/lib/config.sh" "$HARNESS/lib/"
make_consumer "$SANDBOX/consumer" session-signals
export FLTH_CONFIG="$SANDBOX/consumer/fs-linux-test-harness.toml"
export SESSION_TEST_BASH="$BASH"
export SESSION_TEST_DIR="$SANDBOX"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HARNESS/host-tools.sh"
cat > "$HARNESS/vm.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    session) shift; exec "$SESSION_TEST_BASH" "${0%/*}/vm-session.sh" "$@" ;;
    session-begin) echo "$2" > "$SESSION_TEST_DIR/begin" ;;
    session-end) echo "$2" > "$SESSION_TEST_DIR/end" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$HARNESS/host-tools.sh" "$HARNESS/vm.sh"

cat > "$SANDBOX/descendant.sh" <<'COMMAND'
#!/usr/bin/env bash
if [ "$1" = stubborn ]; then
    trap 'echo TERM > "$SESSION_TEST_DIR/term"' TERM
    echo "$$" > "$SESSION_TEST_DIR/descendant"
    while :; do sleep 30 & wait "$!"; done
fi
echo "$$" > "$SESSION_TEST_DIR/descendant"
exec sleep 30
COMMAND
cat > "$SANDBOX/command.sh" <<'COMMAND'
#!/usr/bin/env bash
echo "$$" > "$SESSION_TEST_DIR/command"
"$SESSION_TEST_BASH" "$SESSION_TEST_DIR/descendant.sh" "$1" &
wait "$!"
COMMAND
cat > "$SANDBOX/consumer.sh" <<'COMMAND'
#!/usr/bin/env bash
child=
trap '[ -z "$child" ] || kill -TERM -- "-$child" 2>/dev/null; wait "$child"; exit 143' TERM
set -m
"$SESSION_TEST_BASH" "$SESSION_TEST_DIR/command.sh" normal &
child=$!
set +m
wait "$child"
COMMAND
cat > "$SANDBOX/forever.sh" <<'COMMAND'
#!/usr/bin/env bash
echo "$$" > "$SESSION_TEST_DIR/command"
while :; do sleep 1; done
COMMAND
# Sourced through BASH_ENV by every Bash the session starts, so it acts only in
# vm-session.sh itself, and asks when it acts: Bash 3.2 sets $0 after reading
# BASH_ENV. The statement after the launch is the one place a test can stand:
# the command has been forked and the session does not yet know its PID. A
# statement that no longer matches leaves the "launched" record empty, which the
# replay case below reports. Before the launch, the signal arrives as the session
# checks for one, the last statement before it forks; a statement that no longer
# matches leaves the "injected" record empty, which that case reports.
cat > "$SANDBOX/startup.sh" <<'COMMAND'
session_test_statement() {
    [ "${0##*/}" = vm-session.sh ] || return 0
    if [ "$1" = '[ "$_flth_session_signalled" = 0 ]' ] && [ "${SESSION_TEST_INJECT:-}" = before-launch ] &&
        [ ! -f "$SESSION_TEST_DIR/injected" ]; then
        echo TERM > "$SESSION_TEST_DIR/injected"
        kill -TERM "$$"
        return 0
    fi
    [ "$1" = '_flth_session_child=$!' ] || return 0
    echo "$!" > "$SESSION_TEST_DIR/launched"
    [ "${SESSION_TEST_INJECT:-}" = after-launch ] || return 0
    echo TERM > "$SESSION_TEST_DIR/injected"
    kill -TERM "$$"
    echo "signalled=$_flth_session_signalled child=${_flth_session_child:-none}" > "$SESSION_TEST_DIR/window"
}
trap 'session_test_statement "$BASH_COMMAND"' DEBUG
COMMAND

# How long a session gets to end, in the same units as its escalation. The
# session counts 50 ticks of a liveness check and a 0.1-second sleep before it
# sends KILL, which is five seconds on an idle machine and whatever the machine
# allows on a loaded one, so a limit in seconds fails a session that is on
# schedule. The watchdog counts its ticks at the same time, each costing at least
# what one of the session's does, so a slow machine slows both.
# A session that does not end reaches this limit on any machine.
# Measured on arm64 macOS at load 420, Bash 3.2 and 5.3, 40 runs: the stubborn
# cases ended at tick 48 to 50 and every other case by tick 3. With both loops'
# sleeps raised to 0.25 seconds the stubborn cases still ended at tick 49 to 50.
TERMINATION_TICKS=150

# start_watchdog <run dir> <session pid>: sets watchdog. The command's PID is
# read when the limit is reached, from whichever record the case wrote.
start_watchdog() {
    local run_dir="$1" session_pid="$2"
    set -m
    (
        ticks=0
        while [ "$ticks" -lt "$TERMINATION_TICKS" ]; do
            kill -0 -- "-$session_pid" 2>/dev/null
            command -p sleep 0.1
            ticks=$((ticks + 1))
            echo "$ticks" >> "$run_dir/ticks"
        done
        echo timeout > "$run_dir/timeout"
        # The session last: its end wakes the test, which stops this watchdog.
        for record in command launched; do
            pid="$(cat "$run_dir/$record" 2>/dev/null)"
            [ -z "$pid" ] || kill -KILL -- "-$pid" "$pid" 2>/dev/null || true
        done
        kill -KILL -- "-$session_pid" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    watchdog=$!
    set +m
}

stop_watchdog() {
    kill -KILL -- "-$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
}

check_ended_in_bound() {
    # check_ended_in_bound <run dir> <label> <elapsed seconds>
    if [ ! -f "$1/timeout" ]; then
        local ticks
        ticks="$(tail -n 1 "$1/ticks" 2>/dev/null)"
        ok "$2: session ended at tick ${ticks:-0} of $TERMINATION_TICKS ($3 seconds)"
    else
        bad "$2: session did not end within $TERMINATION_TICKS ticks ($3 seconds)"
    fi
}

alive() {
    local state
    state="$(ps -o stat= -p "$1" 2>/dev/null)"
    case "$state" in '' | *Z*) return 1 ;; esac
    return 0
}

signal_case() {
    local delivery="$1" mode="$2" command="$3" label="$1/$2/$3"
    local run_dir="$SANDBOX/$delivery-$mode-$command"
    mkdir -p "$run_dir"
    export SESSION_TEST_DIR="$run_dir"
    cp "$SANDBOX/command.sh" "$SANDBOX/descendant.sh" "$run_dir/"
    set -m
    "$HARNESS/vm.sh" session "$BASH" "$SANDBOX/$command.sh" "$mode" > "$run_dir/log" 2>&1 &
    local session_pid=$!
    set +m
    local tries=0 descendant_pid='' command_pid=''
    until [ -s "$run_dir/descendant" ] || ! alive "$session_pid" || [ "$tries" -ge 200 ]; do
        sleep 0.05
        tries=$((tries + 1))
    done
    descendant_pid="$(cat "$run_dir/descendant" 2>/dev/null)"
    command_pid="$(cat "$run_dir/command" 2>/dev/null)"
    if [ -n "$descendant_pid" ]; then
        ok "$label: descendant started"
    else
        bad "$label: descendant never started"
    fi
    local watchdog
    start_watchdog "$run_dir" "$session_pid"
    local started=$SECONDS
    case "$delivery" in
        process) kill -TERM "$session_pid" 2>/dev/null ;;
        group) kill -TERM -- "-$session_pid" 2>/dev/null ;;
    esac
    wait "$session_pid"
    local status=$? elapsed=$((SECONDS - started))
    stop_watchdog
    check_eq "$status" 143 "$label: session exits 143"
    check_eq "$(cat "$run_dir/end" 2>/dev/null)" "$session_pid" "$label: session teardown ran"
    check_ended_in_bound "$run_dir" "$label" "$elapsed"
    if [ -n "$descendant_pid" ] && ! alive "$descendant_pid"; then
        ok "$label: no live descendant when the session exits"
    else
        bad "$label: descendant survived the session (pid=$descendant_pid)"
    fi
    if [ "$mode" = stubborn ]; then
        check_eq "$(cat "$run_dir/term" 2>/dev/null)" TERM "$label: descendant received TERM before escalation"
    fi
    [ -z "$command_pid" ] || kill -KILL -- "-$command_pid" "$command_pid" 2>/dev/null || true
    [ -z "$descendant_pid" ] || kill -KILL "$descendant_pid" 2>/dev/null || true
}

signal_case process normal command
signal_case group normal command
signal_case process stubborn command
signal_case group stubborn command
signal_case process normal consumer
signal_case group normal consumer

export SESSION_TEST_DIR="$SANDBOX/startup"
mkdir -p "$SESSION_TEST_DIR"
SESSION_TEST_INJECT=before-launch BASH_ENV="$SANDBOX/startup.sh" "$HARNESS/vm.sh" session "$BASH" -c 'echo ran > "$SESSION_TEST_DIR/ran"' > "$SESSION_TEST_DIR/log" 2>&1
check_eq "$?" 143 "TERM before launch: session exits 143"
check_eq "$(cat "$SESSION_TEST_DIR/injected" 2>/dev/null)" TERM "TERM before launch: signal was injected"
if [ ! -f "$SESSION_TEST_DIR/ran" ]; then
    ok "TERM before launch: command never starts"
else
    bad "TERM before launch: command ran despite cancellation"
fi
# The check above loses a race whenever the replay stops the command before it
# writes its marker. This record is written by the session itself, before the
# replay can run, so it does not depend on who wins.
if [ ! -f "$SESSION_TEST_DIR/launched" ]; then
    ok "TERM before launch: session never launches the command"
else
    bad "TERM before launch: session launched the command despite cancellation"
fi
check_eq "$(cat "$SESSION_TEST_DIR/end" 2>/dev/null)" "$(cat "$SESSION_TEST_DIR/begin" 2>/dev/null)" \
    "TERM before launch: teardown ends the recorded session"

export SESSION_TEST_DIR="$SANDBOX/replay"
mkdir -p "$SESSION_TEST_DIR"
set -m
SESSION_TEST_INJECT=after-launch BASH_ENV="$SANDBOX/startup.sh" "$HARNESS/vm.sh" session "$BASH" "$SANDBOX/forever.sh" > "$SESSION_TEST_DIR/log" 2>&1 &
replay_session=$!
set +m
start_watchdog "$SESSION_TEST_DIR" "$replay_session"
replay_started=$SECONDS
wait "$replay_session"
replay_status=$?
replay_elapsed=$((SECONDS - replay_started))
stop_watchdog
check_eq "$replay_status" 143 "TERM after launch: session exits 143"
check_eq "$(cat "$SESSION_TEST_DIR/injected" 2>/dev/null)" TERM "TERM after launch: signal was injected"
# The handler has run and the PID is still unknown: anything else means the
# signal did not land in the window this case exists for.
check_eq "$(cat "$SESSION_TEST_DIR/window" 2>/dev/null)" "signalled=143 child=none" \
    "TERM after launch: signal arrives before the command's PID is known"
check_ended_in_bound "$SESSION_TEST_DIR" "TERM after launch" "$replay_elapsed"
replay_child="$(cat "$SESSION_TEST_DIR/launched" 2>/dev/null)"
if [ -n "$replay_child" ] && ! kill -0 -- "-$replay_child" 2>/dev/null; then
    ok "TERM after launch: command's process group is gone"
else
    bad "TERM after launch: command's process group survived (pid=$replay_child)"
    [ -z "$replay_child" ] || kill -KILL -- "-$replay_child" 2>/dev/null || true
fi
check_eq "$(cat "$SESSION_TEST_DIR/end" 2>/dev/null)" "$(cat "$SESSION_TEST_DIR/begin" 2>/dev/null)" \
    "TERM after launch: teardown ends the recorded session"

finish session-signals
