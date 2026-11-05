#!/usr/bin/env bash
#
# vm-watchdog.sh — one watchdog on the host for a running guest (#190). vm.sh starts
# it with the guest, in a session of its own, and it ends when the guest does.
#
# The guest's own deadline powers off a guest with nothing asking anything of it, and
# it covers neither a guest that is busy and stuck nor one that has stopped answering.
# SIGKILL cannot clear a process in uninterruptible sleep, and only a reboot can.
#
# Every FLTH_WATCHDOG_INTERVAL seconds it asks the guest for vagrant/guest/watchdog-probe.sh.
# It writes what it sees to watchdog.log in the machine directory, and the last of it
# to watchdog.last, which `vm.sh status` shows.
#
# - A warning names the process, and its suite, and stops nothing. So does what the
#   kernel says on the console: an oops, a soft lockup, a hung task, an RCU stall, a
#   panic, and a change in its taint.
# - A guest that has not answered for FLTH_WATCHDOG_SILENT_SECS, or a process stuck for
#   FLTH_WATCHDOG_STUCK_SECS, ends the guest, whoever is using it: a stuck kernel
#   affects them all. A held guest belongs to the person holding it, so there it only
#   says what it would have done.
#
# STUCK IS NOT THE SAME AS SLEEPING. A process doing heavy I/O is in uninterruptible
# sleep at nearly every look, for hours. So a process counts as stuck only while
# neither its time on the CPU nor its bytes read and written have moved between looks.
#
# SEVERAL MISSED ANSWERS ARE NEEDED. A loaded host can take longer than one check's
# bound, and a host that was asleep has a long silence and no missed checks.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"
flth_load || exit 1
engine_prepare

INTERVAL="${FLTH_WATCHDOG_INTERVAL:-60}"
WARN_SECS="${FLTH_WATCHDOG_WARN_SECS:-300}"
STUCK_SECS="${FLTH_WATCHDOG_STUCK_SECS:-1800}"
SILENT_SECS="${FLTH_WATCHDOG_SILENT_SECS:-600}"
LOW_PERCENT="${FLTH_WATCHDOG_LOW_PERCENT:-5}"
MISSED_NEEDED=3

LOG="$FLTH_MACHINE_DIR/watchdog.log"
LAST="$FLTH_MACHINE_DIR/watchdog.last"
SEEN="$FLTH_MACHINE_DIR/watchdog.seen"

say() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
    printf '%s\n' "$line" >> "$LOG"
    printf '%s\n' "$line" > "$LAST"
}

# Which suite a run belongs to, from the session markers.
suite_of() {
    local run="$1" marker
    if [ "$run" = - ]; then
        if flth_shared; then echo "no suite: it is outside every run"; else echo "$CFG_project_name"; fi
        return 0
    fi
    for marker in "$FLTH_MACHINE_DIR"/sessions/*; do
        [ -f "$marker" ] || continue
        if [ "$(cut -f4 "$marker" 2>/dev/null)" = "$run" ]; then
            cut -f3 "$marker"
            return 0
        fi
    done
    echo "run $run"
}

end_guest() {
    if [ -f "$FLTH_HOLD" ]; then
        say "held: would have ended the guest: $1"
        return 0
    fi
    say "ending the guest: $1"
    "$SELF_DIR/vm.sh" watchdog-end "$1" >> "$LOG" 2>&1
    exit 0
}

# What the report says of uninterruptible sleep, against the last look: a task keeps
# when it was first seen for as long as what it has done has not moved.
look_at_stuck() {
    local report="$1" now="$2" next pid start token run name since age key
    next="$SEEN.next"
    : > "$next"
    while read -r kind pid start token run name; do
        [ "$kind" = d ] || continue
        key="$pid:$start"
        since="$(awk -v key="$key" -v token="$token" '$1 == key && $2 == token { print $3; exit }' "$SEEN" 2>/dev/null)"
        [ -n "$since" ] || since="$now"
        printf '%s %s %s\n' "$key" "$token" "$since" >> "$next"
        age=$((now - since))
        if [ "$age" -ge "$STUCK_SECS" ]; then
            end_guest "process $pid ($name), held by $(suite_of "$run"), stuck for ${age}s"
        elif [ "$age" -ge "$WARN_SECS" ]; then
            say "warning: process $pid ($name), held by $(suite_of "$run"), has made no progress for ${age}s"
        fi
    done <<< "$report"
    mv "$next" "$SEEN"
}

# WHAT THE KERNEL SAYS ON ITS CONSOLE (#196). A kernel that has oopsed can keep
# answering, so its suites go on and report what follows as their own result. The
# console log is on the host, so this needs nothing of the guest. Each event is warned
# of once: what has been read is remembered by its length, and a log shorter than that
# is a new boot's. Only whole lines are read, so a line still being written waits.
console_seen=0
look_at_console() {
    local file size chunk
    file="$(engine_console_log)"
    [ -f "$file" ] || return 0
    size="$(wc -c < "$file" | tr -d ' ')"
    [ "$size" -ge "$console_seen" ] || console_seen=0
    [ "$size" -gt "$console_seen" ] || return 0
    # The x keeps the last newline, which a substitution would strip.
    chunk="$(tail -c +"$((console_seen + 1))" "$file" | head -c "$((size - console_seen))"; echo x)"
    chunk="${chunk%x}"
    case "$chunk" in *$'\n'*) ;; *) return 0 ;; esac
    chunk="${chunk%$'\n'*}"$'\n'
    console_seen=$((console_seen + $(printf '%s' "$chunk" | wc -c)))
    printf '%s\n' "$chunk" | LC_ALL=C awk '
        function tail_of(s, from) { return substr(s, index(s, from)) }
        oops != "" && /Comm: / {
            proc = $0; sub(/.*PID: */, "", proc); pid = proc; sub(/ .*/, "", pid)
            name = proc; sub(/.*Comm: */, "", name); sub(/ .*/, "", name)
            print "warning: the kernel oopsed: " oops ", in process " pid " (" name ")"; oops = ""; next
        }
        /Oops: .*\[#[0-9]+\]/ { if (oops != "") print "warning: the kernel oopsed: " oops; oops = tail_of($0, "Oops: "); next }
        /BUG: soft lockup/ { print "warning: a soft lockup: " tail_of($0, "BUG: soft lockup - ") }
        /Kernel panic - not syncing/ { print "warning: the kernel panicked: " tail_of($0, "Kernel panic") }
        /INFO: task .* blocked for more than/ { print "warning: a hung task: " tail_of($0, "task ") }
        /rcu: INFO: .*detected stall/ { print "warning: an RCU stall: " tail_of($0, "rcu: ") }
        END { if (oops != "") print "warning: the kernel oopsed: " oops }' |
        while IFS= read -r line; do say "$line"; done
}

