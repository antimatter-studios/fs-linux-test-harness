#!/usr/bin/env bash
#
# vm-slot.sh — bounded test VMs, across every repository.
#
#   vm-slot.sh acquire          wait for the slot, then take it
#   vm-slot.sh release          give it back, if this consumer holds it
#   vm-slot.sh release --force  free it whoever holds it
#   vm-slot.sh renew            before this VM stops and starts again: keep
#                               its slot through the restart
#   vm-slot.sh status           say who holds it and for how long
#
# WHY THIS EXISTS. A test VM asks for gigabytes. Two of them beside a
# compiler can fill a laptop, and a full machine does not fail cleanly: it
# kills background work with no message connecting the two. That is what
# happened when several agents built fixtures in parallel.
#
# The limit is machine-wide, not per repository: one by default, or
# FLTH_SLOT_COUNT for a host with room for more. Every admission checks
# available host memory, reserves other booting guests' allocations and
# leaves 2048 MiB for the host. A full machine refuses by consumer name;
# an occupied limit waits visibly. Neither failure is silent.
#
# THE LOCK is a directory, because `mkdir` is atomic. Inside it, `holder`
# is one line of four tab-separated fields:
#
#   identity  name  epoch  token
#
# `identity` is the machine's engine identity (a path a running VM names
# on its command line), `name` the consumer's [project] name, `epoch`
# when the slot was taken, and `token` this generation's identity.
#
# NOT A PID. `acquire` takes the slot and exits, leaving the VM behind,
# so a recorded PID is dead within milliseconds. What holds the slot is a
# running VM, so that is what liveness is measured against.
#
# A RESTART LOOKS LIKE A DEATH. For a moment during a stop and start in place
# no VM process exists, and the process table cannot say why. Two things keep
# that moment from freeing the slot (#122). A restart the harness knows about
# renews the lease first (`vm.sh reload`, or `renew` before a consumer's own
# `vagrant reload`), which is a fresh boot grace and a new token. A restart it
# cannot see is covered only by time: a holder past its grace is not abandoned
# until its VM has been seen absent, with no gap, for FLTH_SLOT_ABSENT_GRACE.
# One that stays down longer than that still loses its slot, and a rival can
# then boot beside it when it returns. Nothing here can see or stop that VM.
#
# Environment:
#   FLTH_STATE_DIR         where the lock lives (default
#                          ${XDG_STATE_HOME:-~/.local/state}/fs-linux-test-harness)
#   FLTH_SLOT_WAIT         seconds `acquire` waits before giving up (3600)
#   FLTH_SLOT_COUNT        machine-wide concurrent VM limit (1, at most 64)
#   FLTH_SLOT_BOOT_GRACE   seconds a fresh holder is trusted without a
#                          running VM (180)
#   FLTH_SLOT_ABSENT_GRACE seconds a holder past that must be seen with no
#                          running VM before it is abandoned (the boot grace)
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

LOCK="$FLTH_STATE_DIR/slot.lock"
HOLDER="$LOCK/holder"

# Long, because a fixture build legitimately takes tens of minutes.
WAIT_SECS="${FLTH_SLOT_WAIT:-3600}"

# THE SLOT IS TAKEN BEFORE THE VM EXISTS — necessarily, since the point
# is to keep boots within the host's limit. During a boot there is a
# holder with no VM behind it; without a grace period a waiter would see
# nothing running, break the lock, and exceed the configured limit.
# Too long only delays reclaiming a dead lock; too
# short reintroduces the race, so it errs long.
BOOT_GRACE_SECS="${FLTH_SLOT_BOOT_GRACE:-180}"

# As long as a boot by default, because a restart the harness cannot see ends
# in one. Too long only delays reclaiming a dead lock.
ABSENT_GRACE_SECS="${FLTH_SLOT_ABSENT_GRACE:-$BOOT_GRACE_SECS}"

POLL_SECS=5

