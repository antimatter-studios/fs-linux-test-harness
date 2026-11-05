#!/usr/bin/env bash
#
# watchdog-probe.sh — what the host's watchdog asks a guest, sent over ssh with a
# bound on the host's side. One line each:
#
#   mem <kB available> <kB in all>
#   disk <kB available> <kB in all>
#   tainted <the kernel's taint, a bit field>
#   d <pid> <start> <cpu ticks>:<bytes read and written> <run or -> <name>
#
# It reads nothing that a task in uninterruptible sleep can block on: /proc/<pid>/stat
# and /io need no hold on the task's memory, and its command line and environment do,
# so asking about a stuck task would get this stuck beside it. Which run a task is in
# comes from its mount namespace, for the same reason.
set -uo pipefail

PROC="${FLTH_WATCHDOG_PROC:-/proc}"
RUNS="${FLTH_GUEST_RUNS:-/run/fs-linux-test-harness-runs}"

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
