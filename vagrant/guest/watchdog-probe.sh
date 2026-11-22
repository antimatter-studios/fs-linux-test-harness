#!/usr/bin/env bash
#
# watchdog-probe.sh — what the host's watchdog asks a guest, sent over ssh with a
# bound on the host's side. One line each:
#
#   mem <kB available> <kB in all>
#   disk <kB available> <kB in all>
#   tainted <the kernel's taint, a bit field>
#   d <pid> <start> <cpu ticks>:<bytes read and written> <run or -> <name>
#   f <tid> <start> <cpu ticks>:<bytes read and written>:<times run> <run or -> <name>
#   t <run> <requests its virtiofsd has not finished, or ?>
#
# An `f` is a thread waiting on a FUSE reply, which on this guest is a run's virtiofsd
# (#289), in either state: the wait can be interruptible. Threads, not processes,
# because a test harness's worker thread makes the call while its main thread waits on
# it. A thread making call after call is in that wait at nearly every look, so how many
# times it has run (schedstat) is part of what it has done: a wait that is never
# answered moves none of it. A FUSE filesystem a suite runs in the guest waits in the
# same place, so a `t` says what each run's own virtiofs connection has outstanding,
# from the kernel's FUSE control filesystem: the connection is named for the mount's
# device. A `?` is a count that could not be read.
#
# It reads nothing that a task in uninterruptible sleep can block on: /proc/<pid>/stat
# and /io need no hold on the task's memory, and its command line and environment do,
# so asking about a stuck task would get this stuck beside it. Which run a task is in
# comes from its mount namespace, for the same reason.
set -uo pipefail

PROC="${FLTH_WATCHDOG_PROC:-/proc}"
RUNS="${FLTH_GUEST_RUNS:-/run/fs-linux-test-harness-runs}"
FUSECTL="${FLTH_WATCHDOG_FUSECTL:-/sys/fs/fuse/connections}"

awk '/^MemTotal:/ { total = $2 } /^MemAvailable:/ { available = $2 }
    END { print "mem", available + 0, total + 0 }' "$PROC/meminfo"
df -Pk / | awk 'NR == 2 { print "disk", $4, $2 }'
{ read -r taint < "$PROC/sys/kernel/tainted" && echo "tainted $taint"; } 2>/dev/null || true

run_of() {
    local namespace file
    namespace="$(readlink "$PROC/$1/ns/mnt" 2>/dev/null)" || { echo -; return; }
    for file in "$RUNS"/ns/*; do
        [ -e "$file" ] || continue
        case "$file" in *.inode) continue ;; esac
        if [ "mnt:[$(stat -L -c %i "$file" 2>/dev/null)]" = "$namespace" ] ||
            [ "$(stat -L -c 'mnt:[%i]' "$file" 2>/dev/null)" = "$namespace" ]; then
            basename "$file"
            return
        fi
    done
    echo -
}

for stat in "$PROC"/[0-9]*/stat; do
    line=""
    { IFS= read -r line < "$stat"; } 2>/dev/null || continue
    [ -n "$line" ] || continue
    pid="${stat%/stat}"
    pid="${pid##*/}"
    # The name can hold spaces and brackets, and it ends at the last bracket.
    name="${line#*(}"
    name="${name%)*}"
    read -r -a fields <<< "${line##*) }"
    [ "${fields[0]:-}" = D ] || continue
    read_bytes=0
    write_bytes=0
    {
        while read -r key value; do
            case "$key" in
                rchar:) read_bytes="$value" ;;
                wchar:) write_bytes="$value" ;;
            esac
        done < "$PROC/$pid/io"
    } 2>/dev/null
    printf 'd %s %s %s:%s %s %s\n' "$pid" "${fields[19]:-0}" \
        "$((${fields[11]:-0} + ${fields[12]:-0}))" "$((read_bytes + write_bytes))" \
        "$(run_of "$pid")" "$name"
done

# Where a sleeping thread waits, by the kernel's own name for it: request_wait_answer,
# or the fuse_ function it is inlined into. A FUSE server waiting for its next request
# (fuse_dev_do_read) is idle, not waiting on a reply.
for wchan_file in "$PROC"/[0-9]*/task/[0-9]*/wchan; do
    wchan=""
    { IFS= read -r wchan < "$wchan_file"; } 2>/dev/null || true
    case "$wchan" in
        fuse_dev_*) continue ;;
        request_wait_answer | *fuse_*) ;;
        *) continue ;;
    esac
    task="${wchan_file%/wchan}"
    tid="${task##*/}"
    pid="${task%/task/*}"
    pid="${pid##*/}"
    line=""
    { IFS= read -r line < "$task/stat"; } 2>/dev/null || continue
    [ -n "$line" ] || continue
    name="${line#*(}"
    name="${name%)*}"
    read -r -a fields <<< "${line##*) }"
    read_bytes=0
    write_bytes=0
    {
        while read -r key value; do
            case "$key" in
                rchar:) read_bytes="$value" ;;
                wchar:) write_bytes="$value" ;;
            esac
        done < "$task/io"
    } 2>/dev/null
    slices=0
    { read -r _ _ slices < "$task/schedstat"; } 2>/dev/null || slices=0
    printf 'f %s %s %s:%s:%s %s %s\n' "$tid" "${fields[19]:-0}" \
        "$((${fields[11]:-0} + ${fields[12]:-0}))" "$((read_bytes + write_bytes))" "${slices:-0}" \
        "$(run_of "$pid")" "$name"
done

# Each run's own connection, found by the device of the virtiofs mount tagged with its
# id, in its namespace. findmnt reads the mount table and touches no mount.
if [ -d "$FUSECTL" ] && [ -z "$(ls -A "$FUSECTL" 2>/dev/null)" ]; then
    mount -t fusectl fusectl "$FUSECTL" 2>/dev/null || true
fi
for file in "$RUNS"/ns/*; do
    [ -e "$file" ] || continue
    case "$file" in *.inode) continue ;; esac
    run="${file##*/}"
    device="$(nsenter --mount="$file" -- findmnt -rn -t virtiofs -o MAJ:MIN,SOURCE 2>/dev/null |
        awk -v run="$run" '$2 == run { print $1; exit }')"
    [ -n "$device" ] || continue
    waiting="?"
    if [ "${device%%:*}" = 0 ]; then
        { read -r waiting < "$FUSECTL/${device#*:}/waiting"; } 2>/dev/null || waiting="?"
    fi
    case "$waiting" in '' | *[!0-9]*) waiting="?" ;; esac
    printf 't %s %s\n' "$run" "$waiting"
done
