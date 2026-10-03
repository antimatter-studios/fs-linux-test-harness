#!/usr/bin/env bash
#
# disposable.sh — a run's writes go with its boot; only setup reaches the
# machine's disk (#32).
#
# The disk carries what the consumer's setup script installed and nothing
# else. Every boot that runs anything is disposable: its writes go to an
# overlay the engine throws away when it stops, so a mount, a loop device
# or a half-finished install that one run leaves behind cannot surface as
# the next run's failure. Only a provisioning boot — the one that applies
# a setup script the disk does not carry yet — writes the disk, and it is
# stopped, confirmed, before anything runs.
#
# Against the stub engine, whose disk keeps a boot's writes only when it
# was booted with --persist. That the real engine keeps its side — QEMU
# opening the disk read-only and discarding the overlay — is pinned by
# tests/vagrantfile.sh (the flag) and proven by tests/smoke.sh (a VM).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"

C="$SANDBOX/consumer"
make_consumer "$C" disposable-test
export SETUP_LOG="$SANDBOX/setup.log"
MACHINE="$FLTH_CACHE_DIR/machines/disposable-test"
GUEST_LIB=/var/lib/fs-linux-test-harness

vm() { (cd "$C" && "$VM" "$@"); }
slot_holder() { awk -F'\t' '{print $2}' "$FLTH_STATE_DIR/slot.lock/holder" 2>/dev/null; }
calls_of() { grep -c "^$1\$" "$FLTH_TEST_STUB/calls" | tr -d ' '; }
setup_runs() { grep -c . "$SETUP_LOG" 2>/dev/null | tr -d ' ' || echo 0; }
setup_hash() { sha256sum "$C/setup.sh" | awk '{print $1}'; }
base_record() { cat "$MACHINE/base.sha256" 2>/dev/null || echo none; }
# The boots and stops, in order, comma-separated.
lifecycle() { grep -E '^(up|up --persist|down)$' "$FLTH_TEST_STUB/calls" | paste -sd, -; }
free_slot() { rm -rf "$FLTH_STATE_DIR/slot.lock"; }

# --- the first boot provisions the disk, then runs on a disposable one ------

stub_state absent; stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "up boots an absent VM"
check_eq "$(lifecycle)" "up --persist,down,up" \
    "setup is applied on a boot that keeps its writes, which is stopped before a disposable boot"
check_eq "$(setup_runs)" 1 "and setup runs once"
check_eq "$(base_record)" "$(setup_hash)" "the machine records which setup its disk carries"
check_eq "$(slot_holder)" disposable-test "the slot is held throughout"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "and the VM is up"

# --- a run's writes do not outlive its boot ---------------------------------

vm run "touch $GUEST_LIB/a-run-wrote-this" 2>/dev/null
check_eq "$(vm run "test -e $GUEST_LIB/a-run-wrote-this && echo present" 2>/dev/null)" present \
    "a run's write is there for the rest of its boot"
vm down 2>/dev/null
stub_reset_calls
vm up 2>/dev/null
check_eq "$(vm run "test -e $GUEST_LIB/a-run-wrote-this && echo survived || echo gone" 2>/dev/null)" gone \
    "and gone once the boot has ended"
check_eq "$(lifecycle)" up "a cold boot of a provisioned machine is one disposable boot"
check_eq "$(setup_runs)" 1 "and setup does not run again: the disk carries it"

# --- a changed setup script reaches the disk on the next cold boot ----------

echo 'echo "setup v2 ran" >> "$SETUP_LOG"' >> "$C/setup.sh"
vm up 2>/dev/null
check_eq "$(setup_runs)" 3 "a changed setup script is applied to the running boot"
check_lacks "$(base_record)" "$(setup_hash)" "but the disk is not recorded as carrying it"
vm down 2>/dev/null
stub_reset_calls
vm up 2>/dev/null
check_eq "$(lifecycle)" "up --persist,down,up" "so the next cold boot provisions the disk first"
check_eq "$(setup_runs)" 5 "applying it there"
check_eq "$(base_record)" "$(setup_hash)" "and records it"
vm down 2>/dev/null
stub_reset_calls
vm up 2>/dev/null
check_eq "$(lifecycle)" up "after which a cold boot is disposable again"
check_eq "$(setup_runs)" 5 "and needs no setup"
vm down 2>/dev/null

