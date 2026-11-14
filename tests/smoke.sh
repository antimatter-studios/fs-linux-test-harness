#!/usr/bin/env bash
#
# smoke.sh — the harness end to end, through a REAL VM.
#
# Boots the shared guest for tests/smoke-consumer on this host (KVM on Linux, HVF
# on macOS), as every consumer's is booted (#220), and checks every promise the
# harness makes against the machine itself:
#
#   up / setup    the shared guest boots, the consumer's setup installs its
#                 tooling inside it, the guest deadline is armed
#   attach        each run's tree is a virtiofs device attached to the running
#                 guest, and a session's is detached when it ends, its daemon
#                 after its device (#222)
#   disposable    a run that leaves a file, a loop device and a mount
#                 behind changes not one byte of the machine's disk, and
#                 the next boot sees none of it
#   cache         the declared cache is a directory of the guest's at /cache,
#                 and it goes with the boot like everything else (#186)
#   overlay       what the guest deletes goes back to the host: the overlay,
#                 as QEMU's monitor measures it, does not keep it (#105)
#   apt-ready     a held dpkg lock is found and named, as dpkg sees it
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
#   boot signal   a session signalled during a boot leaves no guest, and the
#                 next call has its shares (#134)
#   reload        the guest really reboots in place (#122)
#   hold / reap   the reaper leaves the shared guest up, held or not
#   signal        the guest stays up after a session is signalled and keeps
#                 /share and /repo, and the command's descendants still end
#                 (#130). A signal also stops the guest command that session
#                 started, what it moved to another process group, and nothing
#                 of another session's (#139)
#   poweroff      a guest that powers itself off leaves no forwarder when its
#                 session ends (#135)
#   short deadline a guest whose deadline is already in logind's last five minutes
#                 takes setup and new logins, then powers off on time (#150)
#   kernel        a consumer whose setup installs a kernel is refused, naming
#                 both kernels: the shared guest does not restart for it (#157)
#   test          a passing suite passes and the guest stays up; a CORRUPTED
#                 one FAILS with a non-zero exit
#   down/destroy  confirmed
#   shared guest  two consumers join one guest at once (tests/smoke-shared)
#
# The VM is destroyed on every exit path. The machine is in a cache directory of
# its own, so the shared guest the consumers on this host use is not touched.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONSUMER="$REPO/tests/smoke-consumer"
VM="$REPO/scripts/vm.sh"
# Which pinned guest boots: FLTH_SMOKE_GUEST, debian-12 by default, as every
# consumer's is. Each guest has its own copy of the consumer's config, the
# same but for `[vm] guest`, so CI boots every guest a consumer can pin (#70).
SMOKE_GUEST="${FLTH_SMOKE_GUEST:-debian-12}"
case "$SMOKE_GUEST" in
    debian-12)
        export FLTH_CONFIG="$CONSUMER/fs-linux-test-harness.toml"
        DEADLINE_CONFIG="$REPO/tests/smoke-deadline-consumer/fs-linux-test-harness.toml"
        ;;
    debian-13)
        export FLTH_CONFIG="$CONSUMER/fs-linux-test-harness.debian-13.toml"
        DEADLINE_CONFIG="$REPO/tests/smoke-deadline-consumer/fs-linux-test-harness.debian-13.toml"
        ;;
    *) echo "smoke: FLTH_SMOKE_GUEST must be debian-12 or debian-13, got '$SMOKE_GUEST'" >&2; exit 2 ;;
esac
unset FLTH_SHARED_DEADLINE
# A machine of the smoke run's own, beside the one this host's consumers share.
# chores.yml's net for a smoke run that never ends names the same directory.
export FLTH_CACHE_DIR="${FLTH_SMOKE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fs-linux-test-harness-smoke}"
# The shared machine's size, as a CI runner can give it.
export FLTH_SHARED_MEMORY=2G FLTH_SHARED_CPUS=2 FLTH_SHARED_DISK=16G
# Looks often enough to be seen here, with the limits as a consumer gets them.
export FLTH_WATCHDOG_INTERVAL=5

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

