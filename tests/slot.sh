#!/usr/bin/env bash
#
# slot.sh — the machine-wide VM slot (scripts/vm-slot.sh).
#
# Three kinds of check:
#
#   * the REAL FUNCTIONS, sourced with FLTH_SLOT_LIB=1. The windows a
#     generation token closes are microseconds wide inside one process;
#     they can only be reached by holding a stale token and presenting it
#     to the function that ships, not to a reimplementation.
#   * the CLI, for ownership and contention between two consumers.
#   * the decisions that were once wrong in a copy of this file: breaking
#     on age alone, trusting a half-written record, treating an unreadable
#     process table as a dead holder.
#
# engine_alive (is the holder's VM running?) is shadowed per test.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

make_consumer "$SANDBOX/self" slot-self
make_consumer "$SANDBOX/other" slot-other
export FLTH_CONFIG="$SANDBOX/self/fs-linux-test-harness.toml"

export FLTH_SLOT_LIB=1
# shellcheck source=../scripts/vm-slot.sh
. "$REPO/scripts/vm-slot.sh"
set +e
slot_identify
SELF="$HOLDER_IDENTITY"
OTHER="$FLTH_CACHE_DIR/machines/slot-other/vagrant"
check_eq "$SELF" "$FLTH_CACHE_DIR/machines/slot-self/vagrant" "the holder identity is the consumer's machine identity"

# Nothing is running unless a test says so.
ALIVE=""
engine_alive() {
    [ "${PS_UNREADABLE:-}" = 1 ] && return 2
    [ -n "$ALIVE" ] && [ "$1" = "$ALIVE" ]
}

set_lock() {
    # set_lock [identity token [epoch]] — no arguments: a lock with no record
    rm -rf "$LOCK"
    mkdir -p "$LOCK"
    if [ "$#" -ge 2 ]; then
        printf '%s\t%s\t%s\t%s\n' "$1" "holder-repo" "${3:-$(date +%s)}" "$2" > "$HOLDER"
    fi
}
lock_is() {
    local got
    if [ -d "$LOCK" ]; then got=survived; else got=removed; fi
    check_eq "$got" "$1" "$2"
}

# --- tokens ----------------------------------------------------------

rm -rf "$LOCK"
tokens=""
for _ in 1 2 3 4 5; do
    cmd_acquire
    tokens="$tokens$(record_field "$HOLDER" 4)"$'\n'
    cmd_release
done
check_eq "$(printf '%s' "$tokens" | grep -c .)" 5 "five acquisitions each write a token"
check_eq "$(printf '%s' "$tokens" | sort -u | grep -c .)" 5 "and the five tokens differ, in one process and one second"
before="$SERIAL"; next_serial; next_serial
check_eq "$SERIAL" "$((before + 2))" "next_serial advances the counter in its caller, not a subshell"

cmd_acquire
record="$(cat "$HOLDER")"
check_eq "$(snapshot_field "$record" 1)" "$SELF" "the record names this consumer's identity"
check_eq "$(snapshot_field "$record" 2)" "slot-self" "and its project name"
cmd_release

# --- what counts as a record --------------------------------------------

set_lock; : > "$HOLDER"
read_holder >/dev/null; check_eq "$?" 1 "an empty holder file is not a record (acquire is mid-write)"
set_lock; printf '123\n' > "$HOLDER"
read_holder >/dev/null; check_eq "$?" 1 "a line with no tabs is not a record"
set_lock; printf '%s\t%s\t%s\n' "$OTHER" repo "$(date +%s)" > "$HOLDER"
read_holder >/dev/null; check_eq "$?" 1 "three fields is not a record: exactly four are written"
set_lock; printf '%s\t%s\t%s\t%s\n' "$OTHER" repo "yesterday" tok > "$HOLDER"
read_holder >/dev/null; check_eq "$?" 1 "a non-numeric epoch is not a record"
set_lock; printf '%s\t%s\t%s\t%s\n' "" repo "$(date +%s)" tok > "$HOLDER"
read_holder >/dev/null; check_eq "$?" 1 "an empty identity is not a record"
set_lock "$OTHER" tok
read_holder >/dev/null; check_eq "$?" 0 "a complete record is one"

# --- break_lock / delete_generation ---------------------------------------

set_lock "$OTHER" gen-A
break_lock "authorised" gen-A 2>/dev/null
lock_is removed "a break quoting the current generation deletes it"

set_lock "$OTHER" gen-B
break_lock "stale" gen-A 2>/dev/null
check_eq "$?" 1 "a break quoting a replaced generation reports it deleted nothing"
lock_is survived "and the replacement survives"
check_eq "$(record_field "$HOLDER" 4)" gen-B "with its record intact"
residue="$(find "$FLTH_STATE_DIR" -maxdepth 1 -name 'slot.lock.*' | wc -l | tr -d ' ')"
check_eq "$residue" 0 "an unauthorised break never moved the lock at all"

set_lock
break_lock "no holder recorded" "" 2>/dev/null
lock_is removed "a lock with no record is broken on an empty token"
set_lock "$OTHER" gen-C
break_lock "no holder recorded" "" 2>/dev/null
lock_is survived "an empty token does not match a real generation"

set_lock "$SELF" gen-E
delete_generation gen-D releasing
check_eq "$?" 1 "a release holding a replaced generation frees nothing"
lock_is survived "and the live generation is untouched"

