#!/usr/bin/env bash
#
# vm-slot.sh — one test VM at a time, across every repository.
#
#   vm-slot.sh acquire          wait for the slot, then take it
#   vm-slot.sh release          give it back, if this consumer holds it
#   vm-slot.sh release --force  free it whoever holds it
#   vm-slot.sh status           say who holds it and for how long
#
# WHY THIS EXISTS. A test VM asks for gigabytes. Two of them beside a
# compiler fill a laptop, and a full machine does not fail cleanly: it
# kills background work with no message connecting the two. That is what
# happened when several agents built fixtures in parallel.
#
# So the slot is ONE GLOBAL SLOT, not one per repository. The cost is
# stated rather than hidden: VM work in different repositories no longer
# overlaps, and a queued run waits for the one ahead. Slower on a good
# day, much better on a bad one, because the failure it removes was
# silent and the cost it adds is visible.
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
# Environment:
#   FLTH_STATE_DIR         where the lock lives (default
#                          ${XDG_STATE_HOME:-~/.local/state}/fs-linux-test-harness)
#   FLTH_SLOT_WAIT         seconds `acquire` waits before giving up (3600)
#   FLTH_SLOT_BOOT_GRACE   seconds a fresh holder is trusted without a
#                          running VM (180)
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

LOCK="$FLTH_STATE_DIR/slot.lock"
HOLDER="$LOCK/holder"

# Long, because a fixture build legitimately takes tens of minutes.
WAIT_SECS="${FLTH_SLOT_WAIT:-3600}"

# THE SLOT IS TAKEN BEFORE THE VM EXISTS — necessarily, since the point
# is to stop a second one booting. For the length of a boot there is a
# holder with no VM behind it; without a grace period a waiter would see
# nothing running, break the lock, and boot the second VM this file
# exists to prevent. Too long only delays reclaiming a dead lock; too
# short reintroduces the race, so it errs long.
BOOT_GRACE_SECS="${FLTH_SLOT_BOOT_GRACE:-180}"

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
    [ -f "$HOLDER" ] || return 1
    local line fields
    IFS= read -r line < "$HOLDER" 2>/dev/null || return 1
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
    mkdir -p "$FLTH_STATE_DIR"
    local waited=0 announced=0 snapshot identity name since token age

    while :; do
        if mkdir "$LOCK" 2>/dev/null; then
            next_serial
            printf '%s\t%s\t%s\t%s\n' "$HOLDER_IDENTITY" "$HOLDER_NAME" "$(now)" \
                "$(now)-$$-$SERIAL" > "$HOLDER"
            [ "$announced" = 1 ] && echo "[vm-slot] got the slot after $(pretty_age "$waited")" >&2
            return 0
        fi

        # A lock with no complete record: a holder mid-write, or one that
        # died between `mkdir` and `printf`. A moment for the first, then
        # reclaim. The empty token matches only a lock that still has no
        # record, so a replacement that arrived with one is left alone.
        if ! read_holder >/dev/null 2>&1; then
            sleep 1
            if ! read_holder >/dev/null 2>&1; then
                break_lock "no holder recorded" "" || true
                continue
            fi
        fi

        # ONE SNAPSHOT, AND EVERY PART OF THE DECISION COMES FROM IT.
        snapshot="$(read_holder 2>/dev/null || true)"
        [ -n "$snapshot" ] || continue
        identity="$(snapshot_field "$snapshot" 1)"
        name="$(snapshot_field "$snapshot" 2)"
        since="$(snapshot_field "$snapshot" 3)"
        token="$(snapshot_field "$snapshot" 4)"
        age=$(( $(now) - since ))

        if [ "$age" -gt "$BOOT_GRACE_SECS" ] && holder_is_dead "$identity"; then
            break_lock "no VM is running for $name after $(pretty_age "$age")" "$token" || true
            continue
        fi

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
            echo "[vm-slot] waiting for the VM slot — held by $name for $(pretty_age "$age")" >&2
            echo "[vm-slot] one VM runs at a time; this is a queue, not a failure" >&2
            announced=1
        fi

        if [ "$waited" -ge "$WAIT_SECS" ]; then
            echo "[vm-slot] gave up after $(pretty_age "$waited") waiting for $name" >&2
            echo "[vm-slot] if $name is finished, run 'chore vm:down' there, or" >&2
            echo "[vm-slot] 'chore vm:slot:release-force' to take the slot from it." >&2
            return 1
        fi

        sleep "$POLL_SECS"
        waited=$((waited + POLL_SECS))
    done
}

cmd_release() {
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
            echo "  ...but no VM is running for it; the next acquire will take the slot"
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
    release) shift; cmd_release "${1:-}" ;;
    status) cmd_status ;;
    *)
        echo "usage: vm-slot.sh {acquire|release [--force]|status}" >&2
        exit 2
        ;;
esac