qemu_process() {
    local identity
    identity="$("$VM" config | sed -n 's/^identity=//p')"
    [ -n "$identity" ] || return 1
    ps -eo pid=,args= | awk -v want="$identity/" '$2 ~ /qemu-system-/ && index($0, want) > 0'
}
# A memory file the provider named; the harness's own backend is a directory, in
# which QEMU unlinks the file it makes, so there is nothing to reclaim (#222).
qemu_memory() {
    local path
    path="$(qemu_process | sed -n 's/.*mem-path=\([^, ]*\).*/\1/p')"
    [ -f "$path" ] && printf '%s\n' "$path"
    return 0
}
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

# A process naming the shared directory and the forwarder: on a Mac the watcher and,
# from plugin 0.7.7, the process supervising it. The stock provider on Linux starts
# neither. A stop takes a few seconds, so this waits for the count to reach 0. A
# shared guest of this host's consumers watches the same directory, so on a Mac it
# has to be down for this to answer for the smoke guest alone.
forwarders_left() {
    ps -axww -o command= |
        awk -v want="$CONSUMER" 'index($0, want) > 0 && /[n]otify-forwarder/ { n++ } END { print n + 0 }'
}
check_no_forwarders() {
    local left attempt=0
    left="$(forwarders_left)"
    while [ "$left" != 0 ] && [ "$attempt" -lt 10 ]; do
        sleep 1
        attempt=$((attempt + 1))
        left="$(forwarders_left)"
    done
    check_eq "$left" 0 "$1 leaves no forwarder naming the consumer running"
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
profile_active=0
profile_pids=""
profile_vm() {
    local consumer="$1"; shift
    FLTH_CONFIG="$CONTENDER/profile-$consumer/fs-linux-test-harness.toml" \
        FLTH_PROFILE_DIR="$CONTENDER/run-profiles" "$VM" "$@"
}
cleanup() {
    step "cleanup: destroy the smoke VM"
    "$VM" destroy >/dev/null 2>&1 || "$VM" destroy
    for profile_pid in $profile_pids; do
        kill -TERM "$profile_pid" 2>/dev/null || true
        wait "$profile_pid" 2>/dev/null || true
    done
    if [ "$profile_active" != 0 ]; then
        for profile_consumer in one two; do profile_vm "$profile_consumer" destroy >/dev/null 2>&1 || true; done
    fi
    rm -rf "$CONTENDER"
}
# The second consumer, whose setup installs a kernel (#157).
kernel_vm() { FLTH_CONFIG="$REPO/tests/smoke-kernel-consumer/fs-linux-test-harness.toml" "$VM" "$@"; }
# The third, on a guest whose deadline is five minutes (#150): the host's to set.
deadline_vm() { FLTH_SHARED_DEADLINE=5 FLTH_CONFIG="$DEADLINE_CONFIG" "$VM" "$@"; }
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
smoke_config="$("$VM" config)"
check_contains "$smoke_config" "machine=$FLTH_CACHE_DIR/machines/shared-$SMOKE_GUEST" "the machine is the shared guest's, named for its release"
check_contains "$(qemu_process)" "share=on" "guest memory is a shared backend, which a virtiofsd can reach"

step "attach: each run's tree is a device of its own (#222)"
# The oracles are QEMU's own QMP, the guest's findmnt, and the process
# table: what the harness says is attached has to be what QEMU and the guest have.
qmp="$(printf '%s\n' "$smoke_config" | sed -n 's/^qmp=//p')"
standing="$(printf '%s\n' "$smoke_config" | sed -n 's/^run.standing=//p')"
devices() { perl "$REPO/scripts/lib/qmp.pl" "$qmp" '{"execute":"qom-list","arguments":{"path":"/machine/peripheral"}}' 2>/dev/null; }
check_contains "$(devices)" "\"fs-$standing\"" "QEMU has the standing run's device"
check_eq "$("$VM" run "findmnt -n -o FSTYPE $repo_guest" 2>/dev/null)" virtiofs "and the run sees its tree at $repo_guest over virtiofs"
check_eq "$("$VM" run "findmnt -n -o SOURCE $repo_guest" 2>/dev/null)" "$standing" "tagged with its run id"
attach_dir="$CONTENDER/attach"
mkdir -p "$attach_dir"
attach_machine="$(printf '%s\n' "$smoke_config" | sed -n 's/^machine=//p')"
"$VM" session bash -c '
    "$1" run true || exit
    printf "%s\n" "$FLTH_RUN_ID" > "$2/run"
    sed -n "s/^pid //p" "$3/attached/$FLTH_RUN_ID" > "$2/pid"
    "$1" run "findmnt -n -o SOURCE '"$repo_guest"'" > "$2/source"
' flth-attach "$VM" "$attach_dir" "$attach_machine" 2>"$attach_dir/err"
check_eq "$?" 0 "a session runs on its own tree ($(tail -n 1 "$attach_dir/err"))"
session_run="$(cat "$attach_dir/run" 2>/dev/null)"
check_eq "$(cat "$attach_dir/source" 2>/dev/null)" "$session_run" "a device tagged with the session's run"
check_true '! devices | grep -q "\"fs-$session_run\""' "and when it ended its device was removed from QEMU" "its device is still in QEMU"
attach_pid="$(cat "$attach_dir/pid" 2>/dev/null)"
check_true '[ -n "$attach_pid" ] && ! kill -0 "$attach_pid" 2>/dev/null' "and its virtiofsd ($attach_pid) is gone" "its virtiofsd is still running"
check_contains "$(devices)" "\"fs-$standing\"" "while the standing run keeps its own"
check_eq "$("$VM" run hostname 2>/dev/null)" "shared-$SMOKE_GUEST" "the guest's hostname is the shared machine's name"
check_contains "$("$VM" run 'uname -a' 2>/dev/null)" "Linux shared-$SMOKE_GUEST" "uname -a runs in the guest"
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

step "watchdog: the guest's own tools answer it (#190)"
probe_out="$("$VM" run "$(cat "$REPO/vagrant/guest/watchdog-probe.sh")" 2>/dev/null)"
check_contains "$probe_out" "mem " "the probe reads the guest's memory"
check_contains "$probe_out" "disk " "and its disk"
attempt=0
until "$VM" status 2>/dev/null | grep -q 'vm: watchdog: .* ok: ' || [ "$attempt" -ge 24 ]; do
    sleep 5
    attempt=$((attempt + 1))
done
check_contains "$("$VM" status 2>&1)" "vm: watchdog:" "a watchdog started with the guest, and status shows what it sees"
check_contains "$("$VM" status 2>&1)" " ok: the guest answers" "and a guest doing nothing reads as ok"

step "disposable: what a run leaves behind goes with its boot"
# The oracles are the guest's own losetup and findmnt, and the disk's
# bytes: QEMU opens it read-only on a disposable boot, so a checksum taken
# while the VM runs must still hold once the run has written and stopped.
machine="$("$VM" config | sed -n 's/^machine=//p')"
disk="$(find "$machine" -name 'linked-box.img' 2>/dev/null | head -1)"
check_true '[ -f "$disk" ]' "the machine's disk is at $disk" "no linked-box.img under $machine"
sum() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | awk '{print $1}'; }
before="$(sum "$disk")"
cache_guest="$(sed -n 's/^FLTH_CACHE_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
check_eq "$("$VM" run "findmnt -n -o FSTYPE $cache_guest" 2>/dev/null)" "$("$VM" run 'findmnt -n -o FSTYPE /' 2>/dev/null)" \
    "the declared cache is mounted at $cache_guest, a directory of the guest's own disk"
