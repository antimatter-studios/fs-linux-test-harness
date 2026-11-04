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
#   cache         the declared cache (#39) is a mount of its own, with the
#                 root's filesystem, and what a run leaves there is still
#                 there after the boot that wrote it has stopped
#   overlay       what the guest deletes goes back to the host: the overlay,
#                 as QEMU's monitor measures it, does not keep it (#105)
#   apt-ready     a held dpkg lock is found and named, as dpkg sees it
#   slot          a second consumer cannot boot while this one holds it
#   run / share   exit status and output come back; files cross both ways
#                 and nothing in the guest writes to what the host staged
#   direct I/O    a file on either share opens with O_DIRECT, as an image
#                 tool opens it (#26)
#   exec          the per-call path: never boots, and costs milliseconds
#                 rather than a handshake (a test process makes hundreds)
#   guest-test    the consumer's suite runs INSIDE the guest, from the
#                 repository the harness mounts there
#   lost guest    a guest paused or powered off under a running call ends that
#                 call with what stopped it, not a bare 255 (#105)
#   boot signal   a session signalled during a boot leaves no guest, although
#                 FLTH_KEEP_VM=1 asks, and the next call has its shares (#134)
#   reload        the guest really reboots in place and keeps its slot (#122)
#   hold / reap   a held VM survives the reaper; a leaked one does not
#   signal        a VM that stays up after a session is signalled keeps /share
#                 and /repo, and the command's descendants still end (#130)
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
# Which pinned guest boots: FLTH_SMOKE_GUEST, debian-12 by default, as every
# consumer's is. Each guest has its own copy of the consumer's config, the
# same but for `[vm] guest`, so CI boots every guest a consumer can pin (#70).
SMOKE_GUEST="${FLTH_SMOKE_GUEST:-debian-12}"
case "$SMOKE_GUEST" in
    debian-12) export FLTH_CONFIG="$CONSUMER/fs-linux-test-harness.toml" ;;
    debian-13) export FLTH_CONFIG="$CONSUMER/fs-linux-test-harness.debian-13.toml" ;;
    *) echo "smoke: FLTH_SMOKE_GUEST must be debian-12 or debian-13, got '$SMOKE_GUEST'" >&2; exit 2 ;;
esac
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
slot_holder() { "$SLOT" status | awk '$1 == "held" && $2 == "by" && $3 == "flth-smoke" && $4 == "for" { print $3 }'; }
slot_contender() {
    local state="$CONTENDER/slot-state"
    FLTH_STATE_DIR="$state" FLTH_SLOT_COUNT=1 "$SLOT" acquire || return
    (cd "$CONTENDER" && FLTH_CONFIG='' FLTH_STATE_DIR="$state" FLTH_SLOT_COUNT=1 FLTH_SLOT_WAIT=0 "$VM" up)
}

qemu_process() {
    local identity
    identity="$("$VM" config | sed -n 's/^identity=//p')"
    [ -n "$identity" ] || return 1
    ps -eo pid=,args= | awk -v want="$identity/" '$2 ~ /qemu-system-/ && index($0, want) > 0'
}
qemu_memory() { qemu_process | sed -n 's/.*mem-path=\([^, ]*\).*/\1/p'; }
memory_stamp() { ruby -e 's = File.stat(ARGV[0]); puts "#{s.dev}:#{s.ino}"' "$1"; }
check_artifacts_gone() {
    local memory="$1" action="$2" artifact identity remaining=""
    check_true '[ -z "$memory" ] || [ ! -e "$memory" ]' "$action removes unused QEMU memory" "$action left $memory behind"
    [ -n "$memory" ] || return 0
    identity="${memory##*/vagrant-qemu-}"
    identity="${identity%-mem}"
    for artifact in "${memory%/*}/vqemu-$identity-"virtiofs*.sock.pid; do
        [ ! -e "$artifact" ] || remaining="$remaining $artifact"
    done
    check_eq "$remaining" '' "$action removes unused virtiofs socket pidfiles"
}

