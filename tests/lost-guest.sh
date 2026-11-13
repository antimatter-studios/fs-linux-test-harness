#!/usr/bin/env bash
#
# lost-guest.sh -- a lost connection says what stopped the guest (#105).
#
# ssh's own failures are status 255, Vagrant's ssh settings carry `LogLevel
# FATAL` so ssh prints nothing about them, and the teardown that follows frees
# what could have told why. A consumer on a runner whose disk filled saw a bare
# exit 255, two minutes after QEMU had paused the guest.
#
# Against the stub engine, so every answer can be given on demand. A script
# exiting 255 stands in for ssh: the engine cannot tell those apart either.
# tests/lost-guest-engine.sh holds the real engine's answers, and tests/smoke.sh
# stops a real guest and reads the report.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
STUB="$FLTH_TEST_STUB"

C="$SANDBOX/consumer"
make_consumer "$C" lost-guest '[test]' 'command = "./work.sh"' 'guest_command = "./in-guest.sh"'
printf '#!/bin/sh\nexit 255\n' > "$C/in-guest.sh"
chmod +x "$C/in-guest.sh"
ln -s "$C" "$STUB/guest-repo"

# The host's disk, as df prints it: 0 MB free, unless a test says otherwise.
printf '0\n' > "$STUB/free_kb"
cat > "$STUB/bin/df" <<STUB_DF
#!/bin/sh
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo "/dev/stub 14680064 14680064 \$(cat "$STUB/free_kb") 100% /stub"
STUB_DF
chmod +x "$STUB/bin/df"

vm() { (cd "$C" && "$VM" "$@"); }
vm up >/dev/null 2>&1 || bad "the stub VM did not come up"

# lose <how the guest ends the call> [vm.sh command] -- sets $rc, $out and $err.
lose() {
    local script="$1" command="${2:-exec}"
    rm -f "$STUB/vm_status" "$STUB/guest_answers" "$STUB/ends_on_probe" "$STUB/ps_unreadable"
    [ -z "${VM_STATUS:-}" ] || printf '%s\n' "$VM_STATUS" > "$STUB/vm_status"
    [ -z "${ANSWERS:-}" ] || : > "$STUB/guest_answers"
    [ -z "${ENDS:-}" ] || : > "$STUB/ends_on_probe"
    printf '%s\n' "${CONSOLE:-[    1.000000] the last line the guest printed}" > "$STUB/console.log"
    stub_reset_calls
    rc=0
    (cd "$C" && "$VM" "$command" "$script") > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
    out="$(cat "$SANDBOX/out")"
    err="$(cat "$SANDBOX/err")"
    stub_state running
}

# --- QEMU paused the guest: the case that was a bare 255 -----------------

VM_STATUS=$'VM status: paused (io-error)\nI/O status: nospace\noverlay: 7.05 GiB' lose 'echo from-guest; exit 255'
check_eq "$rc" 255 "a lost connection keeps its status: a consumer may read it"
check_eq "$out" from-guest "the report stays out of stdout, which is the command's"
check_contains "$err" "ssh lost its connection to the guest, or the command itself exited 255" \
    "it says what 255 means, including that a command can exit 255 itself"
check_contains "$err" "what stopped it: QEMU paused the guest" "it names what stopped the guest"
check_contains "$err" "VM status: paused (io-error)" "and gives QEMU's monitor's status"
check_contains "$err" "I/O status: nospace" "and the disk's I/O status"
check_contains "$err" "0 MB free" "and how much of the host's disk holding the overlay is free"
check_contains "$err" "$STUB" "and which directory that is"
check_contains "$err" "7.05 GiB" "and how large the overlay has grown"
check_contains "$err" "[console] [    1.000000] the last line the guest printed" "and the tail of the console"
check_lacks "$(stub_calls)" "guest-answers" "a paused guest cannot answer, so it is not asked"

VM_STATUS=$'VM status: paused' lose 'exit 255'
check_contains "$err" "what stopped it: QEMU paused the guest" "a pause with no failed write is still a pause"
check_lacks "$err" "a write to the guest's disk failed" "and is not blamed on the disk"

VM_STATUS=$'VM status: paused (io-error)\nI/O status: nospace' lose 'exit 255'
check_contains "$err" "a write to the guest's disk failed" "a pause on a failed write says so"