check_true '[ ! -e "$machine/cache.img" ]' "and no disk of its own" "a cache disk was made under $machine"
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
echo "  (a cold boot and the setup took $(( $(date +%s) - t0 ))s)"
check_eq "$("$VM" run 'test -e /var/lib/flth-smoke-left-this && echo left || echo gone' 2>/dev/null)" gone "the file the run left is gone"
check_eq "$("$VM" run 'losetup -a | grep -c flth-smoke' 2>/dev/null)" 0 "and so is its loop device"
check_eq "$("$VM" run 'findmnt -n /mnt/flth-smoke >/dev/null && echo mounted || echo unmounted' 2>/dev/null)" unmounted "and its mount"
check_eq "$("$VM" run 'test -e /var/tmp/flth-smoke.img && echo kept || echo gone' 2>/dev/null)" gone "and the image behind them"
check_contains "$("$VM" run 'mkfs.ext4 -V 2>&1 | sed -n 1p' 2>/dev/null)" "mke2fs" "while the setup ran again on the new boot"
check_eq "$("$VM" run "cat $cache_guest/flth-smoke-kept-this 2>/dev/null || echo gone" 2>/dev/null)" gone \
    "and what the run left in the declared cache went with the boot too (#186)"

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

step "guest resource limits: automatic updates stay off and builds default to one job"
for unit in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service; do
    out="$("$VM" run "state=\$(systemctl is-enabled '$unit' 2>/dev/null || true); case \$state in ''|not-found) echo absent ;; masked) systemctl is-active --quiet '$unit' || echo masked-inactive ;; *) echo \$state ;; esac" 2>/dev/null)"
    case "$out" in
        absent | masked-inactive) ok "$unit cannot run automatically" ;;
        *) bad "$unit is not masked and inactive: $out" ;;
    esac