repo_guest="$(sed -n 's/^FLTH_REPO_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"

# QEMU'S MONITOR, ASKED DIRECTLY (#105). The overlay is unlinked as soon as it is
# open, so nothing on the host can stat it and the host's free space moves with
# whatever else runs there. The monitor reports the open file's size, on a socket
# the provider names on QEMU's command line.
monitor() {
    local identity socket
    identity="$("$VM" config | sed -n 's/^identity=//p')"
    socket="$(ps -eo args= | awk -v want="$identity/" '$1 ~ /qemu-system-/ && index($0, want) > 0' |
        sed -n 's/.*id=mon0,path=\([^, ]*\).*/\1/p' | sed -n 1p)"
    [ -n "$socket" ] && perl "$REPO/tests/qemu-monitor.pl" "$socket" "$@"
}
# The overlay's size in MiB: the first image `info block -v` lists under the
# machine's disk is the top of its chain.
overlay_mib() {
    monitor 'info block -v' | tr -d '\r' | awk '/^disk0 / { disk = 1 } disk && /^disk size: / { unit = $4 == "GiB" ? 1024 : $4 == "MiB" ? 1 : $4 == "KiB" ? 1 / 1024 : 0; if (unit) printf "%d\n", $3 * unit; exit }'
}

CONTENDER="$(mktemp -d)"
cleanup() {
    step "cleanup: destroy the smoke VM"
    "$VM" destroy >/dev/null 2>&1 || "$VM" destroy
    kernel_vm destroy >/dev/null 2>&1 || kernel_vm destroy
    rm -rf "$CONTENDER"
}
# The second consumer, whose setup installs a kernel (#80).
kernel_vm() { FLTH_CONFIG="$REPO/tests/smoke-kernel-consumer/fs-linux-test-harness.toml" "$VM" "$@"; }
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
memory="$(qemu_memory)"
if [ "$(uname -s)" = Darwin ]; then
    check_true '[ -n "$memory" ] && [ -f "$memory" ]' "the running QEMU's shared-memory file is observed" "no shared-memory file was found for the running QEMU"
fi
check_eq "$(slot_holder)" flth-smoke "and holds the machine-wide slot"
check_eq "$("$VM" run hostname 2>/dev/null)" flth-smoke "the guest's hostname is the project name"
check_contains "$("$VM" run 'uname -a' 2>/dev/null)" "Linux flth-smoke" "uname -a runs in the guest"
check_contains "$("$VM" run 'mkfs.ext4 -V 2>&1 | head -1' 2>/dev/null)" "mke2fs" "the consumer's setup installed its tooling inside the VM"
# The guest's serial console is logged in the machine directory, for a
# failed boot to show (#61). The oracle is the guest's own kernel: the
# release it reports is the one its boot banner wrote there.
console_log="$("$VM" config | sed -n 's/^machine=//p')/console.log"
release="$("$VM" run 'uname -r' 2>/dev/null)"
check_contains "$(cat "$console_log" 2>/dev/null)" "Linux version $release" \
    "the console log in the machine directory holds the guest kernel's boot banner"
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
cache_guest="$(sed -n 's/^FLTH_CACHE_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
check_eq "$("$VM" run "findmnt -n -o FSTYPE $cache_guest" 2>/dev/null)" "$("$VM" run 'findmnt -n -o FSTYPE /' 2>/dev/null)" \
    "the declared cache is mounted at $cache_guest, with the filesystem the guest's root uses"
check_contains "$("$VM" run "findmnt -n -o SOURCE $cache_guest" 2>/dev/null)" "/dev/vd" "a disk of its own, not the root or a share"
check_true '[ -f "$machine/cache.img" ]' "its disk is in the machine directory" "no cache.img under $machine"
"$VM" run "echo kept > $cache_guest/flth-smoke-kept-this" 2>/dev/null
check_eq "$?" 0 "a run writes into the cache"
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
check_artifacts_gone "$memory" down
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
check_eq "$("$VM" run "cat $cache_guest/flth-smoke-kept-this" 2>/dev/null)" kept \
    "and what the run left in the declared cache survived the stop and the disposable boot"

