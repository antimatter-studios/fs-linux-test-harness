#!/usr/bin/env bash
#
# A VM restarted in place has no engine process for a moment. That moment
# must not read as an abandoned slot once the lease is past its boot grace,
# or a rival boots beside it and the host runs more VMs than its limit (#122).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness

make_consumer "$SANDBOX/reloader" reloading '[vm]' 'memory = "4G"'
make_consumer "$SANDBOX/rival" rival '[vm]' 'memory = "2G"'
make_consumer "$SANDBOX/prov" provisioning '[vm]' 'memory = "1G"'
cat > "$SANDBOX/prov/setup.sh" <<'SETUP'
#!/usr/bin/env bash
# A setup long enough to outlive the boot grace.
f="$FLTH_STATE_DIR/slot.lock/holder"
awk -F'\t' -v OFS='\t' '{$3 = $3 - 86400; print}' "$f" > "$f.aged"
mv "$f.aged" "$f"
SETUP

printf '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$SANDBOX/memory-bin/uname"
chmod +x "$SANDBOX/memory-bin/uname"
hash -r

SLOT="$STUB_HARNESS/scripts/vm-slot.sh"
VM="$STUB_HARNESS/scripts/vm.sh"
ONE="$FLTH_STATE_DIR/slot.lock"
TWO="$FLTH_STATE_DIR/slot-2.lock"
STUB="$FLTH_TEST_STUB"
MACHINE="$FLTH_CACHE_DIR/machines/reloading"
export FLTH_SLOT_COUNT=2 FLTH_SLOT_WAIT=0

as_reloader() { FLTH_CONFIG="$SANDBOX/reloader/fs-linux-test-harness.toml" "$@"; }
as_rival() { FLTH_CONFIG="$SANDBOX/rival/fs-linux-test-harness.toml" "$@"; }
as_prov() { FLTH_CONFIG="$SANDBOX/prov/fs-linux-test-harness.toml" "$@"; }

field() { awk -F'\t' -v n="$2" '{print $n}' "$1/holder" 2>/dev/null; }
holder_name() { field "$1" 2; }
holders() {
    local count=0 lock
    for lock in "$FLTH_STATE_DIR"/slot*.lock; do
        [ -f "$lock/holder" ] && count=$((count + 1))
    done
    echo "$count"
}

# A lease past its grace, keeping its token: what a long run looks like.
age_holder() {
    awk -F'\t' -v OFS='\t' '{$3 = $3 - 86400; print}' "$1/holder" > "$1/holder.aged"
    mv "$1/holder.aged" "$1/holder"
}

# Another consumer in slot one, booting and within its grace, so the reloader
# is left in slot two and the rival would be the host's third VM.
steady_holder() {
    mkdir -p "$ONE"
    printf '%s\t%s\t%s\t%s\n' /steady/machine steady "$(date +%s)" tok-steady > "$ONE/holder"
    printf '1024\n' > "$ONE/memory"
}

reset_scene() {
    "$SLOT" release --force
    rm -f "$STUB/gate_up" "$STUB/gate_up.reached" "$STUB/gate_down" "$STUB/gate_down.reached" \
        "$STUB/after_down" "$STUB/after_force_down" "$STUB/up_failures"
    rm -f "$MACHINE/keep-running"
    printf 'MemAvailable:   67108864 kB\n' > "$FLTH_TEST_MEMINFO"
    stub_state stopped
    stub_reset_calls
}

# The reloader in slot two, running, its lease long past the boot grace.
reloader_running_aged() {
    steady_holder
    stub_state running
    as_reloader "$SLOT" acquire 2>/dev/null
    check_eq "$?" 0 "$1: the reloader takes the second slot"
    age_holder "$TWO"
}

# Until the file appears or the process in the background has gone.
wait_for_gate() {
    local tries=0
    while [ ! -f "$1" ] && [ "$tries" -lt 600 ] && kill -0 "$2" 2>/dev/null; do
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    [ -f "$1" ]
}

calls_order() { stub_calls | grep -E '^(down|up)' | tr '\n' ' '; }