HOLDER_IDENTITY=""
HOLDER_NAME=""

# Who this process is acquiring or releasing for. Resolved only for the
# commands that need it, so `status` and `release --force` work from
# anywhere.
slot_identify() {
    [ -n "$HOLDER_IDENTITY" ] && return 0
    flth_load || exit 1
    HOLDER_IDENTITY="$(engine_identity)"
    HOLDER_NAME="$CFG_project_name"
}

slot_path() {
    LOCK="$FLTH_STATE_DIR/slot.lock"
    [ "$1" = 1 ] || LOCK="$FLTH_STATE_DIR/slot-$1.lock"
    HOLDER="$LOCK/holder"
}

slot_paths() {
    printf '%s\n' "$FLTH_STATE_DIR/slot.lock"
    local candidate
    for candidate in "$FLTH_STATE_DIR"/slot-[0-9]*.lock; do
        [ -d "$candidate" ] && printf '%s\n' "$candidate"
    done
    return 0
}

slot_count() {
    SLOT_COUNT="${FLTH_SLOT_COUNT:-1}"
    case "$SLOT_COUNT" in
        '' | 0* | *[!0-9]*)
            echo '[vm-slot] FLTH_SLOT_COUNT must be an integer from 1 to 64' >&2
            return 1 ;;
    esac
    if [ "${#SLOT_COUNT}" -gt 2 ] || [ "$SLOT_COUNT" -gt 64 ]; then
        echo '[vm-slot] FLTH_SLOT_COUNT must be an integer from 1 to 64' >&2
        return 1
    fi
}

guest_memory_mib() {
    case "$CFG_vm_memory" in
        *G) echo "$(( ${CFG_vm_memory%G} * 1024 ))" ;;
        *M) echo "${CFG_vm_memory%M}" ;;
    esac
}

host_memory_mib() {
    case "$(uname -s)" in
        Linux)
            awk '/^MemAvailable:/ {print int($2 / 1024); found=1} END {if (!found) exit 1}' /proc/meminfo ;;
        Darwin)
            local stats
            stats="$(vm_stat)" || return 1
            printf '%s\n' "$stats" | awk '
                /page size of/ {for (field=1; field<=NF; field++) if ($field == "bytes)") size=$(field-1)}
                /^Pages (free|inactive|speculative):/ {gsub(/\./, "", $NF); pages+=$NF; found++}
                END {if (!size || found != 3) exit 1; print int(pages * size / 1048576)}' ;;
        *) return 1 ;;
    esac
}

# Status 1 refuses. Status ADMIT_WAIT means the answer is not known yet,
# ADMIT_WAITING_ON names the holder it depends on and ADMIT_WAIT_REASON says why.
#
# A HOLDER WITH NO `memory` FILE IS NOT A MALFORMED ONE. `cmd_acquire` writes
# `memory` before `holder`, so a complete record with no reservation beside it
# comes from a harness before v0.5.5, or from a lock being released as this
# reads it. Consumers move their pins one at a time, so that holder is ordinary
# during a move. Its allocation is unknown and, while it may be booting, is not
# yet in available memory, so the caller waits: the holder settles, stops or
# goes within its grace. A reservation that is present and unreadable is
# refused, since waiting will not repair it.
#
# A HOLDER PAST ITS GRACE WITH NO VM MAY BE RESTARTING. Until its absence has
# settled, its reservation may be needed again or may be gone. It is counted
# only to decide whether to wait: a guest that may not exist is no reason to
# refuse, and memory that covers it as well is no reason to wait.
ADMIT_WAIT=2
ADMIT_WAITING_ON=""
ADMIT_WAIT_REASON=""