step "slot: a second consumer cannot boot"
printf '[project]\nname = "flth-smoke-contender"\n[setup]\nscript = "setup.sh"\n' > "$CONTENDER/fs-linux-test-harness.toml"
echo true > "$CONTENDER/setup.sh"
out="$(slot_contender 2>&1)"
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

step "share: a file the host writes stays as the host wrote it (#84)"
# The forwarder plugin's guest receiver opens every file an event names, writes
# its first byte back and sets its times, and truncates one it reads as empty.
# On a Mac that emptied a payload the host had just written. The oracle is the
# file itself, on the host: an event for it has long been delivered after three
# seconds, and a receiver would have moved a modification time set in the past.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
check_eq "$("$VM" run 'pgrep -fc "notify-forwarder receive"' 2>/dev/null)" 0 "no forwarder receiver runs in the guest"
left_alone="$("$VM" share)/.smoke-left-alone"
head -c 65536 /dev/urandom > "$left_alone"
touch -t 200001010000 "$left_alone"
want="$(mtime "$left_alone") $(sum "$left_alone")"
sleep 3
check_eq "$(mtime "$left_alone") $(sum "$left_alone")" "$want" "nothing in the guest has written to a file the host wrote"
rm -f "$left_alone"

step "overlay: what the guest deletes goes back to the host (#105)"
# The oracle is QEMU's monitor. A write takes more of the host's disk until the
# overlay is deleted with the boot, and a suite that wrote and removed a lot could
# fill a small runner: more, in total, than the guest has free is written here, a
# chunk at a time. Stops at the first chunk the overlay kept, because on a host
# short of disk carrying on is the very failure this checks for.
overlay_before="$(overlay_mib)"
check_true '[ -n "$overlay_before" ]' "QEMU's monitor measures the overlay: $overlay_before MiB" "QEMU's monitor did not give the overlay's size"
overlay_chunk=2048
overlay_limit=$((overlay_chunk / 4))
guest_free="$("$VM" run 'df -m --output=avail / | tail -n 1' 2>/dev/null | tr -d ' ')"
overlay_written=0
overlay_after="${overlay_before:-0}"
while [ "$overlay_written" -le "${guest_free:-0}" ] && [ $((overlay_after - ${overlay_before:-0})) -lt "$overlay_limit" ]; do
    "$VM" run "dd if=/dev/zero of=/var/tmp/flth-smoke-chunk bs=1M count=$overlay_chunk conv=fsync status=none; rm -f /var/tmp/flth-smoke-chunk; sync" 2>/dev/null ||
        { bad "writing and deleting a chunk failed in the guest"; break; }
    overlay_written=$((overlay_written + overlay_chunk))
    # The guest sends its discards when the commit that freed the blocks ends,
    # which `sync` can return ahead of, so the overlay gets a moment to shrink.
    overlay_waited=0
    while :; do
        overlay_after="$(overlay_mib)"
        overlay_after="${overlay_after:-0}"
        echo "  (after $overlay_written MiB and ${overlay_waited}s: $overlay_after MiB)"
        if [ $((overlay_after - ${overlay_before:-0})) -lt "$overlay_limit" ] || [ "$overlay_waited" -ge 30 ]; then
            break
        fi
        sleep 3
        overlay_waited=$((overlay_waited + 3))
    done
done
echo "  (wrote and deleted $overlay_written MiB, of $guest_free MiB free; the overlay went from $overlay_before to $overlay_after MiB)"
check_true '[ $((overlay_after - ${overlay_before:-0})) -lt "$overlay_limit" ]' \
    "the overlay gave back what the guest deleted" \
    "the overlay kept what the guest deleted: $overlay_before MiB grew to $overlay_after MiB after $overlay_written MiB written and deleted"