# --- a planned restart renews its lease --------------------------------

# The absence window is off for this part: only the renewal can hold the slot.
export FLTH_SLOT_ABSENT_GRACE=0
reset_scene
reloader_running_aged renew
old_token="$(field "$TWO" 4)"
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a rival waits beside a live VM past its grace"
as_reloader "$SLOT" renew
check_eq "$?" 0 "a planned restart renews its lease before stopping the VM"
new_token="$(field "$TWO" 4)"
check_eq "$([ "$new_token" != "$old_token" ] && echo rotated || echo same)" rotated \
    "the renewal changes the token a waiter may have inspected"
epoch="$(field "$TWO" 3)"
check_eq "$([ "$(( $(date +%s) - epoch ))" -le 180 ] && echo fresh || echo expired)" fresh \
    "the renewal gives the stop and start a fresh boot grace"
stub_state stopped
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a rival cannot take the second slot while the planned restart has no engine process"
check_lacks "$out" 'breaking the lock' "the planned restart is not called abandoned"
check_eq "$(holder_name "$TWO")" reloading "the restart keeps its reservation against the rival"
check_eq "$(holders)" 2 "the host stays at its configured limit of two"
(
    export FLTH_SLOT_LIB=1
    # shellcheck source=../scripts/vm-slot.sh
    . "$SLOT"
    set +e
    # shellcheck disable=SC2034  # read by delete_generation
    LOCK="$TWO" HOLDER="$TWO/holder"
    delete_generation "$old_token" breaking
)
check_eq "$?" 1 "a waiter holding the old token cannot free the renewed lease"
check_eq "$(holder_name "$TWO")" reloading "and the renewed lease survives it"

# The reservation still counts: the restart's guest is about to need it again.
"$SLOT" release --force
reloader_running_aged memory
as_reloader "$SLOT" renew 2>/dev/null
stub_state stopped
rm -r "$ONE"
printf 'MemAvailable:   6291456 kB\n' > "$FLTH_TEST_MEMINFO"
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a rival is not admitted on memory the restarting guest will take back"
check_contains "$out" '4096 MiB pending guests' "the restart's memory stays reserved"

# A consumer that lost its slot is told, rather than restarting outside the limit.
reset_scene
stub_state running
out="$(as_reloader "$SLOT" renew 2>&1)"
check_eq "$?" 1 "a VM holding no slot cannot renew one"
check_contains "$out" 'no reservation' "and the refusal says so"

# --- vm.sh reload: the harness's own stop and start ---------------------

reset_scene
steady_holder
as_reloader "$VM" up 2>/dev/null
check_eq "$?" 0 "the reloader boots through the harness"
check_eq "$(holder_name "$TWO")" reloading "into the second slot"
age_holder "$TWO"
stub_reset_calls
: > "$STUB/gate_up"
as_reloader "$VM" reload > "$SANDBOX/reload.log" 2>&1 &
reload_pid=$!
wait_for_gate "$STUB/gate_up.reached" "$reload_pid"
check_eq "$?" 0 "reload stops the VM and starts another boot"
check_eq "$(cat "$STUB/state")" stopped "the rival races the moment no engine process exists"
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a rival racing the reload does not get a third VM"
check_eq "$(holder_name "$TWO")" reloading "the reload keeps its slot through the stop and start"
check_eq "$(holders)" 2 "and the host stays at its limit"
rm -f "$STUB/gate_up"
wait "$reload_pid"
check_eq "$?" 0 "the reload completes"
check_eq "$(calls_order)" "down up " "one graceful stop, one disposable boot, no provisioning boot"
check_eq "$(cat "$STUB/state")" running "the VM is back"
check_eq "$(holder_name "$TWO")" reloading "and still holds its slot"
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a rival still waits after the reload"

# A hold is the guest's state as well as the host's, and a boot loses the guest's.
as_reloader "$VM" hold 2>/dev/null
: > "$STUB/scripts"
as_reloader "$VM" reload 2>/dev/null
check_eq "$?" 0 "a held VM can reload"
check_contains "$(cat "$STUB/scripts")" 'shutdown -c' "and it is held again once it is back"
rm -f "$MACHINE/keep-running"