# --- a disk that does not carry its record is re-provisioned --------------

# The record is the host's word for what the disk holds; the guest's stamp
# on the disk is the authority. When they disagree the run still gets its
# setup, and the record is dropped so the next cold boot commits it.
rm -rf "$FLTH_TEST_STUB/disk"; mkdir -p "$FLTH_TEST_STUB/disk"
stub_reset_calls
vm up 2>/dev/null
check_eq "$(lifecycle)" up "a disk that lost its setup still boots disposable"
check_eq "$(setup_runs)" 7 "and the run gets its setup"
check_eq "$(base_record)" none "and the record that lied is dropped"
vm down 2>/dev/null
stub_reset_calls
vm up 2>/dev/null
check_eq "$(lifecycle)" "up --persist,down,up" "so the next cold boot provisions the disk"
vm down 2>/dev/null

# --- a provisioning boot that does not stop -------------------------------

echo 'echo "setup v3 ran" >> "$SETUP_LOG"' >> "$C/setup.sh"
stub_state stopped; free_slot; stub_reset_calls
echo unknown > "$FLTH_TEST_STUB/after_down"
out="$(vm up 2>&1)"
check_eq "$?" 1 "up fails when the provisioning boot cannot be confirmed stopped"
check_contains "$out" "provisioning boot" "naming the boot"
check_eq "$(calls_of up)" 0 "and nothing runs on a disk whose writes are not known to be finished"
check_lacks "$(base_record)" "$(setup_hash)" "nor is the setup recorded as on the disk"
check_eq "$(slot_holder)" disposable-test "and the slot is kept: the VM may still be up"
rm -f "$FLTH_TEST_STUB/after_down"; stub_state stopped; free_slot

# --- nothing runs on a provisioning boot ----------------------------------

# A failed setup leaves its provisioning boot up to be inspected. Its
# writes are kept, so a run there would reach the disk.
cp "$C/setup.sh" "$SANDBOX/setup.good"
printf 'exit 9\n' > "$C/setup.sh"
stub_state stopped; stub_reset_calls
out="$(vm up 2>&1)"
check_eq "$?" 1 "a failing setup fails up"
check_eq "$(lifecycle)" "up --persist" "on the provisioning boot, which is left up to be inspected"
cp "$SANDBOX/setup.good" "$C/setup.sh"
stub_reset_calls
out="$(vm run 'echo ran' 2>&1)"
check_eq "$?" 1 "run refuses a VM that is up on a provisioning boot"
check_lacks "$out" "ran" "without running the command"
check_contains "$out" "chore vm:down" "and says how to get past it"
out="$(vm exec 'echo ran' 2>&1)"
check_eq "$?" 1 "and so does exec"
check_lacks "$out" "ran" "without running the command either"
vm down 2>/dev/null
check_eq "$?" 0 "down stops it"
stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "and the next up succeeds"
check_eq "$(lifecycle)" "up --persist,down,up" "provisioning the disk again first"
check_eq "$(vm run 'echo ran' 2>/dev/null)" ran "after which a run runs"

# --- provision ------------------------------------------------------------

before="$(setup_runs)"
stub_reset_calls
vm provision 2>/dev/null
check_eq "$?" 0 "provision on a running VM succeeds"
check_eq "$(lifecycle)" "down,up --persist,down,up" "stopping it, and re-applying setup on a provisioning boot"
check_eq "$(( $(setup_runs) - before ))" 3 "setup ran though it was unchanged"
check_eq "$(base_record)" "$(setup_hash)" "and the disk is recorded as carrying it"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "the VM is left up, as before"