check_true '[ "$overlay_written" -gt "${guest_free:-0}" ]' \
    "and more was written than the guest has free" \
    "only $overlay_written MiB of the guest's $guest_free MiB free was written"

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
check_true 'case "$out" in *interrupted*) false ;; esac' "with no interruption reported" "apt still reports an interruption: $out"

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
ruby "$REPO/tests/exec-cost.rb" "$VM" "$CONTENDER"
check_eq "$?" 0 "exec meets its per-call budget and beats measured calls without SSH reuse"

step "a lost guest: the call says what stopped it (#105)"
# Paused through QEMU's own monitor, under a call that is running. ssh's keepalive
# gives up about two minutes later, as it did on the runner whose disk filled.
"$VM" exec 'sleep 600' > "$CONTENDER/lost.out" 2> "$CONTENDER/lost.err" &
lost_call=$!
sleep 5
monitor stop >/dev/null
check_eq "$?" 0 "QEMU's monitor pauses the guest under a running exec"
wait "$lost_call"
check_eq "$?" 255 "the call ends with ssh's own status"
lost="$(cat "$CONTENDER/lost.err")"
check_contains "$lost" "what stopped it: QEMU paused the guest" "and says QEMU paused the guest"
check_contains "$lost" "VM status: paused" "in the status QEMU's monitor gives"
check_contains "$lost" "free on the host's disk holding the overlay" "and what is free on the disk under it"
check_eq "$(cat "$CONTENDER/lost.out")" "" "and none of that is on stdout"
monitor cont >/dev/null
check_eq "$("$VM" run 'echo back' 2>/dev/null)" back "the guest carries on when QEMU lets it"

step "reload: the VM restarts in place and keeps its slot"
boot_before="$("$VM" run 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"
"$VM" reload
check_eq "$?" 0 "reload stops the VM and boots it again"
check_eq "$(state)" running "the VM is back"
check_eq "$(slot_holder)" flth-smoke "and holds the slot it held before"
boot_after="$("$VM" run 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"
check_true '[ -n "$boot_after" ] && [ "$boot_after" != "$boot_before" ]' "the guest really rebooted" \
    "the guest's boot id did not change across the reload ($boot_before, $boot_after)"

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

step "signal: a VM that stays up keeps its shares (#130)"
# Each call has a limit of its own: a dead share holds whatever reads it, in the
# guest and in the ssh waiting on it, for as long as anyone lets it. Answers go to
# a file: an ssh outliving its limit would hold a capture's pipe open.
bounded() { local limit="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$limit" "$@"; }
signal_dir="$CONTENDER/signal"
mkdir -p "$signal_dir"
# Not through `bounded`: a function run in the background is a subshell, and $! has
# to be the session itself for the signal below to reach it.
FLTH_KEEP_VM=1 perl -e 'alarm shift; exec @ARGV or exit 127' 1800 "$VM" session bash -c '
    "$1" up || exit
    sleep 600 &
    echo "$!" > "$2/descendant"
    : > "$2/ready"
    wait
' flth-signal "$VM" "$signal_dir" > "$signal_dir/session.log" 2>&1 &
signal_session=$!
while [ ! -e "$signal_dir/ready" ] && kill -0 "$signal_session" 2>/dev/null; do
    sleep 1
done
check_true '[ -e "$signal_dir/ready" ]' "the session's command boots the VM" "the session ended before its command had booted the VM"
kill -TERM "$signal_session" 2>/dev/null
wait "$signal_session"
check_eq "$?" 143 "a signalled session exits 143"
signal_descendant="$(cat "$signal_dir/descendant" 2>/dev/null)"
# By state, not `kill -0`: an ended process nothing has reaped yet still answers it.
case "$(ps -o stat= -p "${signal_descendant:-0}" 2>/dev/null)" in
    '' | *Z*) signal_survived=0 ;;
    *) signal_survived=1 ;;
esac
if [ -n "$signal_descendant" ] && [ "$signal_survived" = 0 ]; then
    ok "the command's descendant has ended"
else
    bad "the command's descendant survived the session"