memory_admit() {
    local available requested pending=0 unsettled=0 unsettled_name="" candidate snapshot identity since reservation alive
    ADMIT_WAITING_ON=""
    ADMIT_WAIT_REASON=""
    requested="$(guest_memory_mib)"
    available="$(host_memory_mib)" || available=""
    case "$available" in
        '' | *[!0-9]*)
            echo "[vm-slot] $HOLDER_NAME: host free memory could not be measured; refusing to start" >&2
            return 1 ;;
    esac
    while IFS= read -r candidate; do
        [ -d "$candidate" ] || continue
        [ "$candidate" != "$LOCK" ] || continue
        snapshot="$(read_holder "$candidate/holder" 2>/dev/null || true)"
        if [ -z "$snapshot" ]; then
            sleep 1
            snapshot="$(read_holder "$candidate/holder" 2>/dev/null || true)"
        fi
        if [ -z "$snapshot" ]; then
            echo "[vm-slot] $HOLDER_NAME: memory reservation is incomplete at $candidate; refusing to start" >&2
            return 1
        fi
        identity="$(snapshot_field "$snapshot" 1)"
        [ "$identity" != "$HOLDER_IDENTITY" ] || continue
        since="$(snapshot_field "$snapshot" 3)"
        alive=""
        if [ "$(( $(now) - since ))" -gt "$BOOT_GRACE_SECS" ]; then
            alive=0
            engine_alive "$identity" || alive=$?
            case "$alive" in
                0) continue ;;
                1) if absence_settled "$candidate" "$snapshot"; then continue; fi ;;
            esac
        fi
        if [ ! -e "$candidate/memory" ]; then
            # Nothing settled past its grace reaches here, so its allocation
            # is still unknown.
            ADMIT_WAITING_ON="$(snapshot_field "$snapshot" 2)"
            ADMIT_WAIT_REASON='has no memory reservation recorded'
            continue
        fi
        reservation="$(cat "$candidate/memory" 2>/dev/null || true)"
        case "$reservation" in
            '' | *[!0-9]*)
                echo "[vm-slot] $HOLDER_NAME: memory reservation is unknown for $(snapshot_field "$snapshot" 2); refusing to start" >&2
                return 1 ;;
        esac
        if [ "$alive" = 1 ]; then
            unsettled=$((unsettled + reservation))
            unsettled_name="$(snapshot_field "$snapshot" 2)"
            continue
        fi
        pending=$((pending + reservation))
    done < <(slot_paths)
    if [ "$available" -lt "$((requested + pending + 2048))" ]; then
        echo "[vm-slot] $HOLDER_NAME: insufficient host memory: $available MiB available; $requested MiB guest + $pending MiB pending guests + 2048 MiB host reserve; refusing to start" >&2
        return 1
    fi
    if [ "$available" -lt "$((requested + pending + unsettled + 2048))" ]; then
        ADMIT_WAITING_ON="$unsettled_name"
        ADMIT_WAIT_REASON='has no VM running and may be restarting'
    fi
    [ -z "$ADMIT_WAITING_ON" ] || return "$ADMIT_WAIT"
}

now() { date +%s; }

# EVERY NAME THIS FILE INVENTS CARRIES A SERIAL, AND IT IS A COUNTER
# RATHER THAN A DRAW. Generation tokens and staging names must be unique
# per process and per second; `$RANDOM` repeats once in 32768, which is
# two generations given one identity. A counter cannot repeat.
#
# It ASSIGNS rather than prints: `x="$(next_serial)"` would increment in
# a subshell and hand back 1 every time.
SERIAL=0
next_serial() { SERIAL=$((SERIAL + 1)); }

