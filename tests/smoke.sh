#!/usr/bin/env bash
#
# smoke.sh — the harness end to end, through a REAL VM.
#
# Boots tests/smoke-consumer on this host (KVM on Linux, HVF on macOS) and
# checks every promise the harness makes against the machine itself:
#
#   up / setup    the VM boots, the consumer's setup installs its tooling
#                 inside it, the guest deadline is armed
#   disposable    a run that leaves a file, a loop device and a mount
#                 behind changes not one byte of the machine's disk, and
#                 the next boot sees none of it
#   apt-ready     a held dpkg lock is found and named, as dpkg sees it
#   slot          a second consumer cannot boot while this one holds it
#   run / share   exit status and output come back; files cross both ways
#   direct I/O    a file on either share opens with O_DIRECT, as an image
#                 tool opens it (#26)
#   exec          the per-call path: never boots, and costs milliseconds
#                 rather than a handshake (a test process makes hundreds)
#   guest-test    the consumer's suite runs INSIDE the guest, from the
#                 repository the harness mounts there
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
verdict() { printf '\n== [%4ss] smoke: %s passed, %s failed\n' "$(( $(date +%s) - started ))" "$passes" "$fails"; }
# A boot that failed leaves nothing for any later step to ask, and booting
# again pays the whole retry budget a second time: two failed boots outlast
# the CI job's timeout, which then cancels it with no verdict (#45). Stop
# here, with the verdict; the EXIT trap still destroys the VM.
boot_or_stop() {
    if [ "$1" -ne 0 ]; then
        echo "  smoke: the VM did not boot, so no later step can run; stopping" >&2
        verdict
        exit 1
    fi
}
state() { "$VM" status >/dev/null 2>&1 && echo running || echo not-running; }
slot_holder() { "$SLOT" status | sed -n 's/^held by \([^ ]*\) for.*/\1/p'; }

repo_guest="$(sed -n 's/^FLTH_REPO_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"

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
rc=$?
check_eq "$rc" 0 "vm.sh up succeeds"
boot_or_stop "$rc"
echo "  (boot + setup took $(( $(date +%s) - t0 ))s)"
check_eq "$(state)" running "the VM is running"
check_eq "$(slot_holder)" flth-smoke "and holds the machine-wide slot"
check_eq "$("$VM" run hostname 2>/dev/null)" flth-smoke "the guest's hostname is the project name"
check_contains "$("$VM" run 'uname -a' 2>/dev/null)" "Linux flth-smoke" "uname -a runs in the guest"
check_contains "$("$VM" run 'mkfs.ext4 -V 2>&1 | head -1' 2>/dev/null)" "mke2fs" "the consumer's setup installed its tooling inside the VM"
check_eq "$("$VM" run 'test -r /run/systemd/shutdown/scheduled && echo armed' 2>/dev/null)" armed "the guest's own poweroff deadline is armed"
"$VM" run 'shutdown -c; rm -f /run/fs-linux-test-harness-rearmed' 2>/dev/null
check_eq "$("$VM" run 'test -r /run/systemd/shutdown/scheduled && echo armed' 2>/dev/null)" armed \
    "a call re-arms the deadline as it ends, on the guest's real logind (cancelled, then re-armed by the same call)"
"$VM" run 'uname -a; cat /etc/debian_version; nproc; free -m | sed -n 2p; df -h / | tail -1' 2>/dev/null | sed 's/^/  guest: /'

step "disposable: what a run leaves behind goes with its boot"
# The oracles are the guest's own losetup and findmnt, and the disk's
# bytes: QEMU opens it read-only on a disposable boot, so a checksum taken
# while the VM runs must still hold once the run has written and stopped.
machine="$("$VM" config | sed -n 's/^machine=//p')"
disk="$(find "$machine" -name 'linked-box.img' 2>/dev/null | head -1)"
check_true '[ -f "$disk" ]' "the machine's disk is at $disk" "no linked-box.img under $machine"
sum() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | awk '{print $1}'; }
before="$(sum "$disk")"
check_eq "$("$VM" config | sed -n 's/^disk.setup=//p')" "$(sum "$CONSUMER/setup.sh")" "the disk is recorded as carrying this setup"
"$VM" run 'set -e
    echo left > /var/lib/flth-smoke-left-this
    truncate -s 16M /var/tmp/flth-smoke.img
    mkfs.ext4 -q -F /var/tmp/flth-smoke.img
    dev="$(losetup -f --show /var/tmp/flth-smoke.img)"
    mkdir -p /mnt/flth-smoke
    mount "$dev" /mnt/flth-smoke
    echo inside > /mnt/flth-smoke/file
    sync' 2>/dev/null
