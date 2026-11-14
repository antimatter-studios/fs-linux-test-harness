#!/usr/bin/env bash
# A stale-lock observation must not let two live callers claim one machine.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
mkdir -p "$SANDBOX/harness"
cp -R "$REPO/scripts" "$SANDBOX/harness/"
sed '/^command="${1:-}"/,$d' "$REPO/scripts/vm.sh" > "$SANDBOX/harness/scripts/lock-functions.sh"
export LOCK_FUNCTIONS="$SANDBOX/harness/scripts/lock-functions.sh"
export FLTH_MACHINE_DIR="$SANDBOX/machine"
export LOCK_CASE="$SANDBOX/race"
mkdir -p "$FLTH_MACHINE_DIR/up.lock" "$LOCK_CASE"
( exit 0 ) &
dead_pid=$!
wait "$dead_pid"
printf '%s\n' "$dead_pid" > "$FLTH_MACHINE_DIR/up.lock/pid"

# Pause one contender after it reads the dead owner, before it can act on that
# observation. The other contender then attempts the same real directory lock.
# No engine or VM runs: the host's mkdir, process table and FIFO are the oracles.
cat > "$SANDBOX/contender.sh" <<'WORKER'
#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$LOCK_FUNCTIONS"
cat() {
    if [ "$1" = "$FLTH_MACHINE_DIR/up.lock/pid" ] && [ "$LOCK_PAUSE" = yes ]; then
        command cat "$@" > "$LOCK_CASE/snapshot"
        : > "$LOCK_CASE/read"
        n=0
        while [ ! -e "$LOCK_CASE/resume" ] && [ "$n" -lt 400 ]; do
            command -p sleep 0.05
            n=$((n + 1))
        done
        command cat "$LOCK_CASE/snapshot"
    else
        command cat "$@"
    fi
}
rc=0
up_lock_try || rc=$?
if [ "$rc" = 0 ]; then
    mkfifo "$FLTH_MACHINE_DIR/up.lock/owner" || rc=$?
fi
printf '%s\n' "$rc" > "$LOCK_CASE/$LOCK_NAME.status"
n=0
while [ ! -e "$LOCK_CASE/finish" ] && [ "$n" -lt 400 ]; do
    command -p sleep 0.05
    n=$((n + 1))
done
[ "$UP_LOCK_HELD" = 0 ] || up_lock_drop
WORKER
wait_for_file() {
    local n=0
    while [ ! -e "$1" ] && [ "$n" -lt 200 ]; do
        command -p sleep 0.05
        n=$((n + 1))
    done
    [ -e "$1" ]
}
LOCK_PAUSE=yes LOCK_NAME=first bash "$SANDBOX/contender.sh" > "$LOCK_CASE/first.log" 2>&1 &
first=$!
if wait_for_file "$LOCK_CASE/read"; then
    ok 'a contender has observed the dead owner before reclaiming'
else
    bad "the stale-owner read did not happen ($(cat "$LOCK_CASE/first.log"))"
fi
LOCK_PAUSE=no LOCK_NAME=second bash "$SANDBOX/contender.sh" > "$LOCK_CASE/second.log" 2>&1 &
second=$!
wait_for_file "$LOCK_CASE/second.status" || bad 'the competing lock attempt did not finish'
: > "$LOCK_CASE/resume"
wait_for_file "$LOCK_CASE/first.status" || bad 'the first lock attempt did not finish'
first_status="$(cat "$LOCK_CASE/first.status" 2>/dev/null)"
second_status="$(cat "$LOCK_CASE/second.status" 2>/dev/null)"
case "$first_status|$second_status" in
    '0|1' | '1|0') ok 'exactly one contender owns the reclaimed lock' ;;
    *) bad "both contenders can own the reclaimed lock ($first_status|$second_status)" ;;
esac
holder="$first"
[ "$first_status" = 0 ] || holder="$second"
check_eq "$(cat "$FLTH_MACHINE_DIR/up.lock/pid" 2>/dev/null)" "$holder" \
    'the recorded owner is the live contender that acquired the lock'
check_eq "$([ -p "$FLTH_MACHINE_DIR/up.lock/owner" ] && echo fifo)" fifo \
    'the lock owner can create the boot FIFO'
: > "$LOCK_CASE/finish"
wait "$first" || bad "the first contender failed ($(cat "$LOCK_CASE/first.log"))"
wait "$second" || bad "the second contender failed ($(cat "$LOCK_CASE/second.log"))"
check_eq "$([ -d "$FLTH_MACHINE_DIR/up.lock" ] && echo held || echo free)" free \
    'the holder releases its directory lock'
finish up-lock-race