# The holder record, or failure when there is none YET.
#
# A HALF-WRITTEN HOLDER FILE IS NOT A HOLDER RECORD. An empty file is the
# ordinary state of `cmd_acquire` between its `mkdir` and its `printf`.
# Accepting it made the age `now - 0`, made the identity empty (which
# reads as "dead"), and let a waiter break the lock of a process that was
# mid-acquire — both then booted a VM.
#
# Field counting is explicit because `cut -f` on a line with no tab
# returns the whole line for every field: `123` would be a valid record
# naming an identity called `123`.
read_holder() {
    local file="${1:-$HOLDER}" line fields
    [ -f "$file" ] || return 1
    IFS= read -r line < "$file" 2>/dev/null || return 1
    [ -n "$line" ] || return 1
    fields="$(printf '%s\n' "$line" | awk -F'\t' '{print NF}')"
    [ "$fields" = 4 ] || return 1
    [ -n "$(snapshot_field "$line" 1)" ] || return 1
    [ -n "$(snapshot_field "$line" 2)" ] || return 1
    [ -n "$(snapshot_field "$line" 4)" ] || return 1
    case "$(snapshot_field "$line" 3)" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$line"
}

# A field of the live record.
holder_field() { read_holder | awk -F'\t' -v n="$1" '{print $n}'; }

# A field of a record ALREADY READ.
#
# ONE READ PER DECISION. Asking the live file for the age, the identity
# and the token gave three answers about three possibly different
# records, and a decision assembled from them can describe a state that
# never existed.
snapshot_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'; }

# A field of a record that is not at `$HOLDER` — a lock moved aside. The
# `-f` guard matters: `< missing` is a redirection failure bash reports
# itself, past any `2>/dev/null` on the command.
record_field() {
    [ -f "$1" ] || return 0
    awk -F'\t' -v n="$2" '{print $n}' < "$1" 2>/dev/null
}

pretty_age() {
    local secs=$1
    if [ "$secs" -lt 60 ]; then echo "${secs}s"
    elif [ "$secs" -lt 3600 ]; then echo "$((secs / 60))m"
    else echo "$((secs / 3600))h$(((secs % 3600) / 60))m"
    fi
}

# Dead when no VM is running for the identity that took the slot. This is
# what survives a crash: a script killed before its VM came up leaves a
# lock nothing is using, and this frees it.
#
# A process table that could not be read is NOT evidence of death: a
# break on "could not look" robs a live holder.
holder_is_dead() {
    local identity="$1" rc=0
    [ -n "$identity" ] || return 0
    engine_alive "$identity" || rc=$?
    [ "$rc" -eq 1 ]
}

# Status 0 when the VM of the holder in lock $1, snapshot $2, already seen not
# running, has stayed so for the whole window. Every call is an observation.
#
# The record sits in the lock, so every waiter shares it and it goes with the
# generation: token, first seen absent, last seen absent. It starts again on
# another token, since a renewal is a restart somebody knows about, and after a
# gap longer than the window, since an absence nobody watched is not known to be
# one absence. A waiter that retries within the window still gets an answer.
absence_settled() {
    local lock="$1" token at first record seen_first seen_last
    [ "$ABSENT_GRACE_SECS" -gt 0 ] || return 0
    token="$(snapshot_field "$2" 4)"
    at="$(now)"
    first="$at"
    record="$(cat "$lock/absent" 2>/dev/null || true)"
    if [ "$(snapshot_field "$record" 1)" = "$token" ]; then
        seen_first="$(snapshot_field "$record" 2)"
        seen_last="$(snapshot_field "$record" 3)"
        case "$seen_first" in '' | *[!0-9]*) seen_last="" ;; esac
        case "$seen_last" in
            '' | *[!0-9]*) ;;
            *) [ "$((at - seen_last))" -gt "$ABSENT_GRACE_SECS" ] || first="$seen_first" ;;
        esac
    fi
    next_serial
    {
        printf '%s\t%s\t%s\n' "$token" "$first" "$at" > "$lock/absent.$$.$SERIAL" &&
            mv "$lock/absent.$$.$SERIAL" "$lock/absent"
    } 2>/dev/null || true
    [ "$((at - first))" -ge "$ABSENT_GRACE_SECS" ]
}

