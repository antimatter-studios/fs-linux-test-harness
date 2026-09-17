#!/usr/bin/env bash
#
# vm.sh — the orchestration in scripts/vm.sh, against a stub engine.
#
# The stub (tests/stubs/engine.sh) answers the engine interface from
# files, so every decision can be driven through answers a real VM will
# not give on demand: a halt that leaves it running, a state nobody can
# read, a boot that fails twice. The slot is the real one, in a sandbox.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"

C="$SANDBOX/consumer"
make_consumer "$C" vm-test '[test]' 'command = "./work.sh"'
export SETUP_LOG="$SANDBOX/setup.log"
MACHINE="$FLTH_CACHE_DIR/machines/vm-test"
IDENTITY="$MACHINE/stub"

vm() { (cd "$C" && "$VM" "$@"); }
slot_holder() { awk -F'\t' '{print $2}' "$FLTH_STATE_DIR/slot.lock/holder" 2>/dev/null; }
calls_of() { grep -c "^$1\$" "$FLTH_TEST_STUB/calls" | tr -d ' '; }
setup_runs() { grep -c . "$SETUP_LOG" 2>/dev/null | tr -d ' ' || echo 0; }

# Another consumer's holder, alive, for "someone else has the slot".
foreign_holder() {
    mkdir -p "$FLTH_STATE_DIR/slot.lock"
    printf '%s\t%s\t%s\t%s\n' "/elsewhere/vagrant" other "$(date +%s)" tok-other > "$FLTH_STATE_DIR/slot.lock/holder"
}
free_slot() { rm -rf "$FLTH_STATE_DIR/slot.lock"; }

# --- usage ---------------------------------------------------------------

out="$("$VM" 2>&1)"; check_eq "$?" 2 "no command prints usage and exits 2"
check_contains "$out" "vm.sh run <cmd...>" "and the usage lists the commands"
out="$("$VM" frobnicate 2>&1)"; check_eq "$?" 2 "an unknown command exits 2"
out="$(cd "$SANDBOX" && "$VM" status 2>&1)"; check_eq "$?" 1 "a command with no consumer config fails"
check_contains "$out" "no fs-linux-test-harness.toml" "saying which file it wanted"

# --- up ---------------------------------------------------------------

stub_state absent; stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "up boots an absent VM"
check_eq "$(slot_holder)" vm-test "and takes the slot to do it"
check_eq "$(setup_runs)" 1 "and runs the setup script"
check_eq "$(cat "$MACHINE/setup.sha256")" "$(sha256sum "$C/setup.sh" | awk '{print $1}')" "and records what it applied"

stub_reset_calls
vm up 2>/dev/null
check_eq "$(calls_of up)" 0 "up on a running VM does not boot again"
check_eq "$(calls_of run)" 0 "nor ask the guest about setup when the script is unchanged"
check_eq "$(setup_runs)" 1 "so setup did not run twice"

echo 'echo "setup v2 ran" >> "$SETUP_LOG"' >> "$C/setup.sh"
vm up 2>/dev/null
check_eq "$(setup_runs)" 3 "a changed setup script is applied to a running VM"

vm provision 2>/dev/null
check_eq "$(setup_runs)" 5 "provision re-runs setup even when unchanged"

# A boot of a stopped VM whose guest already has this script applied.
stub_state stopped; free_slot; rm -f "$MACHINE/setup.sha256"
vm up 2>/dev/null
check_eq "$(setup_runs)" 5 "after a reboot, the guest's own stamp prevents a re-run"
check_eq "$(cat "$MACHINE/setup.sha256" 2>/dev/null)" "$(sha256sum "$C/setup.sh" | awk '{print $1}')" "and the host record is restored"

stub_state unknown; free_slot; stub_reset_calls
out="$(vm up 2>&1)"
check_eq "$?" 1 "up refuses to boot on a state that could not be read"
check_eq "$(calls_of up)" "0" "and does not boot"
check_eq "$(slot_holder)" "" "and does not take the slot"

stub_state absent; foreign_holder; stub_reset_calls
out="$(FLTH_SLOT_WAIT=0 vm up 2>&1)"
check_eq "$?" 1 "up fails when another consumer holds the slot"
check_eq "$(calls_of up)" 0 "without booting a second VM"
check_contains "$out" "not booting a second VM" "and says why"
free_slot