# A session owns the VM with this call inside it; another one is using it.
sessions="$MACHINE/sessions"
as_reloader "$VM" session-begin "$$" 2>/dev/null
stub_reset_calls
as_reloader "$VM" reload 2>/dev/null
check_eq "$?" 0 "a session may reload the VM it is using"
rm -f "$sessions/$$"
/bin/sleep 60 &
other=$!
as_reloader "$VM" session-begin "$other" 2>/dev/null
stub_reset_calls
out="$(as_reloader "$VM" reload 2>&1)"
check_eq "$?" 1 "a reload is refused while another session uses the VM"
check_contains "$out" "pid $other" "and names it"
check_eq "$(calls_order)" "" "and stops nothing"
kill "$other" 2>/dev/null
wait "$other" 2>/dev/null
rm -f "$sessions/$other"

echo running > "$STUB/after_down"
echo stopped > "$STUB/after_force_down"
stub_reset_calls
as_reloader "$VM" reload 2>/dev/null
check_eq "$?" 0 "a graceful halt that left the VM up is forced"
check_eq "$(calls_order)" "down down --force up " "and the boot follows the confirmed stop"
echo running > "$STUB/after_force_down"
stub_reset_calls
out="$(as_reloader "$VM" reload 2>&1)"
check_eq "$?" 1 "a VM that will not stop fails the reload"
check_eq "$(stub_calls | grep -c '^up')" 0 "and nothing boots beside it"
check_eq "$(holder_name "$TWO")" reloading "and the running VM keeps its slot"
rm -f "$STUB/after_down" "$STUB/after_force_down"
stub_state running

echo 3 > "$STUB/up_failures"
out="$(as_reloader "$VM" reload 2>&1)"
check_eq "$?" 1 "a reload whose boot fails says so"
check_eq "$(holder_name "$TWO")" "" "and a VM confirmed stopped gives its slot back"
rm -f "$STUB/up_failures"

reset_scene
out="$(as_reloader "$VM" reload 2>&1)"
check_eq "$?" 1 "a stopped VM has nothing to reload"
check_contains "$out" 'not running' "and it is told so"
stub_state unknown
out="$(as_reloader "$VM" reload 2>&1)"
check_eq "$?" 1 "a state that cannot be read is not reloaded"
stub_state running
stub_reset_calls
out="$(as_reloader "$VM" reload 2>&1)"
check_eq "$?" 1 "a running VM holding no slot is not restarted"
check_contains "$out" 'no reservation' "and it is told why"
check_eq "$(calls_order)" "" "and it is left running"

# --- a provisioning boot stops and starts too ---------------------------

reset_scene
stub_state absent
: > "$STUB/gate_down"
export FLTH_SLOT_COUNT=1
as_prov "$VM" up > "$SANDBOX/prov.log" 2>&1 &
prov_pid=$!
wait_for_gate "$STUB/gate_down.reached" "$prov_pid"
check_eq "$?" 0 "a provisioning boot reaches its stop"
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a rival cannot take the slot while a provisioning boot restarts"
check_eq "$(holder_name "$ONE")" provisioning "the provisioning boot keeps its slot past the boot grace"
rm -f "$STUB/gate_down"
wait "$prov_pid"
check_eq "$?" 0 "the boot after provisioning proceeds"
export FLTH_SLOT_COUNT=2

# --- a reload the harness never sees ------------------------------------

# Nothing renewed anything, so only the absence window protects it. This is the
# default the machine runs with: a window as long as the boot grace.
unset FLTH_SLOT_ABSENT_GRACE
reset_scene
reloader_running_aged direct
stub_state stopped
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a direct reload's absent VM does not free its slot on sight"
check_lacks "$out" 'breaking the lock' "the rival does not call it abandoned yet"
check_contains "$out" 'gave up' "and it waits, visibly"
check_eq "$(holder_name "$TWO")" reloading "the direct reload keeps its slot"
check_eq "$(holders)" 2 "the host stays at its limit"
status="$("$SLOT" status 2>&1)"
check_contains "$status" 'stayed absent' "status says what the slot is waiting to see"
stub_state running
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "the VM coming back keeps the slot"
check_eq "$([ -e "$TWO/absent" ] && echo kept || echo cleared)" cleared "and forgets the absence"