# Whether the holder in $LOCK, snapshot $1, may be taken from: past its boot
# grace, with no VM running, for long enough to rule out a restart. A VM seen
# running ends any absence on record. This consumer's own holder needs no window:
# it is asking because its own VM is not up, and it has only one machine to boot.
holder_is_abandoned() {
    local snapshot="$1" identity rc=0
    [ "$(( $(now) - $(snapshot_field "$snapshot" 3) ))" -gt "$BOOT_GRACE_SECS" ] || return 1
    identity="$(snapshot_field "$snapshot" 1)"
    engine_alive "$identity" || rc=$?
    case "$rc" in
        0) rm -f "$LOCK/absent"; return 1 ;;
        1) [ "$identity" = "$HOLDER_IDENTITY" ] || absence_settled "$LOCK" "$snapshot" ;;
        *) return 1 ;;
    esac
}

# Return a lock that was moved aside to the live path, or keep it as an
# orphan if the path has been taken meanwhile.
#
# `mkdir` RATHER THAN `mv "$staged" "$LOCK"`: `mv` of a directory onto an
# existing directory does not fail, it moves the source INSIDE — burying
# a generation inside the live holder's lock and reporting success.
restore_lock() {
    local staged="$1" orphan
    if mkdir "$LOCK" 2>/dev/null; then
        mv "$staged/holder" "$HOLDER" 2>/dev/null || true
        if [ -f "$staged/memory" ]; then mv "$staged/memory" "$LOCK/memory"; fi
        rm -rf "$staged"
        return 0
    fi
    # THE PATH IS TAKEN AND THIS RECORD CANNOT GO BACK. It is a
    # generation this process decided it was NOT authorised to delete, so
    # its VM may still be running. Deleting the record would leave two
    # holders and no trace of how; it is kept, and said so.
    next_serial
    orphan="${LOCK}.orphan.$$.$SERIAL"
    rm -rf "$orphan"
    if mv "$staged" "$orphan" 2>/dev/null; then
        echo "[vm-slot] a lock was staged aside and the slot was retaken before it" >&2
        echo "[vm-slot] could be restored; the displaced record is at $orphan" >&2
        echo "[vm-slot] and its VM may still be running -- check before trusting the slot." >&2
    fi
    return 1
}

# Delete the lock if it still holds the generation named, and otherwise
# leave it exactly as found. 0 when deleted, 1 when not.
#
# `$LOCK` IS A FIXED PATH, so `rm -rf "$LOCK"` deletes whatever is there
# NOW — which, after a decision that read a record and ran `ps`, can be a
# different, live lock. Two waiters agreeing one holder is stale then
# produce two VMs: the first breaks and acquires, the second deletes the
# first's lock.
#
# So the token is checked BEFORE the move (moving a lock this process can
# already see is not its own risks it for nothing: the restore is a
# `mkdir` a waiter can win) and AFTER it (the move is atomic, so from
# then on nobody can acquire the thing being examined — this is the
# check that closes the window).
#
# One implementation for break and release: they are the same operation
# from two sides, and taking the token as an argument is what lets a test
# present a stale one.
delete_generation() {
    local token="${1-}" tag="$2" staged
    if [ "$(holder_field 4 2>/dev/null || true)" != "$token" ]; then
        return 1
    fi
    next_serial
    staged="${LOCK}.${tag}.$$.$SERIAL"
    rm -rf "$staged"
    mv "$LOCK" "$staged" 2>/dev/null || return 1
    if [ "$(record_field "$staged/holder" 4)" != "$token" ]; then
        restore_lock "$staged"
        return 1
    fi
    rm -rf "$staged"
}

break_lock() {
    local why="$1" token="${2-}"
    delete_generation "$token" breaking || return 1
    # After the fact, so the line describes what happened.
    echo "[vm-slot] breaking the lock: $why" >&2
}