fi
check_eq "$(state)" running "the VM stays up, as FLTH_KEEP_VM=1 asks"
signal_share="$("$VM" share)"
printf 'from the host\n' > "$signal_share/signal-marker"
bounded 120 "$VM" run 'timeout -s KILL 30 cat /share/signal-marker' > "$signal_dir/share" 2>/dev/null
check_eq "$(cat "$signal_dir/share")" "from the host" "/share still answers in the guest"
bounded 120 "$VM" run "timeout -s KILL 30 test -f $repo_guest/fs-linux-test-harness.toml && echo present" > "$signal_dir/repo" 2>/dev/null
check_eq "$(cat "$signal_dir/repo")" present "$repo_guest still answers in the guest"
bounded 120 "$VM" run "timeout -s KILL 30 sh -c 'echo from the guest > /share/signal-back'" > /dev/null 2>&1
check_eq "$(cat "$signal_share/signal-back" 2>/dev/null)" "from the guest" "and a write to /share still reaches the host"
rm -f "${signal_share:?}/signal-marker" "${signal_share:?}/signal-back"
bounded 600 "$VM" down
check_eq "$?" 0 "the VM it left stops"
check_eq "$(state)" not-running "and is down"

step "test: FLTH_KEEP_VM=1"
FLTH_KEEP_VM=1 "$VM" test
check_eq "$?" 0 "the suite passes"
check_eq "$(state)" running "and the VM is left running, as asked"

step "a lost guest: one that powers itself off (#105)"
"$VM" exec 'systemctl poweroff; sleep 300' > "$CONTENDER/poweroff.out" 2> "$CONTENDER/poweroff.err"
check_eq "$?" 255 "a call under a guest that powers itself off ends with ssh's own status"
lost="$(cat "$CONTENDER/poweroff.err")"
check_contains "$lost" "what stopped it: the guest powered itself off" "and says so, from the console"
check_contains "$lost" "[console]" "with the tail of the console"

step "boot signal: a boot that a signal stopped is not a VM to keep (#134)"
boot_signal_dir="$CONTENDER/boot-signal"
mkdir -p "$boot_signal_dir"
FLTH_KEEP_VM=1 perl -e 'alarm shift; exec @ARGV or exit 127' 1800 "$VM" session bash -c '
    "$1" up || exit
    : > "$2/booted"
    sleep 600
' flth-boot-signal "$VM" "$boot_signal_dir" > "$boot_signal_dir/session.log" 2>&1 &
boot_signal_session=$!
# The process table, not `status`: the signal has to land between QEMU starting
# and the shares being mounted, and `status` asks Vagrant until QEMU is up.
until ps -eo args= | awk -v want="$machine/vagrant/" '$1 ~ /qemu-system-/ && index($0, want) { found = 1 } END { exit !found }' ||
    ! kill -0 "$boot_signal_session" 2>/dev/null; do
    sleep 0.2
done
check_true '[ ! -e "$boot_signal_dir/booted" ]' "the signal lands during the boot" "the boot finished before the signal, so this says nothing"
kill -TERM "$boot_signal_session" 2>/dev/null
wait "$boot_signal_session"
check_eq "$?" 143 "a session signalled during a boot exits 143"
check_eq "$(state)" not-running "and leaves no guest without its shares, although FLTH_KEEP_VM=1 asks"
check_true '[ "$(slot_holder)" != flth-smoke ]' "and gives the slot back" "it kept the slot"
bounded 1800 "$VM" run "timeout -s KILL 30 findmnt -n /share > /dev/null && timeout -s KILL 30 findmnt -n $repo_guest > /dev/null && echo mounted" > "$boot_signal_dir/run" 2>/dev/null
check_eq "$(cat "$boot_signal_dir/run")" mounted "the next run boots a guest with /share and $repo_guest mounted"

step "down"
"$VM" down
check_eq "$?" 0 "vm.sh down succeeds"
check_eq "$(state)" not-running "the VM is confirmed stopped"
check_true '[ "$(slot_holder)" != flth-smoke ]' "and the slot released" "down left the slot held"

