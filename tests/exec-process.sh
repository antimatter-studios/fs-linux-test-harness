#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

export PROCESS_STUB="$SANDBOX/process"
mkdir -p "$PROCESS_STUB/bin"
cat > "$PROCESS_STUB/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROCESS_STUB/pgrep-log"
cat "$PROCESS_STUB/pids"
exit "$(cat "$PROCESS_STUB/pgrep-status")"
STUB
cat > "$PROCESS_STUB/bin/ps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROCESS_STUB/ps-log"
cat "$PROCESS_STUB/args"
exit "$(cat "$PROCESS_STUB/ps-status")"
STUB
chmod +x "$PROCESS_STUB/bin/pgrep" "$PROCESS_STUB/bin/ps"
export PATH="$PROCESS_STUB/bin:$PATH"
. "$REPO/scripts/lib/common.sh"

identity="$SANDBOX/machine.with[characters]/vagrant"
# Candidates that are there: a ps that cannot read processes that exist is an
# unreadable table, while one whose candidates have all gone is a QEMU that exited
# (#205, tests/engine-vagrant.sh).
/bin/sleep 300 >/dev/null 2>&1 &
first=$!
/bin/sleep 300 >/dev/null 2>&1 &
second=$!
# shellcheck disable=SC2064  # expand now: the pids are fixed
trap "kill -KILL $first $second 2>/dev/null; rm -rf '$SANDBOX'" EXIT
printf '%s\n%s\n' "$first" "$second" > "$PROCESS_STUB/pids"
printf '0\n' > "$PROCESS_STUB/pgrep-status"
printf '0\n' > "$PROCESS_STUB/ps-status"
printf '/opt/bin/qemu-system-aarch64 -drive file=%s/disk.img\n' "$identity" > "$PROCESS_STUB/args"
status=0
engine_alive "$identity" || status=$?
check_eq "$status" 0 "a QEMU candidate naming this machine is alive"
check_eq "$(cat "$PROCESS_STUB/ps-log")" "-p $first,$second -o args=" \
    "the per-call path reads only QEMU candidates, not every process's arguments"
check_eq "$(cat "$PROCESS_STUB/pgrep-log" 2>/dev/null)" '-x qemu-system-.*' \
    "candidate discovery matches executable names, including truncated names"

printf '/opt/bin/qemu-system-aarch64 -drive file=%s-old/disk.img\n' "$identity" > "$PROCESS_STUB/args"
status=0
engine_alive "$identity" || status=$?
check_eq "$status" 1 "a different machine sharing the path prefix is not alive"
printf 'bash -c inspect %s/disk.img\n' "$identity" > "$PROCESS_STUB/args"
status=0
engine_alive "$identity" || status=$?
check_eq "$status" 1 "a command merely mentioning the machine is not QEMU"

printf '1\n' > "$PROCESS_STUB/ps-status"
status=0
engine_alive "$identity" || status=$?
check_eq "$status" 2 "an unreadable candidate stays unknown, never stopped"
printf '0\n' > "$PROCESS_STUB/ps-status"
: > "$PROCESS_STUB/args"
status=0
engine_alive "$identity" || status=$?
check_eq "$status" 2 "an empty candidate result stays unknown"

for discovery_status in 0 1 2 127; do
    : > "$PROCESS_STUB/pids"
    : > "$PROCESS_STUB/ps-log"
    printf '%s\n' "$discovery_status" > "$PROCESS_STUB/pgrep-status"
    printf '/opt/bin/qemu-system-aarch64 -drive file=%s/disk.img\n' "$identity" > "$PROCESS_STUB/args"
    status=0
    engine_alive "$identity" || status=$?
    check_eq "$status" 0 "failed or empty discovery ($discovery_status) falls back to the full table"
    check_eq "$(cat "$PROCESS_STUB/ps-log")" '-eo args=' "fallback ($discovery_status) reads the full table"
done

finish exec-process