# --- boot retries ---------------------------------------------------------

stub_state absent; echo 2 > "$FLTH_TEST_STUB/up_failures"; stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "a boot that fails twice and then succeeds is an up"
check_eq "$(calls_of up)" 3 "after three attempts"
check_eq "$(calls_of 'down --force')" 2 "forcing the half-started VM down between attempts"

vm down 2>/dev/null
stub_state absent; echo 3 > "$FLTH_TEST_STUB/up_failures"; stub_reset_calls
out="$(vm up 2>&1)"
check_eq "$?" 1 "three failed boots fail up"
check_eq "$(calls_of up)" 3 "and it stops trying at three"
check_eq "$(slot_holder)" "" "a failed boot confirmed stopped gives the slot back"

stub_state absent; echo 3 > "$FLTH_TEST_STUB/up_failures"; echo unknown > "$FLTH_TEST_STUB/after_failed_up"
out="$(vm up 2>&1)"
check_eq "$(slot_holder)" vm-test "a failed boot whose state cannot be read KEEPS the slot"
check_contains "$out" "the slot is kept rather than" "and says so"
rm -f "$FLTH_TEST_STUB/after_failed_up"; free_slot

# --- down ---------------------------------------------------------------

stub_state absent; vm up 2>/dev/null; vm hold 2>/dev/null
vm down 2>/dev/null
check_eq "$?" 0 "down stops the VM"
check_eq "$(slot_holder)" "" "and, confirmed stopped, releases the slot"
check_eq "$([ -f "$MACHINE/keep-running" ] && echo present || echo cleared)" cleared "and clears the hold"

vm up 2>/dev/null; echo running > "$FLTH_TEST_STUB/after_down"
out="$(vm down 2>&1)"
check_eq "$?" 1 "a halt that leaves the VM running fails down"
check_eq "$(slot_holder)" vm-test "and keeps the slot"

echo unknown > "$FLTH_TEST_STUB/after_down"
out="$(vm down 2>&1)"
check_eq "$?" 1 "a halt after which the state cannot be read fails down"
check_eq "$(slot_holder)" vm-test "and NEVER releases the slot on an unread state"
check_contains "$out" "released on a guess" "saying why"
rm -f "$FLTH_TEST_STUB/after_down"

foreign_holder; stub_state stopped
vm down 2>/dev/null
check_eq "$(slot_holder)" other "down on a consumer that does not hold the slot leaves the holder alone"
free_slot

# --- destroy ------------------------------------------------------------

stub_state absent; vm up 2>/dev/null
vm destroy 2>/dev/null
check_eq "$?" 0 "destroy deletes the VM"
check_eq "$(slot_holder)" "" "and releases the slot once it is confirmed gone"
check_eq "$([ -f "$MACHINE/setup.sha256" ] && echo present || echo cleared)" cleared "and forgets what setup was applied"
vm up 2>/dev/null; echo unknown > "$FLTH_TEST_STUB/after_destroy"
out="$(vm destroy 2>&1)"
check_eq "$?" 1 "a destroy that cannot be confirmed fails"
check_eq "$(slot_holder)" vm-test "and keeps the slot"
rm -f "$FLTH_TEST_STUB/after_destroy"; stub_state stopped; vm down 2>/dev/null

# --- status -------------------------------------------------------------

stub_state running; out="$(vm status)"; check_eq "$?" 0 "status exits 0 for a running VM"
stub_state stopped; out="$(vm status)"; check_eq "$?" 1 "and 1 for a stopped one"
check_contains "$out" "not running (stopped)" "naming the state"
stub_state unknown; out="$(vm status)"; check_eq "$?" 1 "and 1 for an unreadable one"

# --- hold and reap ------------------------------------------------------

stub_state absent; free_slot; vm up 2>/dev/null; stub_reset_calls
out="$(vm hold 2>&1)"
check_contains "$out" "guest deadline is cancelled" "hold reaches the guest"
check_contains "$(stub_calls)" "shutdown -c" "and cancels its poweroff timer"
check_eq "$([ -f "$FLTH_TEST_STUB/guest-held" ] && echo yes)" yes "and marks the guest held"
out="$(vm reap 2>&1)"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "reap leaves a held VM running"
check_contains "$out" "left running" "and says why"

