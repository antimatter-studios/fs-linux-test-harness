#!/usr/bin/env bash
#
# disposable.sh — a run's writes go with its boot, and so does everything else
# (#32, #220).
#
# The shared guest's disk is the box's and carries nobody's setup. Every boot is
# disposable: its writes go to an overlay the engine throws away when it stops, so
# a mount, a loop device or a half-finished install that one run leaves behind
# cannot surface as the next run's failure. Each consumer's setup runs when it
# joins, on the boot it joined, and goes with that boot. No boot keeps its writes,
# not even one that applies a setup.
#
# Against the stub engine, whose disk keeps a boot's writes only when it was booted
# with --persist. That the real engine keeps its side — QEMU opening the disk
# read-only and discarding the overlay — is pinned by tests/vagrantfile.sh (the
# flag) and proven by tests/smoke.sh (a VM).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"

C="$SANDBOX/consumer"
make_consumer "$C" disposable-test
export SETUP_LOG="$SANDBOX/setup.log"
GUEST_LIB=/var/lib/fs-linux-test-harness

vm() { (cd "$C" && "$VM" "$@"); }
setup_runs() { grep -c . "$SETUP_LOG" 2>/dev/null | tr -d ' ' || echo 0; }
# The boots and stops, in order, comma-separated.
lifecycle() { grep -E '^(up|up --persist|down)$' "$FLTH_TEST_STUB/calls" | paste -sd, -; }
persists() { grep -c '^up --persist$' "$FLTH_TEST_STUB/all-calls" 2>/dev/null | tr -d ' '; }
# Every call of the whole test, kept across the resets.
keep_calls() { cat "$FLTH_TEST_STUB/calls" >> "$FLTH_TEST_STUB/all-calls"; }

# --- the first boot is disposable, and setup runs on it --------------------

stub_state absent; stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "up boots an absent VM"
check_eq "$(lifecycle)" up "on one disposable boot: there is no provisioning boot"
check_eq "$(setup_runs)" 1 "and setup runs once, on it"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "and the VM is up"
keep_calls

# --- a run's writes do not outlive its boot ---------------------------------

vm run "touch $GUEST_LIB/a-run-wrote-this" 2>/dev/null
check_eq "$(vm run "test -e $GUEST_LIB/a-run-wrote-this && echo present" 2>/dev/null)" present \
    "a run's write is there for the rest of its boot"
vm down 2>/dev/null
stub_reset_calls
vm up 2>/dev/null
check_eq "$(vm run "test -e $GUEST_LIB/a-run-wrote-this && echo survived || echo gone" 2>/dev/null)" gone \
    "and gone once the boot has ended"
check_eq "$(lifecycle)" up "a cold boot is one disposable boot"
check_eq "$(setup_runs)" 2 "and setup runs again: the disk does not carry it"
keep_calls

# --- a changed setup reaches the running boot, and only that boot -----------

echo 'echo "setup v2 ran" >> "$SETUP_LOG"' >> "$C/setup.sh"
stub_reset_calls
vm up 2>/dev/null
check_eq "$(setup_runs)" 4 "a changed setup script is applied to the running boot"
check_eq "$(lifecycle)" "" "without stopping or booting anything"
keep_calls

# --- provision: setup again, in place ----------------------------------------

stub_reset_calls
vm provision 2>/dev/null
check_eq "$?" 0 "provision on a running VM succeeds"
check_eq "$(setup_runs)" 6 "and runs setup though it was unchanged"
check_eq "$(lifecycle)" "" "in place: the shared guest is not stopped for one consumer's setup"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "and it is left up"
keep_calls
vm down 2>/dev/null
stub_reset_calls
vm provision 2>/dev/null
check_eq "$(lifecycle)" up "provision of a stopped guest is one disposable boot too"
keep_calls

check_eq "$(persists)" 0 "no boot in all of this kept its writes"
vm down 2>/dev/null

finish disposable