cmd_acquire() {
    slot_identify
    slot_count || return 1
    mkdir -p "$FLTH_STATE_DIR"
    local waited=0 announced=0 snapshot name since token age index holders candidate number

    while :; do
        holders=""
        index=1
        while IFS= read -r candidate; do
            [ -d "$candidate" ] || continue
            number="${candidate##*/slot-}"
            number="${number%.lock}"
            case "$number" in '' | *[!0-9]*) continue ;; esac
            if [ "$number" -gt "$SLOT_COUNT" ]; then
                LOCK="$candidate"
                HOLDER="$LOCK/holder"
                snapshot="$(read_holder 2>/dev/null || true)"
                if [ -n "$snapshot" ]; then
                    if holder_is_abandoned "$snapshot"; then
                        break_lock 'disabled slot has no running VM' "$(snapshot_field "$snapshot" 4)" || true
                        continue
                    fi
                    name="$(snapshot_field "$snapshot" 2)"
                else
                    name="an incomplete reservation at $candidate"
                fi
                holders="$holders${holders:+, }$name (disabled slot)"
                index=$((SLOT_COUNT + 1))
            fi
        done < <(slot_paths)
        while [ "$index" -le "$SLOT_COUNT" ]; do
            slot_path "$index"
            index=$((index + 1))
            if mkdir "$LOCK" 2>/dev/null; then
                next_serial
                token="$(now)-$$-$SERIAL"
                guest_memory_mib > "$LOCK/memory"
                printf '%s\t%s\t%s\t%s\n' "$HOLDER_IDENTITY" "$HOLDER_NAME" "$(now)" \
                    "$token" > "$HOLDER"
                admit=0
                memory_admit || admit=$?
                if [ "$admit" = 0 ]; then
                    [ "$announced" = 1 ] && echo "[vm-slot] got the slot after $(pretty_age "$waited")" >&2
                    return 0
                fi
                delete_generation "$token" releasing || true
                [ "$admit" = "$ADMIT_WAIT" ] || return 1
                # The slot goes back for the wait, which can outlast this
                # process's own boot grace and let another waiter break it.
                name="$ADMIT_WAITING_ON"
                holders="$name ($ADMIT_WAIT_REASON)"
                break
            fi

            # A lock with no complete record: a holder mid-write, or one that
            # died between `mkdir` and `printf`. A moment for the first, then
            # reclaim. The empty token matches only a lock that still has no
            # record, so a replacement that arrived with one is left alone.
            if ! read_holder >/dev/null 2>&1; then
                sleep 1
                if ! read_holder >/dev/null 2>&1; then
                    break_lock "no holder recorded" "" || true
                    index=$((index - 1))
                    continue
                fi
            fi

            # ONE SNAPSHOT, AND EVERY PART OF THE DECISION COMES FROM IT.
            snapshot="$(read_holder 2>/dev/null || true)"
            if [ -z "$snapshot" ]; then
                index=$((index - 1))
                continue
            fi
            name="$(snapshot_field "$snapshot" 2)"
            since="$(snapshot_field "$snapshot" 3)"
            token="$(snapshot_field "$snapshot" 4)"
            age=$(( $(now) - since ))

            if holder_is_abandoned "$snapshot"; then
                break_lock "no VM is running for $name after $(pretty_age "$age")" "$token" || true
                index=$((index - 1))
                continue
            fi
            holders="$holders${holders:+, }$name ($(pretty_age "$age"))"
        done

        # THERE IS NO AGE-ALONE BREAK, AND THERE MUST NOT BE.
        #
        # An earlier version took the slot from any holder past 90 minutes
        # without asking whether its VM was up. Because the break lives in
        # this wait loop, crossing the limit did nothing until another
        # repository wanted the slot — and then it robbed a live machine
        # and booted a second one beside it. Measured: two VMs whose start
        # times were 5401 seconds apart against a 5400 second limit.
        #
        # A dead holder is already broken above, within the boot grace. A
        # live one must not be robbed by any rule. A holder whose script
        # died while its VM kept running is the one case nothing here can
        # reclaim, and the give-up message below names the remedy: a
        # person's decision, not a timer's.

        if [ "$announced" = 0 ]; then
            echo "[vm-slot] waiting for the VM slot — held by $holders" >&2
            echo "[vm-slot] $SLOT_COUNT VM slot(s); this is a queue, not a failure" >&2
            announced=1
        fi

        if [ "$waited" -ge "$WAIT_SECS" ]; then
            echo "[vm-slot] gave up after $(pretty_age "$waited") waiting for $holders" >&2
            echo "[vm-slot] if $name is finished, run 'chore vm:down' there, or" >&2
            echo "[vm-slot] 'chore vm:slot:release-force' to take the slot from it." >&2
            return 1
        fi

        sleep "$POLL_SECS"
        waited=$((waited + POLL_SECS))
    done
}