rm -f "$MACHINE/keep-running"
out="$(vm reap 2>&1)"
check_eq "$?" 0 "reap of a leaked VM succeeds"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "and stops it"
check_eq "$(slot_holder)" "" "and releases the slot"
check_contains "$out" "did not clean up" "and says why it acted"

stub_reset_calls
vm reap 2>/dev/null
check_eq "$(stub_calls | grep -vc '^prepare$' | tr -d ' ')" 0 "reap with nothing running makes no engine call beyond the process check"

# --- run, put, share, config -------------------------------------------

stub_state absent
out="$(vm run 'echo from-guest; exit 3' 2>/dev/null)"
check_eq "$?" 3 "run passes the guest command's exit status through"
check_eq "$out" "from-guest" "and its stdout, without setup or boot chatter"
out="$(vm run 'echo a && echo b | tr b c' 2>/dev/null)"
check_eq "$out" "a
c" "operators in the command belong to the guest's shell"

echo payload > "$SANDBOX/file.img"
out="$(vm put "$SANDBOX/file.img")"
check_eq "$out" "/share/file.img" "put prints the guest path"
check_eq "$(cat "$C/.vm-share/file.img")" payload "and the file is in the consumer's share"
check_eq "$(vm share)" "$(cd "$C" && pwd -P)/.vm-share" "share prints the host path"
out="$(vm config)"
check_contains "$out" "identity=$IDENTITY" "config prints the slot identity"
check_contains "$out" "slot=$FLTH_STATE_DIR/slot.lock" "and where the slot lives"
vm down 2>/dev/null

# --- test: the session rules --------------------------------------------

work() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$C/work.sh"; chmod +x "$C/work.sh"; }

stub_state absent; free_slot
work 'echo "args:[$*] vm:$(basename "$FLTH_VM") share:$FLTH_SHARE_HOST" > result.txt; "$FLTH_VM" run "true"'
vm test one "two words" 2>/dev/null
check_eq "$?" 0 "test succeeds when the work does"
check_eq "$(cat "$C/result.txt")" "args:[one two words] vm:vm.sh share:$(cd "$C" && pwd -P)/.vm-share" \
    "the command runs from the repository root with arguments appended and FLTH_VM set"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "and the VM is torn down afterwards"
check_eq "$(slot_holder)" "" "with the slot released"

work 'exit 4'
vm test 2>/dev/null
check_eq "$?" 4 "a failing test command fails test with its own status"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "and still tears down"

work 'exit 0'; echo running > "$FLTH_TEST_STUB/after_down"
out="$(vm test 2>&1)"
check_eq "$?" 1 "work that succeeds with a teardown that fails is a failure"
check_contains "$out" "TEARDOWN FAILED" "said loudly"
work 'exit 5'
vm test 2>/dev/null
check_eq "$?" 5 "when both fail, the work's status wins"
rm -f "$FLTH_TEST_STUB/after_down"; vm down 2>/dev/null

work 'exit 0'; stub_state absent
FLTH_KEEP_VM=1 vm test 2>/dev/null
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "FLTH_KEEP_VM=1 leaves the VM up"
vm down 2>/dev/null

make_consumer "$SANDBOX/notest" no-test
out="$(cd "$SANDBOX/notest" && "$VM" test 2>&1)"
check_eq "$?" 1 "test without a [test] command fails"
check_contains "$out" "has no [test] command" "and says so"

# --- setup failure --------------------------------------------------------

stub_state absent; free_slot
printf 'exit 9\n' > "$C/setup.sh"
out="$(vm up 2>&1)"
check_eq "$?" 1 "a failing setup script fails up"
check_contains "$out" "failed inside the VM" "saying where"
check_eq "$([ -f "$MACHINE/setup.sha256" ] && echo recorded || echo none)" none "and nothing is recorded as applied"
check_eq "$(cat "$FLTH_TEST_STUB/state")" running "the VM is left up to be inspected"
vm down 2>/dev/null

finish vm