check_eq "$?" 0 "a run leaves a file, a loop device and a mount behind"
check_contains "$("$VM" run 'losetup -a' 2>/dev/null)" "/var/tmp/flth-smoke.img" "the guest's losetup lists the loop device"
check_contains "$("$VM" run 'findmnt -n -o SOURCE /mnt/flth-smoke' 2>/dev/null)" "/dev/loop" "and findmnt the mount"
"$VM" down
check_eq "$?" 0 "the VM stops"
check_eq "$(sum "$disk")" "$before" "the machine's disk is byte for byte what it was before the run"
t0=$(date +%s)
"$VM" up
rc=$?
check_eq "$rc" 0 "the next boot comes up"
boot_or_stop "$rc"
echo "  (a cold boot of a provisioned machine took $(( $(date +%s) - t0 ))s)"
check_eq "$("$VM" run 'test -e /var/lib/flth-smoke-left-this && echo left || echo gone' 2>/dev/null)" gone "the file the run left is gone"
check_eq "$("$VM" run 'losetup -a | grep -c flth-smoke' 2>/dev/null)" 0 "and so is its loop device"
check_eq "$("$VM" run 'findmnt -n /mnt/flth-smoke >/dev/null && echo mounted || echo unmounted' 2>/dev/null)" unmounted "and its mount"
check_eq "$("$VM" run 'test -e /var/tmp/flth-smoke.img && echo kept || echo gone' 2>/dev/null)" gone "and the image behind them"
check_contains "$("$VM" run 'mkfs.ext4 -V 2>&1 | sed -n 1p' 2>/dev/null)" "mke2fs" "while what setup installed is still there"

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

step "direct I/O: a file on either share opens with O_DIRECT (#26)"
# Some image tools open their image with O_DIRECT (xfs_repair among them,
# and a loop device with direct I/O), and on the macOS engine that open
# failed with ENOTDIR on both shares: virtiofsd before 1.14.0 decoded an
# arm64 guest's open flags with x86_64 values, where arm64's O_DIRECT is
# O_DIRECTORY (christhomas/virtiofsd#3). scripts/host-tools.sh refuses
# those builds. This is the end-to-end check that 1.14.0 fixed it on a
# Mac, and it must stay green on 9p. A consumer meanwhile works on a guest-local copy (README,
# "Where a tool works on an image"); tests/guest-scratch.sh holds the
# smoke consumer to that.
for dir in /share "$repo_guest"; do
    out="$("$VM" run "f=$dir/.smoke-direct-io; rm -f \$f; dd if=/dev/zero of=\$f bs=4096 count=16 oflag=direct status=none && dd if=\$f of=/dev/null bs=4096 count=16 iflag=direct status=none && echo direct; rm -f \$f" 2>"$CONTENDER/direct-io.err")"
    if [ "$out" = direct ]; then
        ok "a file on $dir opens with O_DIRECT, to write and to read"
    else
        bad "a file on $dir does not open with O_DIRECT: $(tail -n 3 "$CONTENDER/direct-io.err" | tr '\n' ' ')"
    fi
done

step "apt-ready: the package manager's lock, as the guest's own dpkg sees it"
# The boot ran vagrant/guest/apt-ready.sh; the consumer's setup then
# installed packages, which is the proof it left the lock free. Here the
# same script meets a REAL dpkg-style (POSIX fcntl) lock in a real guest
# kernel, and dpkg itself is the oracle for whether the lock is held.
"$VM" put "$REPO/vagrant/guest/apt-ready.sh" >/dev/null
"$VM" run 'setsid python3 -c "import fcntl, time; f = open(\"/var/lib/dpkg/lock-frontend\", \"w\"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(120)" </dev/null >/dev/null 2>&1 & echo $! > /run/flth-smoke-locker; sleep 2' 2>/dev/null
locker="$("$VM" run 'cat /run/flth-smoke-locker' 2>/dev/null)"
out="$("$VM" run 'dpkg --configure -a' 2>&1)"
check_contains "$out" "lock" "the oracle: the guest's dpkg refuses to run while the lock is held"
out="$("$VM" run 'bash /share/apt-ready.sh 2' 2>&1)"
rc=$?
check_true '[ "$rc" -ne 0 ]' "apt-ready fails on a lock held past its wait" "apt-ready passed with the dpkg lock held (exit $rc)"
check_contains "$out" "held by pid $locker" "and names the process holding it"
"$VM" run "kill $locker" 2>/dev/null
check_eq "$("$VM" run 'bash /share/apt-ready.sh 10 >/dev/null && dpkg --configure -a && echo free' 2>/dev/null)" free \
    "once released, apt-ready passes and the guest's dpkg agrees"