# Its reservation is unknown rather than wrong: waiting is the answer, not a refusal.
reset_scene
reloader_running_aged direct-memory
stub_state stopped
rm -r "$ONE"
printf 'MemAvailable:   6291456 kB\n' > "$FLTH_TEST_MEMINFO"
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 1 "a rival does not boot on memory an absent VM may take back"
check_lacks "$out" 'insufficient host memory' "it is not refused for a guest that may be gone"
check_contains "$out" 'gave up' "it waits for the answer"
check_eq "$([ -d "$ONE" ] && echo held || echo free)" free "and leaves no reservation while it waits"
printf 'MemAvailable:   67108864 kB\n' > "$FLTH_TEST_MEMINFO"
as_rival "$SLOT" acquire 2>/dev/null
check_eq "$?" 0 "a free slot with memory for both guests is taken"
check_eq "$(holder_name "$TWO")" reloading "without touching the absent holder"

# An absence must be watched for the whole window, on this generation.
reset_scene
reloader_running_aged record
stub_state stopped
token="$(field "$TWO" 4)"
long_ago=$(( $(date +%s) - 1000 ))
printf '%s\t%s\t%s\n' "$token" "$long_ago" "$long_ago" > "$TWO/absent"
as_rival "$SLOT" acquire >/dev/null 2>&1
check_eq "$(holder_name "$TWO")" reloading "an absence last seen long ago starts a new window"
printf '%s\t%s\t%s\n' other-token "$long_ago" "$(date +%s)" > "$TWO/absent"
as_rival "$SLOT" acquire >/dev/null 2>&1
check_eq "$(holder_name "$TWO")" reloading "another generation's absence does not count"
printf '%s\t%s\t%s\n' "$token" "$long_ago" "$(date +%s)" > "$TWO/absent"
as_rival "$SLOT" acquire 2>/dev/null
check_eq "$?" 0 "an absence watched for the whole window frees the slot"
check_eq "$(holder_name "$TWO")" rival "the abandoned holder is reclaimed"

# --- an abandoned holder is still reclaimed -----------------------------

# Real time, briefly: a waiter's poll sleeps a fifth of a second here.
printf '#!/bin/sh\nexec /bin/sleep 0.2\n' > "$STUB/bin/sleep"
export FLTH_SLOT_ABSENT_GRACE=1 FLTH_SLOT_WAIT=3600

reset_scene
reloader_running_aged abandoned
stub_state stopped
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 0 "a waiter takes a slot whose VM stays absent for the window"
check_contains "$out" 'breaking the lock' "and says it broke the lock"
check_eq "$(holder_name "$TWO")" rival "the abandoned holder is replaced"
check_eq "$(holders)" 2 "at the limit, not past it"

reset_scene
export FLTH_SLOT_COUNT=1 FLTH_SLOT_BOOT_GRACE=0
stub_state running
as_reloader "$SLOT" acquire 2>/dev/null
as_reloader "$SLOT" renew 2>/dev/null
stub_state stopped
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 0 "a restart that renewed and then died is reclaimed too"
check_eq "$(holder_name "$ONE")" rival "so a renewal cannot hold a slot for good"
export FLTH_SLOT_COUNT=2
unset FLTH_SLOT_BOOT_GRACE

reset_scene
reloader_running_aged abandoned-memory
stub_state stopped
rm -r "$ONE"
printf 'MemAvailable:   6291456 kB\n' > "$FLTH_TEST_MEMINFO"
out="$(as_rival "$SLOT" acquire 2>&1)"
check_eq "$?" 0 "once settled, an abandoned holder reserves no memory"
check_lacks "$out" 'insufficient host memory' "and causes no refusal"
check_eq "$(holder_name "$ONE")" rival "the rival is admitted"

finish slot-reload