# The kernel's own record of what has gone wrong, warned of when it changes. Only the
# letters that mean something failed: an out-of-tree or unsigned module is no fault.
taint_seen=0
look_at_taint() {
    local value="$1" letters=""
    case "$value" in '' | *[!0-9]*) return 0 ;; esac
    [ "$value" != "$taint_seen" ] || return 0
    taint_seen="$value"
    [ $((value & 16)) = 0 ] || letters="$letters, M: a machine check"
    [ $((value & 32)) = 0 ] || letters="$letters, B: a bad page"
    [ $((value & 128)) = 0 ] || letters="$letters, D: it oopsed or hit a BUG"
    [ $((value & 512)) = 0 ] || letters="$letters, W: it warned"
    [ $((value & 16384)) = 0 ] || letters="$letters, L: a soft lockup"
    [ -z "$letters" ] || say "warning: the kernel is tainted, $value: ${letters#, }"
}

low() {
    # low <what> <available> <total>
    [ "${3:-0}" -gt 0 ] || return 0
    if [ "$(($2 * 100 / $3))" -lt "$LOW_PERCENT" ]; then
        say "warning: $1 is low: $(($2 / 1024)) MiB of $(($3 / 1024)) MiB left"
    fi
}

rm -f "$SEEN"
: > "$LOG"
: > "$LAST"
last_answer="$(date +%s)"
missed=0
while :; do
    # Real time: a test's stub on PATH must not make this spin.
    command -p sleep "$INTERVAL"
    alive=0
    engine_alive "$(engine_identity)" || alive=$?
    [ "$alive" -ne 1 ] || break
    [ "$alive" -eq 0 ] || continue
    now="$(date +%s)"
    warned_before="$(wc -l < "$LOG")"
    look_at_console
    if ! report="$(engine_guest_report)"; then
        missed=$((missed + 1))
        silent=$((now - last_answer))
        say "warning: the guest did not answer: ${silent}s since it last did"
        if [ "$missed" -ge "$MISSED_NEEDED" ] && [ "$silent" -ge "$SILENT_SECS" ]; then
            end_guest "the guest did not answer for ${silent}s"
        fi
        continue
    fi
    last_answer="$now"
    missed=0
    look_at_stuck "$report" "$now"
    while read -r kind available total _; do
        case "$kind" in
            mem) low memory "$available" "$total" ;;
            disk) low disk "$available" "$total" ;;
            tainted) look_at_taint "$available" ;;
        esac
    done <<< "$report"
    if [ "$(wc -l < "$LOG")" = "$warned_before" ]; then
        say "ok: the guest answers"
    fi
done
exit 0