cmd_release() {
    local candidate
    while IFS= read -r candidate; do
        LOCK="$candidate"
        HOLDER="$LOCK/holder"
        release_slot "${1:-}"
    done < <(slot_paths)
    slot_path 1
}

cmd_check_memory() {
    slot_identify
    local candidate snapshot token admit waited=0 announced=0
    while IFS= read -r candidate; do
        LOCK="$candidate"
        HOLDER="$LOCK/holder"
        snapshot="$(read_holder 2>/dev/null || true)"
        if [ -n "$snapshot" ] && [ "$(snapshot_field "$snapshot" 1)" = "$HOLDER_IDENTITY" ]; then
            # This keeps its slot while it waits, and each pass renews the
            # boot grace, so no waiter breaks a lock whose boot has not begun.
            while :; do
                next_serial
                token="$(now)-$$-$SERIAL"
                renew_holder "$snapshot" "$token" || {
                    echo "[vm-slot] $HOLDER_NAME: memory reservation changed before the boot; refusing to start" >&2
                    return 1
                }
                snapshot="$(read_holder 2>/dev/null || true)"
                if [ "$(snapshot_field "$snapshot" 4)" != "$token" ]; then
                    echo "[vm-slot] $HOLDER_NAME: the renewed memory reservation was displaced; refusing to start" >&2
                    return 1
                fi
                admit=0
                memory_admit || admit=$?
                [ "$admit" = "$ADMIT_WAIT" ] || return "$admit"
                if [ "$announced" = 0 ]; then
                    echo "[vm-slot] $HOLDER_NAME: waiting before the boot — $ADMIT_WAITING_ON $ADMIT_WAIT_REASON" >&2
                    announced=1
                fi
                if [ "$waited" -ge "$WAIT_SECS" ]; then
                    echo "[vm-slot] gave up after $(pretty_age "$waited") waiting for $ADMIT_WAITING_ON" >&2
                    return 1
                fi
                sleep "$POLL_SECS"
                waited=$((waited + POLL_SECS))
            done
        fi
    done < <(slot_paths)
    echo "[vm-slot] $HOLDER_NAME: no memory reservation owns this boot; refusing to start" >&2
    return 1
}

# Before this VM stops to start again. The boot after the stop renews again
# (check-memory), but the stop itself can come long after the lease was taken,
# and a waiter must not find an old lease and no VM. A waiter that has already
# read the old record holds a token that no longer frees anything.
#
# Refused when no slot holds this VM: restarting then would run outside the limit.
cmd_renew() {
    slot_identify
    local candidate snapshot token
    while IFS= read -r candidate; do
        LOCK="$candidate"
        HOLDER="$LOCK/holder"
        snapshot="$(read_holder 2>/dev/null || true)"
        if [ -n "$snapshot" ] && [ "$(snapshot_field "$snapshot" 1)" = "$HOLDER_IDENTITY" ]; then
            next_serial
            token="$(now)-$$-$SERIAL"
            if ! renew_holder "$snapshot" "$token" ||
                [ "$(holder_field 4 2>/dev/null || true)" != "$token" ]; then
                echo "[vm-slot] $HOLDER_NAME: no reservation could be renewed: it changed as this tried" >&2
                return 1
            fi
            return 0
        fi
    done < <(slot_paths)
    echo "[vm-slot] $HOLDER_NAME: no reservation holds this VM, so a restart would run outside the limit" >&2
    return 1
}