done
check_eq "$("$VM" run 'printf "%s" "${CARGO_BUILD_JOBS-unset}"' 2>/dev/null)" 1 'a real guest run exports one build job'
check_eq "$("$VM" exec 'printf "%s" "${CARGO_BUILD_JOBS-unset}"' 2>/dev/null)" 1 'a real guest exec exports one build job'
check_eq "$("$VM" run 'cat /share/setup-build-jobs' 2>/dev/null)" 1 'the real consumer setup receives one build job'
check_eq "$(CARGO_BUILD_JOBS=2 "$VM" run 'printf "%s" "${CARGO_BUILD_JOBS-unset}"' 2>/dev/null)" 2 'a real guest receives an explicit build override'

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

step "reload: the VM restarts in place"
boot_before="$("$VM" run 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"
"$VM" reload
check_eq "$?" 0 "reload stops the VM and boots it again"
check_eq "$(state)" running "the VM is back"
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
rm -f "$machine/keep-running"
"$VM" reap
check_eq "$(state)" running "reap leaves an unheld shared guest running too: it is there for the next run"
"$VM" down
check_eq "$(state)" not-running "and down, with nobody using it, stops it"

step "guest-test: the suite runs inside the guest"
"$VM" guest-test > "$CONTENDER/guest-test.log" 2>&1
rc=$?
sed 's/^/  guest-test: /' "$CONTENDER/guest-test.log" | tail -5
check_eq "$rc" 0 "vm.sh guest-test exits 0 for a passing in-guest suite"
check_contains "$(cat "$CONTENDER/guest-test.log")" "in-guest suite: $repo_guest as root" \
    "the command ran in the guest, from the repository mount"
check_contains "$(cat "$CONTENDER/guest-test.log")" 'in-guest build jobs: 1' 'the real guest-test inherits one build job'
check_eq "$(cat "$("$VM" share)/results/verdict" 2>/dev/null)" pass "and its results are on the share"
check_eq "$(state)" running "the guest stays up for the next run"

"$VM" guest-test corrupt > "$CONTENDER/guest-test-corrupt.log" 2>&1
rc=$?
check_true '[ "$rc" -ne 0 ]' "a corrupted image fails guest-test too (exit $rc)" "a corrupted in-guest run passed"

step "test: a passing suite"
"$VM" test
check_eq "$?" 0 "vm.sh test exits 0 for a passing suite"
results="$("$VM" share)/results"
check_eq "$(cat "$results/verdict" 2>/dev/null)" pass "the verdict collected on the host is pass"
check_contains "$(cat "$results/e2fsck.log" 2>/dev/null)" "Pass 5: Checking group summary information" "e2fsck ran to completion, and its log came back"
check_eq "$(state)" running "the guest stays up for the next run"