step "apt-ready: a dpkg transaction an earlier boot left half done"
# dpkg journals a transaction in /var/lib/dpkg/updates/ and empties it when
# the transaction completes; a numbered entry left there is what an
# install stopped part way through leaves behind, and it is exactly what
# apt reads as "dpkg was interrupted". The guest's own apt is the oracle,
# before and after.
"$VM" run 'touch /var/lib/dpkg/updates/0000' 2>/dev/null
out="$("$VM" run 'apt-get check' 2>&1)"
check_contains "$out" "dpkg was interrupted" "the oracle: the guest's apt refuses an interrupted dpkg"
out="$("$VM" run 'bash /share/apt-ready.sh 10' 2>&1)"
rc=$?
check_eq "$rc" 0 "apt-ready finishes the transaction"
check_eq "$("$VM" run 'ls -A /var/lib/dpkg/updates/' 2>/dev/null)" "" "and dpkg's journal is empty after it"
out="$("$VM" run 'apt-get check' 2>&1)"
rc=$?
check_eq "$rc" 0 "and the guest's apt agrees the package manager is usable"
check_lacks "$out" "interrupted" "with no interruption reported"

step "exec: the per-call path"
"$VM" exec 'echo out; echo err >&2; exit 7' > "$CONTENDER/out" 2> "$CONTENDER/err"
check_eq "$?" 7 "exec returns the guest's exit status"
check_eq "$(cat "$CONTENDER/out")" out "and its stdout"
check_contains "$(cat "$CONTENDER/err")" err "and its stderr"
check_eq "$("$VM" exec "test -d $repo_guest && echo mounted" 2>/dev/null)" mounted "the consumer repository is mounted in the guest"
check_eq "$("$VM" exec "cat $repo_guest/$(basename "$FLTH_CONFIG") | sed -n 's/^name = //p'" 2>/dev/null)" '"flth-smoke"' \
    "and it is this consumer's own tree"
"$VM" exec "touch $repo_guest/.smoke-wrote-this" 2>/dev/null
check_true '[ -f "$CONSUMER/.smoke-wrote-this" ]' "the guest can write to it, so a build in there reaches the host" "the repository mount is read-only in the guest"
rm -f "$CONSUMER/.smoke-wrote-this"
# THE NUMBER THAT MATTERS: a suite asking the guest hundreds of questions
# pays this per question. A fresh ssh handshake is ~0.7s; multiplexed,
# ~0.03s.
t0=$(date +%s%N)
for _ in 1 2 3 4 5 6 7 8 9 10; do "$VM" exec true >/dev/null 2>&1; done
per_call=$(( ( $(date +%s%N) - t0 ) / 10000000 ))
echo "  (exec: ${per_call}ms per call, averaged over ten)"
check_true "[ $per_call -lt 250 ]" "ten execs average ${per_call}ms each — the connection is reused" \
    "exec costs ${per_call}ms per call, about what a fresh SSH handshake costs: the connection is NOT being reused"

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

step "guest-test: the suite runs inside the guest"
"$VM" guest-test > "$CONTENDER/guest-test.log" 2>&1
rc=$?
sed 's/^/  guest-test: /' "$CONTENDER/guest-test.log" | tail -5
check_eq "$rc" 0 "vm.sh guest-test exits 0 for a passing in-guest suite"
check_contains "$(cat "$CONTENDER/guest-test.log")" "in-guest suite: $repo_guest as root" \
    "the command ran in the guest, from the repository mount"
check_eq "$(cat "$("$VM" share)/results/verdict" 2>/dev/null)" pass "and its results are on the share"
check_eq "$(state)" not-running "the VM is torn down afterwards"

"$VM" guest-test corrupt > "$CONTENDER/guest-test-corrupt.log" 2>&1
rc=$?
check_true '[ "$rc" -ne 0 ]' "a corrupted image fails guest-test too (exit $rc)" "a corrupted in-guest run passed"
check_eq "$(state)" not-running "and it still tears down"

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
verdict
[ "$fails" -eq 0 ]