# The binding INSIDE cmd_release: its read is shadowed so it believes it
# holds a generation the live lock no longer carries.
set_lock "$SELF" gen-live
saved="$(declare -f read_holder)"
eval 'read_holder() { printf "%s\t%s\t%s\t%s\n" "$SELF" holder-repo "$(date +%s)" gen-stale; }'
cmd_release
eval "$saved"
lock_is survived "cmd_release deletes only the generation it read, not whatever is at the path"

# --- restore_lock -----------------------------------------------------

set_lock "$OTHER" gen-G
staged="${LOCK}.breaking.t1"; mkdir -p "$staged"
printf '%s\t%s\t%s\t%s\n' "$OTHER" r "$(date +%s)" gen-OLD > "$staged/holder"
restore_lock "$staged" 2>/dev/null
check_eq "$?" 1 "a restore onto a retaken path reports failure"
check_eq "$(record_field "$HOLDER" 4)" gen-G "the live lock keeps the live generation"
check_eq "$(find "$LOCK" -mindepth 1 -type d | wc -l | tr -d ' ')" 0 "with no dead generation buried inside it (mkdir, not mv)"
kept="$(find "$FLTH_STATE_DIR" -maxdepth 1 -name 'slot.lock.orphan.*')"
check_eq "$(record_field "$kept/holder" 4)" gen-OLD "the displaced record is kept as an orphan, not deleted"
rm -rf "$FLTH_STATE_DIR"/slot.lock.orphan.*

for displaced in ONE TWO; do
    staged="${LOCK}.breaking.$displaced"; mkdir -p "$staged"
    printf '%s\t%s\t%s\t%s\n' "$OTHER" r "$(date +%s)" "gen-$displaced" > "$staged/holder"
    restore_lock "$staged" 2>/dev/null
done
check_eq "$(find "$FLTH_STATE_DIR" -maxdepth 1 -name 'slot.lock.orphan.*' | wc -l | tr -d ' ')" 2 \
    "two displaced records in one process are both kept"
rm -rf "$FLTH_STATE_DIR"/slot.lock.orphan.*

rm -rf "$LOCK"
staged="${LOCK}.breaking.t3"; mkdir -p "$staged"
printf '%s\t%s\t%s\t%s\n' "$OTHER" r "$(date +%s)" gen-H > "$staged/holder"
restore_lock "$staged"
check_eq "$(record_field "$HOLDER" 4)" gen-H "a restore onto a free path puts the lock back with its record"

# --- the acquire decision ---------------------------------------------

# Fast loops: sleep is a no-op and nobody waits.
sleep() { :; }
old=$(( $(date +%s) - 86400 ))

set_lock "$OTHER" gen-ancient "$old"
ALIVE="$OTHER"
FLTH_WAIT_OUT="$( WAIT_SECS=0; cmd_acquire 2>&1 )"
check_eq "$(record_field "$HOLDER" 4)" gen-ancient "a LIVE holder is never robbed, however old (no age-alone break)"
check_contains "$FLTH_WAIT_OUT" "gave up after" "the waiter gives up instead, and says so"
check_contains "$FLTH_WAIT_OUT" "vm:slot:release-force" "naming the person's remedy"

set_lock "$OTHER" gen-dead "$old"
ALIVE=""
WAIT_SECS=0 cmd_acquire 2>/dev/null
check_eq "$(snapshot_field "$(read_holder)" 1)" "$SELF" "a DEAD holder past the boot grace is broken and the slot taken"
cmd_release

set_lock "$OTHER" gen-booting
ALIVE=""
( WAIT_SECS=0; cmd_acquire 2>/dev/null )
check_eq "$(record_field "$HOLDER" 4)" gen-booting "a holder within the boot grace is not broken though no VM runs yet"

set_lock "$OTHER" gen-unseen "$old"
PS_UNREADABLE=1
( WAIT_SECS=0; cmd_acquire 2>/dev/null )
check_eq "$(record_field "$HOLDER" 4)" gen-unseen "an unreadable process table is not taken as a dead holder"
PS_UNREADABLE=""

set_lock
( WAIT_SECS=0; cmd_acquire 2>/dev/null )
check_eq "$(snapshot_field "$(read_holder)" 1)" "$SELF" "a lock abandoned before its record was written is reclaimed"
unset -f sleep

# --- the CLI: ownership and contention between consumers ---------------

set +e
slot() { (cd "$1" && FLTH_CONFIG='' "$REPO/scripts/vm-slot.sh" "${@:2}"); }
unset FLTH_SLOT_LIB FLTH_CONFIG
rm -rf "$LOCK"

slot "$SANDBOX/self" acquire 2>/dev/null
check_eq "$?" 0 "consumer A acquires a free slot"
out="$(FLTH_SLOT_WAIT=0 slot "$SANDBOX/other" acquire 2>&1)"
check_eq "$?" 1 "consumer B cannot acquire while A holds it"
check_contains "$out" "held by slot-self" "and is told who holds it"
out="$(slot "$SANDBOX/other" release 2>&1)"
check_eq "$(snapshot_field "$(read_holder)" 2)" slot-self "B's release does not free A's slot"
out="$(cd / && "$REPO/scripts/vm-slot.sh" status)"
check_contains "$out" "held by slot-self" "status works from anywhere, without a consumer"
slot "$SANDBOX/self" release
lock_is removed "A's release frees its own slot"
slot "$SANDBOX/other" acquire 2>/dev/null
check_eq "$?" 0 "and B then acquires it"
(cd / && "$REPO/scripts/vm-slot.sh" release --force)
lock_is removed "release --force frees it whoever holds it"
out="$(cd / && "$REPO/scripts/vm-slot.sh" status)"
check_eq "$out" "the VM slot is free" "and status says so"

finish slot
