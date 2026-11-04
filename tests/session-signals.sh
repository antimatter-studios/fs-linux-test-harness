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
cat > "$SANDBOX/startup.sh" <<'COMMAND'
set() {
    if [ "${0##*/}" = vm-session.sh ] && [ "${1:-}" = -m ] && [ ! -f "$SESSION_TEST_DIR/injected" ]; then
        echo TERM > "$SESSION_TEST_DIR/injected"
        kill -TERM "$$"
    fi
    builtin set "$@"
}
COMMAND

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
    set -m
    (
        sleep 12
        echo timeout > "$run_dir/timeout"
        kill -KILL -- "-$session_pid" 2>/dev/null || true
        [ -z "$command_pid" ] || kill -KILL -- "-$command_pid" "$command_pid" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    local watchdog=$!
    set +m
    local started=$SECONDS
    case "$delivery" in
        process) kill -TERM "$session_pid" 2>/dev/null ;;
        group) kill -TERM -- "-$session_pid" 2>/dev/null ;;
    esac
    wait "$session_pid"
    local status=$? elapsed=$((SECONDS - started))
    kill -KILL -- "-$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    check_eq "$status" 143 "$label: session exits 143"
    check_eq "$(cat "$run_dir/end" 2>/dev/null)" "$session_pid" "$label: session teardown ran"
    if [ ! -f "$run_dir/timeout" ] && [ "$elapsed" -lt 10 ]; then
        ok "$label: termination completes within 10 seconds (5-second escalation)"
    else
        bad "$label: session exceeded its termination bound ($elapsed seconds)"
    fi
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
BASH_ENV="$SANDBOX/startup.sh" "$HARNESS/vm.sh" session "$BASH" -c 'echo ran > "$SESSION_TEST_DIR/ran"' > "$SESSION_TEST_DIR/log" 2>&1
check_eq "$?" 143 "TERM before launch: session exits 143"
check_eq "$(cat "$SESSION_TEST_DIR/injected" 2>/dev/null)" TERM "TERM before launch: signal was injected"
if [ ! -f "$SESSION_TEST_DIR/ran" ]; then
    ok "TERM before launch: command never starts"
else
    bad "TERM before launch: command ran despite cancellation"
fi
check_eq "$(cat "$SESSION_TEST_DIR/end" 2>/dev/null)" "$(cat "$SESSION_TEST_DIR/begin" 2>/dev/null)" \
    "TERM before launch: teardown ends the recorded session"

finish session-signals