# --- QEMU is gone ---------------------------------------------------------

CONSOLE='[  99.000000] reboot: Power down' lose "echo stopped > '$STUB/state'; exit 255"
check_eq "$rc" 255 "a guest that powered off keeps the status too"
check_contains "$err" "what stopped it: the guest powered itself off; QEMU then ended" \
    "its console's power-off is what names it"
check_contains "$err" "[console] [  99.000000] reboot: Power down" "and the console says so to the reader"
check_lacks "$(stub_calls)" "vm-status" "QEMU that has ended has no monitor to ask"

CONSOLE='[  99.000000] an ordinary line' lose "echo stopped > '$STUB/state'; exit 255"
check_contains "$err" "what stopped it: QEMU ended and the guest's console records no power-off" \
    "a QEMU that ended with no power-off on the console was killed or crashed"

lose "echo stopped > '$STUB/state'; rm -f '$STUB/console.log'; exit 255"
check_contains "$err" "QEMU ended and the guest's console records no power-off" "so was one with no console at all"
check_contains "$err" "no console output" "and the missing console is said to be missing"

lose "touch '$STUB/ps_unreadable'; exit 255"
check_contains "$err" "what stopped it: unknown; the process table could not be read" \
    "a process table that cannot be read is not reported as a stopped guest"
rm -f "$STUB/ps_unreadable"

# --- QEMU runs and the guest is not paused --------------------------------

ANSWERS=1 VM_STATUS='VM status: running' lose 'exit 255'
check_contains "$err" "what stopped it: not the guest: it is up and answers" "a guest that answers did not stop"
check_contains "$err" "VM status: running" "and QEMU's status is still given"

VM_STATUS='VM status: running' lose 'exit 255'
check_contains "$err" "what stopped it: QEMU is running and the guest does not answer" "one that does not answer hung or crashed"

lose 'exit 255'
check_contains "$err" "QEMU's monitor did not answer" "a monitor that does not answer is said to be silent"
check_contains "$err" "does not answer" "and the guest is still asked about"

# A guest shutting down drops its connections a moment before QEMU ends, so the
# first look finds QEMU running and a guest that does not answer. That is a
# power-off, not a hang.
ENDS=1 CONSOLE='[  99.000000] reboot: Power down' VM_STATUS='VM status: running' lose 'exit 255'
check_contains "$err" "what stopped it: the guest powered itself off" \
    "a guest found shutting down is reported as powered off once QEMU has ended"
check_lacks "$err" "hung or it crashed" "and not as hung"

# --- every path into the guest --------------------------------------------

VM_STATUS='VM status: paused' lose 'exit 255' run
check_eq "$rc" 255 "run keeps the status"
check_contains "$err" "what stopped it: QEMU paused the guest" "and reports a lost guest as exec does"

VM_STATUS='VM status: paused' lose 'exit 7'
check_eq "$rc" 7 "a command that fails with another status"
check_eq "$err" "" "prints nothing it did not print itself"
check_lacks "$(stub_calls)" "vm-status" "and costs no question of QEMU"

printf 'VM status: paused (io-error)\nI/O status: nospace\n' > "$STUB/vm_status"
stub_state running
rc=0
(cd "$C" && "$VM" guest-test) > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
err="$(cat "$SANDBOX/err")"
check_eq "$rc" 255 "guest-test keeps the status"
check_contains "$err" "what stopped it: QEMU paused the guest" "and reports what stopped the guest"
check_lacks "$(stub_calls)" "down" "and leaves the shared guest to the suites still using it"

# A setup script is a call into the guest too, and it fails in its own words.
stub_state absent
printf '#!/bin/sh\nexit 255\n' > "$C/setup.sh"
printf 'VM status: paused (io-error)\nI/O status: nospace\n' > "$STUB/vm_status"
rc=0
(cd "$C" && "$VM" up) > "$SANDBOX/out" 2> "$SANDBOX/err" || rc=$?
err="$(cat "$SANDBOX/err")"
check_eq "$rc" 1 "a setup lost with its guest fails as a failed setup does"
check_contains "$err" "the setup script (setup.sh) failed" "in the words it always used"
check_contains "$err" "what stopped it: QEMU paused the guest" "and says what stopped the guest"

finish lost-guest