step "test: a corrupted image MUST fail"
"$VM" test corrupt
rc=$?
check_true '[ "$rc" -ne 0 ]' "vm.sh test exits non-zero ($rc) when the suite finds corruption" "a corrupted image passed"
check_eq "$(cat "$results/verdict" 2>/dev/null)" fail "the verdict collected on the host is fail"
check_contains "$(cat "$results/cmp.log" 2>/dev/null)" differ "because the content check found the flipped byte"

step "signal: a VM that stays up keeps its shares (#130)"
# Each call has a limit of its own: a dead share holds whatever reads it, in the
# guest and in the ssh waiting on it, for as long as anyone lets it. Answers go to
# a file: an ssh outliving its limit would hold a capture's pipe open.
bounded() { local limit="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$limit" "$@"; }
signal_dir="$CONTENDER/signal"
mkdir -p "$signal_dir"
# Not through `bounded`: a function run in the background is a subshell, and $! has
# to be the session itself for the signal below to reach it.
perl -e 'alarm shift; exec @ARGV or exit 127' 1800 "$VM" session bash -c '
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
check_eq "$(state)" running "the guest stays up for the next run"
signal_share="$("$VM" share)"
printf 'from the host\n' > "$signal_share/signal-marker"
bounded 120 "$VM" run 'timeout -s KILL 30 cat /share/signal-marker' > "$signal_dir/share" 2>/dev/null
check_eq "$(cat "$signal_dir/share")" "from the host" "/share still answers in the guest"
bounded 120 "$VM" run "timeout -s KILL 30 test -f $repo_guest/fs-linux-test-harness.toml && echo present" > "$signal_dir/repo" 2>/dev/null
check_eq "$(cat "$signal_dir/repo")" present "$repo_guest still answers in the guest"
bounded 120 "$VM" run "timeout -s KILL 30 sh -c 'echo from the guest > /share/signal-back'" > /dev/null 2>&1
check_eq "$(cat "$signal_share/signal-back" 2>/dev/null)" "from the guest" "and a write to /share still reaches the host"
rm -f "${signal_share:?}/signal-marker" "${signal_share:?}/signal-back"

step "signal: it stops the guest command it started, and only that (#139)"
# The oracle is the guest's own process table. Full command lines, so that no
# shell naming one of these in its arguments can answer. `timeout` moves itself and
# its child to a process group of their own, and is not the shell's last command,
# so the shell does not exec it.
guest_runs() { bounded 120 "$VM" run "pgrep -c -x -f '$1'" 2>/dev/null | tr -d ' \n'; }
guest_call_session() {
    perl -e 'alarm shift; exec @ARGV or exit 127' 600 "$VM" session bash -c '"$1" run "$2"' \
        flth-guest-call "$VM" "$1" >> "$signal_dir/guest-call.log" 2>&1 &
    guest_call=$!
}
wait_guest_runs() {
    # wait_guest_runs <full command line> <count>: bounded, in seconds
    local attempt=0
    while [ "$attempt" -lt 60 ] && [ "$(guest_runs "$1")" != "$2" ]; do
        sleep 1
        attempt=$((attempt + 1))
    done
    [ "$attempt" -lt 60 ]
}
guest_call_session 'timeout 900 sleep 1001; echo after'
signalled_call=$guest_call
guest_call_session 'sleep 1002'
other_call=$guest_call
check_true 'wait_guest_runs "sleep 1001" 1' "the first session's command is running in the guest" "the first session's command never showed in the guest"
check_true 'wait_guest_runs "sleep 1002" 1' "the second session's too" "the second session's command never showed in the guest"
kill -TERM "$signalled_call" 2>/dev/null
wait "$signalled_call"
check_eq "$?" 143 "a signalled session exits 143"
check_true 'wait_guest_runs "sleep 1001" 0' "its guest command has ended in the guest" "its guest command is still running in the guest"
check_eq "$(guest_runs "timeout 900 sleep 1001")" 0 "and so has the timeout that moved it to another group"
check_eq "$(guest_runs "sleep 1002")" 1 "the second session's command is still running"
check_eq "$(state)" running "the VM stays up"
kill -TERM "$other_call" 2>/dev/null
wait "$other_call"
check_true 'wait_guest_runs "sleep 1002" 0' "a signal to the second session stops its command" "the second session's command outlived its signal"

