#!/usr/bin/env bash
#
# smoke.sh — the harness end to end, through a REAL VM.
#
# Boots tests/smoke-consumer on this host (KVM on Linux, HVF on macOS) and
# checks every promise the harness makes against the machine itself:
#
#   up / setup    the VM boots, the consumer's setup installs its tooling
#                 inside it, the guest deadline is armed
#   slot          a second consumer cannot boot while this one holds it
#   run / share   exit status and output come back; files cross both ways
#   hold / reap   a held VM survives the reaper; a leaked one does not
#   test          a passing suite passes and tears down; a CORRUPTED one
#                 FAILS with a non-zero exit and still tears down;
#                 FLTH_KEEP_VM=1 keeps the VM
#   down/destroy  confirmed, and the slot released
#
# The VM is destroyed on every exit path. Uses the machine's real slot, so
# on a shared host it queues behind other repositories like anything else.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONSUMER="$REPO/tests/smoke-consumer"
VM="$REPO/scripts/vm.sh"
SLOT="$REPO/scripts/vm-slot.sh"
export FLTH_CONFIG="$CONSUMER/fs-linux-test-harness.toml"
unset FLTH_KEEP_VM

fails=0
passes=0
started=$(date +%s)
ok() { printf '  ok    %s\n' "$1"; passes=$((passes + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }
check_true() { if eval "$1"; then ok "$2"; else bad "$3"; fi; }
check_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (lacked '$2' in: $1)" ;; esac; }
step() { printf '\n== [%4ss] %s\n' "$(( $(date +%s) - started ))" "$1"; }
state() { "$VM" status >/dev/null 2>&1 && echo running || echo not-running; }
slot_holder() { "$SLOT" status | sed -n 's/^held by \([^ ]*\) for.*/\1/p'; }

CONTENDER="$(mktemp -d)"
cleanup() {
    step "cleanup: destroy the smoke VM"
    "$VM" destroy >/dev/null 2>&1 || "$VM" destroy
    rm -rf "$CONTENDER"
}
trap cleanup EXIT

step "host tools"
"$REPO/scripts/host-tools.sh" || { echo "smoke: this host cannot run the VM" >&2; exit 1; }

step "clean start"
"$VM" destroy >/dev/null 2>&1 || true
check_eq "$(state)" not-running "no smoke VM is running"

step "up: boot, setup, deadline"
t0=$(date +%s)
"$VM" up
check_eq "$?" 0 "vm.sh up succeeds"
echo "  (boot + setup took $(( $(date +%s) - t0 ))s)"
check_eq "$(state)" running "the VM is running"
check_eq "$(slot_holder)" flth-smoke "and holds the machine-wide slot"
check_eq "$("$VM" run hostname 2>/dev/null)" flth-smoke "the guest's hostname is the project name"
check_contains "$("$VM" run 'uname -a' 2>/dev/null)" "Linux flth-smoke" "uname -a runs in the guest"
check_contains "$("$VM" run 'mkfs.ext4 -V 2>&1 | head -1' 2>/dev/null)" "mke2fs" "the consumer's setup installed its tooling inside the VM"
check_eq "$("$VM" run 'test -r /run/systemd/shutdown/scheduled && echo armed' 2>/dev/null)" armed "the guest's own poweroff deadline is armed"
"$VM" run 'uname -a; cat /etc/debian_version; nproc; free -m | sed -n 2p; df -h / | tail -1' 2>/dev/null | sed 's/^/  guest: /'

step "slot: a second consumer cannot boot"
printf '[project]\nname = "flth-smoke-contender"\n[setup]\nscript = "setup.sh"\n' > "$CONTENDER/fs-linux-test-harness.toml"
echo true > "$CONTENDER/setup.sh"
out="$(cd "$CONTENDER" && FLTH_CONFIG='' FLTH_SLOT_WAIT=0 "$VM" up 2>&1)"
rc=$?
check_true '[ "$rc" -ne 0 ]' "the contender's up fails (exit $rc)" "the contender booted a second VM"
check_contains "$out" "held by flth-smoke" "it is told who holds the slot"
check_contains "$out" "not booting a second VM" "and that it did not boot"
check_eq "$(cd "$CONTENDER" && FLTH_CONFIG='' "$VM" status >/dev/null 2>&1 && echo running || echo not-running)" not-running "no second VM process exists"
check_eq "$(slot_holder)" flth-smoke "the slot is still held by the smoke consumer"

step "run and share"
"$VM" run 'echo out; echo err >&2; exit 7' > "$CONTENDER/out" 2> "$CONTENDER/err"
check_eq "$?" 7 "run returns the guest's exit status"
check_eq "$(cat "$CONTENDER/out")" out "and its stdout"
check_contains "$(cat "$CONTENDER/err")" err "and its stderr"
printf 'from host %s\n' "$$" > "$CONTENDER/host-file.txt"
guest_path="$("$VM" put "$CONTENDER/host-file.txt")"
check_eq "$guest_path" /share/host-file.txt "put answers the guest path"
check_eq "$("$VM" run "cat $guest_path" 2>/dev/null)" "from host $$" "the guest reads the host's file"
"$VM" run "echo from guest > /share/guest-file.txt" 2>/dev/null
check_eq "$(cat "$("$VM" share)/guest-file.txt")" "from guest" "the host reads the guest's file"

step "hold and reap"
"$VM" hold
check_eq "$("$VM" run 'test -e /run/fs-linux-test-harness-held && ! test -e /run/systemd/shutdown/scheduled && echo held' 2>/dev/null)" held \
    "hold marks the guest and cancels its deadline"
"$VM" reap
check_eq "$(state)" running "reap leaves a held VM running"
machine="$("$VM" config | sed -n 's/^machine=//p')"
rm -f "$machine/keep-running"   # a VM nothing accounted for: the leak the reaper exists for
"$VM" reap
check_eq "$(state)" not-running "reap stops a leaked VM"
check_true '[ "$(slot_holder)" != flth-smoke ]' "and releases the slot" "reap left the slot held"

step "test: a passing suite"
"$VM" test
check_eq "$?" 0 "vm.sh test exits 0 for a passing suite"
results="$("$VM" share)/results"
check_eq "$(cat "$results/verdict" 2>/dev/null)" pass "the verdict collected on the host is pass"
check_contains "$(cat "$results/e2fsck.log" 2>/dev/null)" "Pass 5: Checking group summary information" "e2fsck ran to completion, and its log came back"
check_eq "$(state)" not-running "the VM is torn down afterwards"
check_true '[ "$(slot_holder)" != flth-smoke ]' "and the slot released" "test left the slot held"

step "test: a corrupted image MUST fail"
"$VM" test corrupt
rc=$?
check_true '[ "$rc" -ne 0 ]' "vm.sh test exits non-zero ($rc) when the suite finds corruption" "a corrupted image passed"
check_eq "$(cat "$results/verdict" 2>/dev/null)" fail "the verdict collected on the host is fail"
check_contains "$(cat "$results/cmp.log" 2>/dev/null)" differ "because the content check found the flipped byte"
check_eq "$(state)" not-running "the VM is torn down after a failure too"

step "test: FLTH_KEEP_VM=1"
FLTH_KEEP_VM=1 "$VM" test
check_eq "$?" 0 "the suite passes"
check_eq "$(state)" running "and the VM is left running, as asked"

step "down"
"$VM" down
check_eq "$?" 0 "vm.sh down succeeds"
check_eq "$(state)" not-running "the VM is confirmed stopped"
check_true '[ "$(slot_holder)" != flth-smoke ]' "and the slot released" "down left the slot held"

step "destroy"
"$VM" destroy
check_eq "$?" 0 "vm.sh destroy succeeds"
check_contains "$("$VM" status 2>&1)" "(absent)" "the VM no longer exists"

trap - EXIT
rm -rf "$CONTENDER"
printf '\n== [%4ss] smoke: %s passed, %s failed\n' "$(( $(date +%s) - started ))" "$passes" "$fails"
[ "$fails" -eq 0 ]