vm hold 2>/dev/null
vm provision 2>/dev/null
check_eq "$([ -f "$MACHINE/keep-running" ] && echo held || echo released)" held "a held VM is still held after provision"

mkdir -p "$MACHINE/sessions"
# A live process that is not this one: `sleep` is stubbed to return at once.
tail -f /dev/null & sleep_pid=$!
printf '%s\t%s\n' "$sleep_pid" "$(ps -o lstart= -p "$sleep_pid" | sed 's/^ *//')" > "$MACHINE/sessions/$sleep_pid"
stub_reset_calls
out="$(vm provision 2>&1)"
check_eq "$?" 1 "provision refuses a VM another session is using"
check_contains "$out" "pid $sleep_pid" "naming the session"
check_eq "$(calls_of down)" 0 "and does not stop it under them"
kill "$sleep_pid" 2>/dev/null; wait "$sleep_pid" 2>/dev/null
rm -rf "$MACHINE/sessions"

# --- destroy ----------------------------------------------------------------

vm destroy 2>/dev/null
check_eq "$(base_record)" none "destroy forgets what the disk carried"
stub_reset_calls
vm up 2>/dev/null
check_eq "$(lifecycle)" "up --persist,down,up" "and the next boot provisions a new one"
vm down 2>/dev/null

# --- a declared cache outlives every boot, and nothing else does (#39) ------

# A consumer that keeps an in-guest build cache declares it, and gets a
# place at /cache whose writes survive the disposable boot that made them.
# Whatever the run wrote anywhere else is gone exactly as before. That the
# real engine keeps its side — a disk of its own, outside the overlay — is
# pinned by tests/vagrantfile.sh and tests/engine-vagrant.sh and proven on
# a VM by tests/smoke.sh.
vm destroy 2>/dev/null
CC="$SANDBOX/cached"
make_consumer "$CC" disposable-test '[cache]' 'size = "4G"'
vmc() { (cd "$CC" && "$VM" "$@"); }
vmc up 2>/dev/null
check_eq "$?" 0 "a consumer that declares a cache boots"
check_eq "$(vmc run 'test -d /cache && echo there' 2>/dev/null)" there "and finds its cache at /cache"
check_contains "$(vmc config)" "cache.guest=/cache" "and config says where it is"
check_contains "$(vmc config)" "cache.size=4G" "and how big"
vmc run "echo built > /cache/build-output; touch $GUEST_LIB/not-declared" 2>/dev/null
vmc down 2>/dev/null
stub_reset_calls
vmc up 2>/dev/null
check_eq "$(lifecycle)" up "the next boot is disposable"
check_eq "$(vmc run 'cat /cache/build-output' 2>/dev/null)" built "and what the last run left in the cache is there"
check_eq "$(vmc run "test -e $GUEST_LIB/not-declared && echo survived || echo gone" 2>/dev/null)" gone \
    "while what it left anywhere else is gone"
echo 'echo "setup v4 ran" >> "$SETUP_LOG"' >> "$CC/setup.sh"
vmc down 2>/dev/null
stub_reset_calls
vmc up 2>/dev/null
check_eq "$(lifecycle)" "up --persist,down,up" "a changed setup script provisions the disk"
check_eq "$(vmc run 'cat /cache/build-output' 2>/dev/null)" built "and the cache survives that too"
vmc destroy 2>/dev/null
vmc up 2>/dev/null
check_eq "$(vmc run 'cat /cache/build-output 2>/dev/null || echo empty' 2>/dev/null)" empty \
    "destroy empties it: a cache is regenerable, and destroy is the reset"
vmc down 2>/dev/null
vm up 2>/dev/null
check_eq "$(vm run 'test -e /cache && echo there || echo none' 2>/dev/null)" none \
    "a consumer that declares no cache has no /cache"
vm down 2>/dev/null

finish disposable