step "destroy"
"$VM" destroy
check_eq "$?" 0 "vm.sh destroy succeeds"
check_contains "$("$VM" status 2>&1)" "(absent)" "the VM no longer exists"
check_true '[ ! -e "$machine/cache.img" ]' "and its cache went with it" "destroy left $machine/cache.img behind"
check_artifacts_gone "$memory" destroy

step "an abrupt QEMU stop: the next boot reclaims abandoned memory"
"$VM" up
rc=$?
check_eq "$rc" 0 "the abrupt-stop guest boots"
boot_or_stop "$rc"
memory="$(qemu_memory)"
generation=""
if [ -n "$memory" ]; then generation="$(memory_stamp "$memory")"; fi
pid="$(qemu_process | awk '{print $1}')"
case "$pid" in
    '' | *[!0-9]*) bad "the smoke QEMU's pid could not be identified"; verdict; exit 1 ;;
esac
kill -KILL "$pid"
check_eq "$?" 0 "only the smoke QEMU is stopped abruptly"
attempt=0
while [ "$attempt" -lt 10 ]; do
    [ -z "$(qemu_process)" ] && break
    sleep 1
    attempt=$((attempt + 1))
done
check_eq "$(qemu_process)" '' "the abruptly stopped QEMU is gone"
"$VM" up
rc=$?
check_eq "$rc" 0 "a new boot follows the abrupt stop"
boot_or_stop "$rc"
if [ -n "$memory" ]; then
    replacement="$(memory_stamp "$(qemu_memory)")"
    if [ "$generation" != "$replacement" ]; then
        ok "the abandoned memory file was replaced, not reused"
    else
        bad "the next boot reused abandoned memory"
    fi
fi
"$VM" destroy
check_eq "$?" 0 "the abrupt-stop guest is destroyed"
check_artifacts_gone "$memory" 'destroy after abrupt stop'

step "kernel: the next boot runs the kernel a provisioning boot installed (#80)"
# The oracles are the guest's own: dpkg says which kernel the setup's package
# installed, and the running kernel says what it is. On Linux the guest's GRUB
# chooses it; on macOS the box starts QEMU on a kernel beside the box, and the
# harness has to carry the disk's across.
kernel_vm destroy >/dev/null 2>&1 || true
t0=$(date +%s)
kernel_vm up
rc=$?
check_eq "$rc" 0 "a setup that installs a kernel boots"
boot_or_stop "$rc"
echo "  (provisioning and the next boot took $(( $(date +%s) - t0 ))s)"
installed="$(kernel_vm run 'dpkg-query -W -f="\${Depends}" "linux-image-$(dpkg --print-architecture)"' 2>/dev/null | sed -n 's/^linux-image-\([^ ,|]*\).*/\1/p')"
check_true '[ -n "$installed" ]' "the guest's dpkg names the kernel the setup installed: $installed" "the guest's dpkg names no kernel for the setup's package"
check_eq "$(kernel_vm run 'uname -r' 2>/dev/null)" "$installed" "the guest runs it"
check_eq "$(kernel_vm run 'test -d "/lib/modules/$(uname -r)" && modprobe loop && echo loaded' 2>/dev/null)" loaded \
    "and loads a module from the tree it installed"
check_eq "$(kernel_vm run "findmnt -n -o TARGET /share; findmnt -n -o TARGET $repo_guest" 2>/dev/null | paste -sd, -)" "/share,$repo_guest" \
    "and both shares mount under it"
kernel_vm down
check_eq "$?" 0 "the VM stops"
kernel_vm up
rc=$?
check_eq "$rc" 0 "a later cold boot comes up"
boot_or_stop "$rc"
check_eq "$(kernel_vm run 'uname -r' 2>/dev/null)" "$installed" "and runs it too"
kernel_vm destroy
check_eq "$?" 0 "the second consumer's VM is destroyed"

trap - EXIT
rm -rf "$CONTENDER"
verdict
[ "$fails" -eq 0 ]