bounded 600 "$VM" down
check_eq "$?" 0 "the VM it left stops"
check_eq "$(state)" not-running "and is down"

step "poweroff: a guest that powers itself off leaves no forwarder (#135)"
poweroff_session='
    "$1" up || exit
    "$1" exec "systemctl poweroff" > /dev/null 2>&1
    attempt=0
    while [ "$attempt" -lt 120 ] && "$1" status > /dev/null 2>&1; do
        sleep 1
        attempt=$((attempt + 1))
    done
    "$1" status > /dev/null 2>&1 && exit 9
    exit 0
'
bounded 1800 "$VM" session bash -c "$poweroff_session" flth-poweroff "$VM"
check_eq "$?" 0 "a session whose guest powered itself off ends cleanly"
check_eq "$(state)" not-running "and the VM is down"
check_no_forwarders "a session ended on a powered-off guest"

step "test: the guest a run booted stays up"
"$VM" test
check_eq "$?" 0 "the suite passes"
check_eq "$(state)" running "and the guest it booted is left running for the next run"

step "a lost guest: one that powers itself off (#105)"
"$VM" exec 'systemctl poweroff; sleep 300' > "$CONTENDER/poweroff.out" 2> "$CONTENDER/poweroff.err"
check_eq "$?" 255 "a call under a guest that powers itself off ends with ssh's own status"
lost="$(cat "$CONTENDER/poweroff.err")"
check_contains "$lost" "what stopped it: the guest powered itself off" "and says so, from the console"
check_contains "$lost" "[console]" "with the tail of the console"

step "boot signal: a boot that a signal stopped is not a VM to keep (#134)"
boot_signal_dir="$CONTENDER/boot-signal"
mkdir -p "$boot_signal_dir"
perl -e 'alarm shift; exec @ARGV or exit 127' 1800 "$VM" session bash -c '
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
check_eq "$(state)" not-running "and leaves no guest without its shares"
bounded 1800 "$VM" run "timeout -s KILL 30 findmnt -n /share > /dev/null && timeout -s KILL 30 findmnt -n $repo_guest > /dev/null && echo mounted" > "$boot_signal_dir/run" 2>/dev/null
check_eq "$(cat "$boot_signal_dir/run")" mounted "the next run boots a guest with /share and $repo_guest mounted"

step "down"
"$VM" down
check_eq "$?" 0 "vm.sh down succeeds"
check_eq "$(state)" not-running "the VM is confirmed stopped"
check_no_forwarders "vm.sh down"

step "destroy"
"$VM" destroy
check_eq "$?" 0 "vm.sh destroy succeeds"
check_contains "$("$VM" status 2>&1)" "(absent)" "the VM no longer exists"
check_no_forwarders "vm.sh destroy"
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
check_no_forwarders "vm.sh destroy after an abrupt stop"

step "short deadline: the guest takes logins until it powers off on time (#150)"
# The oracles are the guest's own: logind writes /run/nologin for a poweroff less
# than five minutes away, sshd decides a login with it there, and logind's record
# says when the poweroff is. The status of `up` is the setup's first login. A new
# connection bypasses the harness's shared
# one, which sshd has already let in. How long the guest stays up is timed from the
# last call, whose start is the last re-arm: the rate limit is past by then.
deadline_vm destroy >/dev/null 2>&1 || true
deadline_vm up
rc=$?
check_eq "$rc" 0 "a five-minute deadline lets the setup finish"
boot_or_stop "$rc"
check_eq "$(deadline_vm run 'test -e /run/nologin && echo present' 2>/dev/null)" present \
    "the first command runs with logind's /run/nologin in place"
deadline_ssh() {
    ssh -F "$(deadline_vm config | sed -n 's/^machine=//p')/ssh-config" -o ControlPath=none -T default "$@"
}
check_eq "$(deadline_ssh 'sudo -n echo logged-in' 2>/dev/null </dev/null)" logged-in \
    "a new connection is let in and reaches root"