renew_holder() (
    local expected="$1" token="$2"
    cd "$LOCK" || return 1
    [ "$(read_holder ./holder 2>/dev/null || true)" = "$expected" ] || return 1
    guest_memory_mib > "memory.next.$token" || return 1
    mv "memory.next.$token" memory || return 1
    printf '%s\t%s\t%s\t%s\n' "$(snapshot_field "$expected" 1)" "$(snapshot_field "$expected" 2)" "$(now)" "$token" > "holder.next.$token" || return 1
    mv "holder.next.$token" holder || return 1
)

release_slot() {
    if [ "${1:-}" = "--force" ]; then
        rm -rf "$LOCK"
        return 0
    fi
    slot_identify
    # ONE SNAPSHOT: the ownership test and the token must come from the
    # same record, or a release confirms it owns one generation and
    # deletes the next.
    local snapshot
    snapshot="$(read_holder 2>/dev/null || true)"
    if [ -z "$snapshot" ]; then
        # No complete record: somebody is between `mkdir` and the write.
        # Not ours to free — acquire reclaims it if it is abandoned.
        return 0
    fi
    if [ "$(snapshot_field "$snapshot" 1)" != "$HOLDER_IDENTITY" ]; then
        # Somebody else's slot. Silent: `down` releases unconditionally,
        # and halting a VM that never held the slot is ordinary.
        return 0
    fi
    delete_generation "$(snapshot_field "$snapshot" 4)" releasing || true
    return 0
}

cmd_status() {
    local candidate
    while IFS= read -r candidate; do
        LOCK="$candidate"
        HOLDER="$LOCK/holder"
        status_slot
    done < <(slot_paths)
    slot_path 1
}

status_slot() {
    local snapshot age
    snapshot="$(read_holder 2>/dev/null || true)"
    if [ -z "$snapshot" ]; then
        if [ -d "$LOCK" ]; then
            echo "the VM slot is being taken (no holder recorded yet)"
        else
            echo "the VM slot is free"
        fi
        return 0
    fi
    age=$(( $(now) - $(snapshot_field "$snapshot" 3) ))
    printf 'held by %s for %s\n' "$(snapshot_field "$snapshot" 2)" "$(pretty_age "$age")"
    printf '  identity: %s\n' "$(snapshot_field "$snapshot" 1)"
    if holder_is_dead "$(snapshot_field "$snapshot" 1)"; then
        if [ "$age" -le "$BOOT_GRACE_SECS" ]; then
            echo "  ...no VM yet, but it is within the $(pretty_age "$BOOT_GRACE_SECS") boot window"
        else
            echo "  ...but no VM is running for it; a waiter takes the slot once it has stayed absent for $(pretty_age "$ABSENT_GRACE_SECS")"
        fi
    fi
    return 0
}

# SOURCEABLE, SO THE FUNCTIONS CAN BE TESTED DIRECTLY. The windows the
# token closes are microseconds wide inside one process; a test can only
# reach them by holding a stale token and handing it to the real
# function. With FLTH_SLOT_LIB set this file defines everything and
# stops.
if [ -n "${FLTH_SLOT_LIB:-}" ]; then
    # shellcheck disable=SC2317  # reached only when executed, not sourced
    return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
    acquire) cmd_acquire ;;
    check-memory) cmd_check_memory ;;
    release) shift; cmd_release "${1:-}" ;;
    renew) cmd_renew ;;
    status) cmd_status ;;
    *)
        echo "usage: vm-slot.sh {acquire|release [--force]|renew|status}" >&2
        exit 2
        ;;
esac