poweroff_due() { deadline_vm run 'sed -n "s/^USEC=//p" /run/systemd/shutdown/scheduled' 2>/dev/null; }
due_before="$(poweroff_due)"
sleep 65
due_after="$(poweroff_due)"
last_call=$(date +%s)
check_true '[ -n "$due_before" ] && [ -n "$due_after" ] && [ "$due_after" -gt "$due_before" ]' \
    "a call after the rate limit moves the poweroff in logind's record ($due_before to $due_after)" \
    "a call after the rate limit did not move the poweroff in logind's record ($due_before to $due_after)"
idle=0
while [ "$idle" -lt 480 ] && deadline_vm status >/dev/null 2>&1; do
    sleep 5
    idle=$(( $(date +%s) - last_call ))
done
check_true '! deadline_vm status >/dev/null 2>&1' "the guest stops by itself with nothing asking anything of it" "the guest was still up ${idle}s after its last call"
check_true '[ "$idle" -ge 280 ] && [ "$idle" -le 420 ]' \
    "it stops on time: ${idle}s after its last call, for a deadline of 300s" \
    "it stopped ${idle}s after its last call, for a deadline of 300s"
deadline_console="$(deadline_vm config | sed -n 's/^machine=//p')/console.log"
check_contains "$(tail -n 40 "$deadline_console" 2>/dev/null)" "Power down" "and its console records a power-off"
deadline_vm down
check_eq "$?" 0 "down clears up after a guest that powered itself off"
deadline_vm destroy
check_eq "$?" 0 "the five-minute guest is destroyed"

step "kernel: a setup that installs a kernel is refused on the shared guest (#157)"
# The shared guest does not restart for one consumer's setup, so its tests would run
# on the guest's kernel while the join reported success. The oracle is the guest's
# own /boot and `uname -r`, as the refusal names them.
kernel_vm destroy >/dev/null 2>&1 || true
t0=$(date +%s)
kernel_out="$(kernel_vm up 2>&1)"
rc=$?
echo "  (the boot and the setup took $(( $(date +%s) - t0 ))s)"
check_true '[ "$rc" -ne 0 ]' "the join of a consumer whose setup installs a kernel fails (exit $rc)" "it joined as if its kernel ran"
# Asked of that guest over its own SSH config, which the refusal does not stand in
# front of. Not as the smoke consumer: this consumer pins no guest, so it joins the
# default one, which is not the smoke consumer's on a debian-13 run.
running_kernel="$(ssh -F "$(kernel_vm config | sed -n 's/^machine=//p')/ssh-config" \
    -o ControlPath=none -T default 'uname -r' 2>/dev/null </dev/null)"
check_true '[ -n "$running_kernel" ]' "the guest answers uname -r" "the guest did not answer uname -r"
check_contains "$kernel_out" "this shared guest runs $running_kernel" "naming the kernel the guest runs"
check_contains "$kernel_out" "setup installed kernel " "and the one the setup installed"
profile_release="$(printf '%s\n' "$kernel_out" | sed -n 's/.*setup installed kernel \([^, ]*\),.*/\1/p' | head -n 1)"
kernel_out="$(kernel_vm exec true 2>&1)"
rc=$?
check_true '[ "$rc" -ne 0 ]' "and a later call of that consumer's is refused too" "a later call ran on the wrong kernel"
check_contains "$kernel_out" "setup installed kernel " "saying why"
kernel_vm destroy
check_eq "$?" 0 "that guest is destroyed"

# shellcheck source=tests/smoke-profiles/guest.sh
. "$REPO/tests/smoke-profiles/guest.sh"

# shellcheck source=tests/smoke-profiles/concurrent.sh
. "$REPO/tests/smoke-profiles/concurrent.sh"

# shellcheck source=tests/smoke-shared/guest.sh
. "$REPO/tests/smoke-shared/guest.sh"

trap - EXIT
rm -rf "$CONTENDER"
verdict
[ "$fails" -eq 0 ]
