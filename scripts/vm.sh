#!/usr/bin/env bash
#
# vm.sh — drive a consumer's Linux test VM.
#
#   vm.sh up               boot (idempotent) and apply the consumer's setup
#   vm.sh run <cmd...>     boot if needed, run a command as root in the guest
#   vm.sh exec <cmd...>    run a command in a guest that is ALREADY up
#   vm.sh put <file>       copy a file into the shared directory; print its guest path
#   vm.sh share            print the host path of the shared directory
#   vm.sh provision        boot if needed, re-run the setup script unconditionally
#   vm.sh reload           restart the shared guest in place, if nobody else is using it
#   vm.sh test [args...]   boot if needed, run the consumer's [test] command as a run of its own
#   vm.sh guest-test [args...]  boot if needed, run the [test] guest_command INSIDE the guest
#   vm.sh session <cmd...> run a command on the host inside a session: the VM comes down when it ends
#   vm.sh down             stop the shared guest and confirm it stopped, if nobody is using it
#   vm.sh status           exit 0 when the VM is running, 1 otherwise
#   vm.sh hold             keep the VM up: reap leaves it, the guest deadline is cancelled
#   vm.sh reap             stop a VM nothing cleaned up (the safety net)
#   vm.sh destroy          delete the shared guest and its disk, if nobody is using it
#   vm.sh config           print the resolved configuration
#
# NOT IN THE USAGE, AND NO CHORE TASK, ON PURPOSE: `session-begin <pid>`,
# `session-end <pid>`, `tree-lost <run>`, `run-id` and `guest-tree` are vm-session.sh's
# and guest-test's plumbing, the calls that make a session visible to the reaper,
# tell it whether there is a VM it may keep and set up a run on a shared guest.
# `up-boot` is the boot `up` starts in a process group of its own (vm_up). A
# person has no reason to run them, so
# they stay out of the list above, which is what tests/generic.sh reads as
# the public commands every one of which needs a task in vm.chores.yml.
#
# The consumer is found from fs-linux-test-harness.toml in the working
# directory or a parent, or from FLTH_CONFIG. See README.md.
#
# EVERY CONSUMER USES ONE GUEST, shared by every consumer on the host (#153, #220).
# It is kept running between invocations on purpose: booting is the slow part, and
# the next run, of this consumer or another, should not pay it again. What stops it
# is `down` with nobody using it, a boot that did not finish, the watchdog, and the
# guest's own poweroff deadline.
#
# WHAT A BOOT WRITES IS GONE WHEN IT STOPS. The machine's disk is the box's and
# carries nobody's setup: every boot is disposable (lib/engine.sh, engine_up), and
# each consumer's setup runs when it joins, on the boot it joined.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
. "$(dirname "$SELF")/lib/common.sh"

HOST_TOOLS="$FLTH_HARNESS/scripts/host-tools.sh"
BOOT_ATTEMPTS=3
BOOT_RETRY_WAIT=5
# How long a box that will not arrive is waited for, in seconds (boot_engine).
BOX_RETRY_BOUND=900
BOX_RETRY_FIRST_WAIT=30
BOX_RETRY_MAX_WAIT=120
# How much of the guest's console a failed boot prints (show_console).
CONSOLE_TAIL_LINES=60
# What a lost connection prints of it: several calls can lose the guest at once.
LOST_GUEST_CONSOLE_LINES=20
LOST_GUEST_TRIES=5
LOST_GUEST_RETRY_WAIT=3

usage() {
    sed -n '3,20p' "$SELF" | sed 's/^# \{0,1\}//'
}

# Say what the host is missing before trying to boot. Without this the
# first symptom is an engine error naming a plugin, or a guest that
# imports and never boots.
require_host_tools() {
    if ! "$HOST_TOOLS" --quiet; then
        echo "vm: the VM cannot start until the host tools above are installed." >&2
        exit 1
    fi
}

# `boot` applies the setup only when the guest does not carry the script yet;
# `force` (`vm.sh provision`) re-applies it regardless.
PROVISION_MODE=boot

# What started this process. The boot `up` starts is a process of its own and is
# handed its caller's, so what it records names the same invocation (vm_up).
VM_PARENT="$PPID"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Run the consumer's setup script inside the guest.
#
#   boot    run it unless the guest records this exact script as
#           already applied on this boot
#   force   run it regardless
#
# The guest's stamp is the authority: it lives with the boot the tooling
# was installed on, and goes with it.
#
# The script travels base64-encoded inside the command, so nothing in it
# can be mistaken for the end of anything, and it runs with stdin from
# /dev/null so an `apt-get` inside cannot swallow what follows. Its output
# goes to stderr, so the stdout of `vm.sh run` is only the command's.
apply_setup() {
    local mode="$1" script hash guest force=0 payload out rc stamp take_turn with_tree
    # The setup reads this consumer's tree, which is the run's device.
    shared_attach || return
    script="$FLTH_ROOT/$CFG_setup_script"
    hash="$(sha256_of "$script")" || return
    [ "$mode" = force ] && force=1
    payload="$(base64 < "$script")" || return

    # ON THE SHARED GUEST each consumer has a stamp of its own and its setup runs with
    # its own tree. Two setups at once would collide on the package manager's lock,
    # and nothing merges them, so they take turns. The stamp is read again after the
    # wait: another suite of this consumer may have applied it. They install
    # alongside each other.
    #
    # A SHARED GUEST DOES NOT RESTART FOR ONE CONSUMER (#157). A setup that installs a
    # kernel the guest is not running would leave that consumer's kernel tests on the
    # wrong kernel while its join reported success. So the kernels in /boot are
    # compared before and after it, and a new one that is not the running kernel is
    # recorded for this consumer: this join and every later one on this boot refuse,
    # naming both. Another consumer's join is not affected.
    local kernel_check kernel_after
    stamp="/var/lib/fs-linux-test-harness/setup-$CFG_project_name.sha256"
    kernel_check="kernel_record=/var/lib/fs-linux-test-harness/setup-$CFG_project_name.kernel
running=\"\$(uname -r)\"
kernels() { local k; for k in /boot/vmlinuz-*; do [ -e \"\$k\" ] && printf '%s\\n' \"\${k##*/vmlinuz-}\"; done; return 0; }
refuse_kernel() { [ -s \"\$kernel_record\" ] || return 0; echo \"kernel \$(cat \"\$kernel_record\") \$running\"; exit 0; }
kernels_before=\"\$(kernels)\""
    take_turn="exec 9> $FLTH_GUEST_RUNS/setup.lock
flock -n 9 || { echo '[vm] waiting for another consumer'\\''s setup to finish' >&2; flock 9; }
if [ $force = 0 ] && [ \"\$(cat \"\$stamp\" 2>/dev/null || true)\" = '$hash' ]; then
    refuse_kernel
    exit 0
fi
kernels_before=\"\$(kernels)\""
    kernel_after="installed=\"\$(kernels | grep -Fxv -f <(printf '%s\\n' \"\$kernels_before\") | grep -Fxv \"\$running\" | tail -n 1 || true)\"
if [ -n \"\$installed\" ]; then
    mkdir -p \"\$(dirname \"\$kernel_record\")\"
    printf '%s\\n' \"\$installed\" > \"\$kernel_record\"
fi"
    with_tree="bash $FLTH_GUEST_RUNS/run.sh setup $(shared_run_places)"

    guest="set -euo pipefail
stamp=$stamp
$kernel_check
if [ $force = 0 ] && [ \"\$(cat \"\$stamp\" 2>/dev/null || true)\" = '$hash' ]; then
    refuse_kernel
    exit 0
fi
$take_turn
echo '[vm] running setup script $CFG_setup_script' >&2
tmp=\"\$(mktemp)\"
printf '%s\n' '$payload' | base64 -d > \"\$tmp\"
FLTH_PROJECT='$CFG_project_name' FLTH_SHARE='$FLTH_SHARE_GUEST' $with_tree bash \"\$tmp\" </dev/null 9>&- >&2
rm -f \"\$tmp\"
mkdir -p \"\$(dirname \"\$stamp\")\"
printf '%s\n' '$hash' > \"\$stamp\"
$kernel_after
refuse_kernel
echo applied"

    rc=0
    # Through guest_call_held, so the call re-arms the guest's deadline as it starts
    # and as it ends (#150): a setup that ends just inside a short deadline still
    # leaves the whole of it to reach the first command.
    out="$(guest_call_held "$guest")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "vm: the setup script ($CFG_setup_script) failed inside the VM." >&2
        echo "    The VM is left running so it can be inspected; 'chore vm:down' stops it." >&2
        exit 1
    fi
    case "$out" in
        'kernel '*)
            # shellcheck disable=SC2086  # "kernel <installed> <running>"
            set -- $out
            printf '%s\n' "$2" > "$(shared_kernel_record)"
            shared_kernel_explain "$2" "$3"
            exit 1
            ;;
    esac
    return 0
}

# The consumer's refusal on this boot of a shared guest, for the calls after a join.
shared_kernel_record() { printf '%s/kernel-refused-%s\n' "$FLTH_MACHINE_DIR" "$CFG_project_name"; }
shared_kernel_explain() {
    echo "vm: $CFG_project_name's setup installed kernel $1, and this shared guest runs $2." >&2
    echo "    The shared guest does not restart for one consumer's setup, so its tests would run on $2." >&2
    echo "    Every consumer uses this guest: a setup that installs a kernel cannot be run on it (#207)." >&2
}

# ONE UP AT A TIME PER MACHINE. A test process that runs its oracle tests
# in parallel calls `up` from several threads at once; while the first
# boot is under way the VM is not yet running, so every later caller
# decided to boot it too, and QEMU refused the second forward of the same
# port, failing a consumer's oracle tier. The lock is a directory, made
# atomically, holding its owner's pid: a later `up` waits for it, then
# reads the state afresh and finds the VM running. An owner that died
# leaves a lock whose pid is gone, which the next caller takes over.
UP_LOCK_WAIT_SECS="${FLTH_UP_LOCK_WAIT_SECS:-2700}"
# Whether this process holds the lock, so that what it calls does not wait for itself.
UP_LOCK_HELD=0

up_lock_take() {
    local waited=0 owner
    mkdir -p "$FLTH_MACHINE_DIR"
    until up_lock_try; do
        if [ "$waited" -ge "$UP_LOCK_WAIT_SECS" ]; then
            owner="$(cat "$FLTH_MACHINE_DIR/up.lock/pid" 2>/dev/null || true)"
            echo "vm: another up of this machine (pid ${owner:-unknown}) has held it for ${waited}s; not booting beside it." >&2
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# Take the lock if no live process holds it.
up_lock_try() {
    local lock="$FLTH_MACHINE_DIR/up.lock" owner
    until mkdir "$lock" 2>/dev/null; do
        owner="$(cat "$lock/pid" 2>/dev/null || true)"
        if [ -z "$owner" ] || kill -0 "$owner" 2>/dev/null; then
            return 1
        fi
        rm -rf "$lock"
    done
    echo "$$" > "$lock/pid"
    UP_LOCK_HELD=1
    trap 'rm -rf "$FLTH_MACHINE_DIR/up.lock"' EXIT
}

# Held only while up decides and boots: `run` comes through up on every
# call, and parallel runs on a VM that is up must not queue behind each
# other. The EXIT trap covers up's own `exit` paths.
up_lock_drop() {
    rm -rf "$FLTH_MACHINE_DIR/up.lock"
    UP_LOCK_HELD=0
    trap - EXIT
}

# A BOOT THAT DID NOT FINISH IS NOT A VM (#134). QEMU daemonizes early in a boot
# and the shares are mounted late, so a signal between the two ends the boot and
# leaves a guest with /share and /repo never mounted. It answers ssh and its state
# reads running, so a run against it exits 0 having seen empty directories. Measured
# on an Apple Silicon host with a session that kept its VM.
#
# So a marker exists from before a boot starts until the engine says it finished,
# and is written and removed under the up lock. A marker with no live process
# holding that lock is a boot that stopped short, however it stopped: a signal, a
# KILL or three failed attempts. Nothing keeps what it left: a session's end and the
# reaper stop it whatever would have kept a VM, and `up` replaces it.
unfinished_boot_marker() { printf '%s/boot-unfinished\n' "$FLTH_MACHINE_DIR"; }

# THE WATCHDOG (scripts/vm-watchdog.sh, #190). In a session of its own, so a signal to
# what booted the guest does not reach it, and holding nothing of its caller's open:
# the up lock's descriptors are how a dead `up` is noticed.
WATCHDOG_STATUS=75
watchdog_record() { printf '%s/watchdog-ended\n' "$FLTH_MACHINE_DIR"; }
watchdog_told() { printf '%s/watchdog-told\n' "$FLTH_MACHINE_DIR"; }

watchdog_start() {
    [ "${FLTH_WATCHDOG:-on}" != off ] || return 0
    watchdog_stop
    rm -f "$(watchdog_record)"
    # The parent records the pid before it exits, so a stop straight after this finds it.
    perl -MPOSIX -e '
        my $record = shift;
        my $child = fork;
        if ($child) { open my $file, ">", $record or exit 1; print {$file} "$child\n"; close $file; exit 0; }
        POSIX::setsid();
        exec @ARGV or exit 127;
    ' "$FLTH_MACHINE_DIR/watchdog.pid" bash "$FLTH_HARNESS/scripts/vm-watchdog.sh" \
        </dev/null >/dev/null 2>&1 5<&- 6>&- 7<&- 8>&- 9>&- || true
}

watchdog_stop() {
    local pid
    pid="$(cat "$FLTH_MACHINE_DIR/watchdog.pid" 2>/dev/null || true)"
    rm -f "$FLTH_MACHINE_DIR/watchdog.pid"
    case "$pid" in '' | *[!0-9]*) return 0 ;; esac
    # A pid on record can belong to something else by now.
    case "$(ps -o args= -p "$pid" 2>/dev/null || true)" in
        *vm-watchdog.sh*) kill -TERM "$pid" 2>/dev/null || true ;;
    esac
}

# The reason a watchdog gave, for whatever asks after it ended the guest.
watchdog_explain() {
    local reason="$1"
    echo "vm: the watchdog ended this guest: $reason." >&2
    echo "    This is not a failure of the suite: it could not finish. Run it again; the next call boots a new guest." >&2
}

# Called by the watchdog. The record goes first, so anything that loses the guest from
# here on can say why. The guest is forced down, since a graceful stop waits on what
# is stuck, and the suites are stopped once it has gone, so that none of them boots
# another guest in its place.
vm_watchdog_end() {
    local reason="$1" marker pid start have_lock=0 pids="" told
    told="$(watchdog_told)"
    printf '%s\n' "$reason" > "$(watchdog_record)"
    mkdir -p "$told"
    for marker in "$(sessions_dir)"/*; do
        [ -f "$marker" ] || continue
        IFS=$'\t' read -r pid start _ < "$marker" || true
        case "$pid" in '' | *[!0-9]*) continue ;; esac
        [ "$(process_start "$pid" || true)" = "$start" ] || continue
        printf '%s\n' "$reason" > "$told/$pid"
        pids="$pids $pid"
    done
    if up_lock_try; then have_lock=1; fi
    rm -f "$FLTH_MACHINE_DIR/watchdog.pid"
    engine_down --force >/dev/null 2>&1 || true
    confirmed_stopped || true
    [ "$have_lock" = 0 ] || up_lock_drop
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
}

# THE WATCHDOG FOUND A RUN'S virtiofsd GONE (#222): its device goes before anything
# else runs there, then the run ends, and the suites on that run are told why and
# stopped, as for a guest the watchdog ends. Other runs are not touched.
vm_tree_lost() {
    local run="$1" attached=0 marker pid start told reason
    engine_tree_attached "$run" || attached=$?
    [ "$attached" = 3 ] || return 0
    reason="the virtiofsd serving run $run's tree has gone"
    told="$(watchdog_told)"
    mkdir -p "$told"
    engine_detach_tree "$run" || true
    engine_run "bash $FLTH_GUEST_RUNS/run.sh end $run" >&2 || true
    for marker in "$(sessions_dir)"/*; do
        [ -f "$marker" ] || continue
        [ "$(cut -f4 "$marker" 2>/dev/null || true)" = "$run" ] || continue
        IFS=$'\t' read -r pid start _ < "$marker" || true
        case "$pid" in '' | *[!0-9]*) continue ;; esac
        [ "$(process_start "$pid" || true)" = "$start" ] || continue
        printf '%s\n' "$reason" > "$told/$pid"
        kill -TERM "$pid" 2>/dev/null || true
    done
}

# Asked by a session as it ends: prints `told`, having said why on stderr, if the
# watchdog ended it. Printed rather than a status, so that only a yes is a yes.
vm_watchdog_told() {
    local file
    file="$(watchdog_told)/$1"
    [ -f "$file" ] || return 0
    watchdog_explain "$(cat "$file")"
    rm -f "$file"
    echo told
}

boot_vm() {
    : > "$(unfinished_boot_marker)" || return
    boot_engine || return
    shared_prepare_guest || return
    shared_boot_identity > "$(shared_boot_record)" || return
    # A refusal is for the boot that holds the kernel it named.
    local refused
    for refused in "$FLTH_MACHINE_DIR"/kernel-refused-*; do
        [ ! -f "$refused" ] || rm -f "$refused"
    done
    rm -f "$(unfinished_boot_marker)"
}

boot_stopped_short() {
    local owner
    [ -f "$(unfinished_boot_marker)" ] || return 1
    owner="$(cat "$FLTH_MACHINE_DIR/up.lock/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        return 1
    fi
    return 0
}

# Stop what a boot that stopped short left. Returns 1 with nothing done when no boot
# stopped short, or when an `up` has taken the machine, which then replaces the
# guest itself. The lock keeps an `up` from booting while this stops it.
stop_unfinished_boot() {
    local alive=0
    boot_stopped_short || return 1
    up_lock_try || return 1
    if [ ! -f "$(unfinished_boot_marker)" ]; then
        up_lock_drop
        return 1
    fi
    engine_alive "$(engine_identity)" || alive=$?
    if [ "$alive" -eq 1 ]; then
        rm -f "$(unfinished_boot_marker)"
    else
        echo "[vm] stopping $CFG_project_name: its boot did not finish, so it has no shares and nothing keeps it." >&2
        vm_down
    fi
    up_lock_drop
}

# Every caller but `run` and `up`, which replace the guest: nothing is run on it.
refuse_unfinished_boot() {
    [ -f "$(unfinished_boot_marker)" ] || return 0
    echo "vm: $CFG_project_name's last boot did not finish, or is still running, so its guest has no shares." >&2
    echo "    Nothing ran. 'chore vm:up' replaces it." >&2
    exit 1
}

# A PROCESS GROUP IS MADE FROM ONE SIDE (#209). Job control (`set -m`) makes a
# background job's group from both sides at once, the shell and the child, as
# POSIX asks; on macOS the two calls race, the child's fails with EPERM although
# the group is made, and Bash prints "child setpgid ... Operation not permitted"
# into the caller's stderr. So the boot and the escalation below are started by
# Perl, which makes the group in the child alone and then runs them. The group
# exists only once the child has made it, so until then the boot is signalled by
# its pid. Job control a caller turned on is off while they start.
UP_OWN_GROUP='$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0) or die "vm: the boot has no process group of its own: $!\n"; exec { $ARGV[0] } @ARGV or die "vm: could not start the boot: $!\n"'
# Escalation: KILL to what is left of the group after 50 ticks of 0.1 seconds. By
# the pid only while the group has not been seen: once it has, the pid is its.
UP_KILLER='setpgrp(0, 0); my ($child, $seen) = (shift, 0);
for (1 .. 50) {
    if (kill 0, -$child) { $seen = 1 } elsif ($seen || !kill 0, $child) { last }
    select undef, undef, undef, 0.1;
}
kill "KILL", -$child;
kill "KILL", $child unless $seen;'

up_forward() {
    up_signalled="$1"
    [ -n "$up_child" ] || return 0
    kill -"$2" -- "-$up_child" 2>/dev/null || kill -"$2" "$up_child" 2>/dev/null || true
    [ -z "$up_killer" ] || return 0
    local monitor=0
    case "$-" in *m*) monitor=1 && set +m ;; esac
    (
        trap '' HUP INT TERM
        exec perl -e "$UP_KILLER" "$up_child"
    ) >/dev/null 2>&1 6>&- &
    up_killer=$!
    [ "$monitor" = 0 ] || set -m
}

vm_up() {
    local rc=0 up_child='' up_killer='' up_signalled=0 monitor=0
    up_lock_take
    trap 'up_forward 129 HUP' HUP
    trap 'up_forward 130 INT' INT
    trap 'up_forward 143 TERM' TERM
    mkfifo "$FLTH_MACHINE_DIR/up.lock/owner" || return
    exec 6<> "$FLTH_MACHINE_DIR/up.lock/owner"
    exec 5< "$FLTH_MACHINE_DIR/up.lock/owner"
    rm -f "$FLTH_MACHINE_DIR/up.lock/owner"
    case "$-" in *m*) monitor=1 && set +m ;; esac
    if [ "$up_signalled" = 0 ]; then
        perl -e "$UP_OWN_GROUP" "$BASH" "$SELF" up-boot "$PROVISION_MODE" "$VM_PARENT" 0<&0 6>&- &
        up_child=$!
    fi
    exec 5<&-
    [ "$monitor" = 0 ] || set -m
    if [ "$up_signalled" != 0 ] && [ -n "$up_child" ]; then
        case "$up_signalled" in
            129) up_forward 129 HUP ;;
            130) up_forward 130 INT ;;
            143) up_forward 143 TERM ;;
        esac
    fi
    if [ -n "$up_child" ]; then
        while :; do
            wait "$up_child" || rc=$?
            kill -0 "$up_child" 2>/dev/null || break
        done
    fi
    if [ -n "$up_killer" ]; then
        while kill -0 "$up_killer" 2>/dev/null; do
            wait "$up_killer" || true
        done
    fi
    exec 6>&-
    trap '' HUP INT TERM
    if [ "$up_signalled" != 0 ]; then
        rc="$up_signalled"
        if [ -f "$(unfinished_boot_marker)" ]; then
            vm_down
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        confirmed_stopped || true
    fi
    up_lock_drop
    trap - HUP INT TERM
    if [ "$rc" -eq 0 ]; then
        # Outside the lock: a consumer's setup can take many minutes, and nothing
        # about another suite joining depends on it. The guest serialises them.
        apply_setup "$([ "$PROVISION_MODE" = force ] && echo force || echo boot)" || rc=$?
    fi
    return "$rc"
}

# The boot `up` starts (`up-boot <provision mode> <up's caller>`), in a process group
# of its own: what a signal to `up` is passed to. Descriptor 5 is the read end of
# the up lock's owner FIFO, whose writer is `up`: when `up` is gone, however it
# went, the watcher reads end-of-file and stops the boot.
vm_up_boot() {
    local rc=0 watcher
    PROVISION_MODE="$1"
    VM_PARENT="$2"
    (
        trap 'exit 0' TERM
        read -r _ || {
            trap '' HUP INT TERM
            kill -TERM 0 2>/dev/null || true
            command -p sleep 5
            kill -KILL 0 2>/dev/null || true
        }
    ) <&5 >/dev/null 2>&1 &
    watcher=$!
    exec 5<&-
    vm_up_locked || rc=$?
    kill -TERM "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    exit "$rc"
}

vm_up_locked() {
    local state
    state="$(engine_state)" || return
    if [ "$state" = running ] && [ -f "$(unfinished_boot_marker)" ]; then
        echo "[vm] $CFG_project_name's last boot did not finish, so its guest has no shares: replacing it." >&2
        vm_down
        state="$(engine_state)" || return
    fi
    case "$state" in
        running)
            # No host-tool check on this path: `run` comes through here on
            # every call, and a VM that is up needs nothing installed. The
            # setup is vm_up's, after the lock.
            refuse_other_boot
            return 0
            ;;
        unknown)
            # A missing engine is the likeliest reason a state cannot be
            # read, so say that first if it is so. Then refuse: booting on
            # a state nobody could read can start a duplicate VM outside
            # the configured limit.
            require_host_tools
            echo "vm: could not read the VM's state; not booting until it can be read." >&2
            exit 1
            ;;
    esac
    require_host_tools

    # The guest's disk carries nobody's setup: each consumer's runs when it joins,
    # on the boot it joined, and goes with that boot.
    echo "[vm] booting the shared guest for $CFG_project_name (a first boot downloads the box)..." >&2
    boot_vm
}

# THE GUEST'S CONSOLE, WHEN A BOOT FAILS (#61). A boot that never
# answers SSH times out saying only that; what the guest printed on its
# serial console (a kernel panic, a root that never mounted, a network
# that never came up) is the one account of why. Its tail goes to stderr,
# every line labelled, so a CI log keeps it beside the failure.
show_console() {
    local log lines="${1:-$CONSOLE_TAIL_LINES}"
    log="$(engine_console_log)"
    if [ ! -s "$log" ]; then
        echo "[vm] no console output in $log: the guest wrote nothing to its serial console" >&2
        return 0
    fi
    echo "[vm] the guest's console, the last $lines lines of $log:" >&2
    tail -n "$lines" "$log" | tr -d '\r' | sed 's/^/[console] /' >&2
}

# A LOST CONNECTION SAYS WHAT STOPPED THE GUEST (#105). ssh's own failures are
# status 255, Vagrant's settings carry `LogLevel FATAL` so ssh prints nothing about
# them, and the teardown that follows frees whatever could have told why. A guest
# paused on a full host disk ended a consumer's run with a bare 255, two minutes
# after QEMU had stopped it. So this looks while there is something to look at:
#
#   QEMU's process     gone: powered off if the console says so, otherwise killed
#   QEMU's monitor     paused: a failed write when its status says so
#   the guest          no answer: hung or crashed
#
# A script may exit 255 too, and ssh cannot tell the two apart, so a guest that
# answers is reported as both. All of it is on stderr and the status is not
# touched: a consumer may read either. Status 255 is the only one that costs this.
report_lost_guest() {
    local alive=0 status="" answered=0 tries=0 console free dir overlay
    echo "vm: exit 255: ssh lost its connection to the guest, or the command itself exited 255." >&2

    # A guest shutting down drops its connections a moment before QEMU ends. A
    # look at that moment finds QEMU running and a guest that does not answer,
    # which is not a hang, so that answer has to hold before it is believed.
    while :; do
        alive=0
        engine_alive "$(engine_identity)" || alive=$?
        [ "$alive" -eq 0 ] || break
        status="$(engine_vm_status)" || status=""
        case "$status" in *'VM status: paused'*) break ;; esac
        if engine_guest_answers; then
            answered=1
            break
        fi
        tries=$((tries + 1))
        [ "$tries" -lt "$LOST_GUEST_TRIES" ] || break
        sleep "$LOST_GUEST_RETRY_WAIT"
    done

    console="$(tail -n "$LOST_GUEST_CONSOLE_LINES" "$(engine_console_log)" 2>/dev/null || true)"
    if [ "$alive" -eq 2 ]; then
        echo "vm: what stopped it: unknown; the process table could not be read." >&2
    elif [ "$alive" -ne 0 ]; then
        case "$console" in
            *'Power down'* | *'System halted'*)
                echo "vm: what stopped it: the guest powered itself off; QEMU then ended." >&2 ;;
            *)
                echo "vm: what stopped it: QEMU ended and the guest's console records no power-off: it was killed or it crashed." >&2 ;;
        esac
    else
        case "$status" in
            *'VM status: paused'*)
                echo "vm: what stopped it: QEMU paused the guest." >&2
                case "$status" in
                    *'io-error'* | *'I/O status: '*)
                        echo "vm: a write to the guest's disk failed. The overlay grows on the host's disk, and a full host disk stops a guest this way." >&2 ;;
                esac
                ;;
            *)
                if [ "$answered" = 1 ]; then
                    echo "vm: what stopped it: not the guest: it is up and answers, so ssh lost its connection, or the command itself exited 255." >&2
                else
                    echo "vm: what stopped it: QEMU is running and the guest does not answer: it hung or it crashed." >&2
                fi
                ;;
        esac
        if [ -n "$status" ]; then
            printf '%s\n' "$status" | grep -v '^overlay: ' | sed 's/^/vm: QEMU says: /' >&2
        else
            echo "vm: QEMU's monitor did not answer." >&2
        fi
    fi

    dir="$(engine_overlay_dir)"
    free="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }')"
    overlay="$(printf '%s\n' "$status" | sed -n 's/^overlay: //p')"
    if [ -n "$free" ]; then
        echo "vm: $free MB free on the host's disk holding the overlay ($dir)${overlay:+; the overlay is $overlay}." >&2
    fi
    show_console "$LOST_GUEST_CONSOLE_LINES"
    if [ "$answered" = 0 ]; then
        echo "vm: this guest is shared, so every suite using it lost it too: $(shared_suites)." >&2
    fi
}

# A call into the guest. Keeps its status, and reports when that is ssh's own.
guest_run() {
    shared_attach || return
    guest_call_held "$(guest_call_script "$1")"
}

# The same, outside any run of a shared guest. A setup is what makes the tools every
# run uses, and it enters a namespace of its own (`run.sh setup`), so it must not go
# through a run, whose private directories would keep what it installs (#150).
guest_call_held() {
    local rc=0 script
    script="$(guest_call "$1")" || return
    engine_run_held "$script" || rc=$?
    [ "$rc" -ne 255 ] || report_lost_guest
    if [ "$rc" -eq 255 ] && [ -f "$(watchdog_record)" ]; then
        watchdog_explain "$(cat "$(watchdog_record)")"
        rc="$WATCHDOG_STATUS"
    fi
    return "$rc"
}

# Boot, retrying.
#
# RETRIED, because the forwarded SSH port is not always free the instant
# a previous machine stops (`Could not set up host forwarding rule`).
# Waiting for the port to look free does not work — `lsof` reports it
# free while QEMU still cannot bind it — so the retry is where the
# failure happens, and covers causes nobody has guessed.
#
# A BOX THAT DID NOT ARRIVE IS NOT A BOOT THAT FAILED (#145). A catalog outage
# outlasts three attempts five seconds apart, and one threw away a merge queue
# run that had taken hours. So it is waited for over minutes, on a count of its
# own, and reported as what it was: no VM started, so there is no console to show
# and nothing to force down. A boot failure keeps the retries above.
#
# THE WAIT FITS INSIDE WHAT IS WAITING ON IT: well inside the up lock's wait
# (FLTH_UP_LOCK_WAIT_SECS) and the shortest job limit around a first boot in the
# family, 45 minutes. The time an attempt takes counts, so a catalog that fails
# slowly is bounded too.
#
# THE HOST'S MEMORY IS MEASURED BEFORE EACH ATTEMPT. A guest asks for gigabytes,
# and a full machine does not fail cleanly: it kills background work with no
# message connecting the two. So a boot the host has no room for is refused,
# naming the numbers.
boot_engine() {
    local attempt=1 box_spent=0 box_wait="$BOX_RETRY_FIRST_WAIT" failure started up_rc
    while :; do
        if ! host_memory_check; then
            confirmed_stopped || true
            return 1
        fi
        mkdir -p "$FLTH_MACHINE_DIR" || return
        started="$SECONDS"
        up_rc=0
        engine_up || up_rc=$?
        if [ "$up_rc" = 0 ]; then
            watchdog_start
            return 0
        fi
        if failure="$(engine_box_failure)"; then
            box_spent=$((box_spent + SECONDS - started))
            if [ "$box_spent" -ge "$BOX_RETRY_BOUND" ]; then
                echo "vm: the box could not be fetched: $failure, and was still failing after ${box_spent}s. No VM was started." >&2
                confirmed_stopped || true
                exit 1
            fi
            [ "$box_wait" -le $((BOX_RETRY_BOUND - box_spent)) ] || box_wait=$((BOX_RETRY_BOUND - box_spent))
            echo "[vm] the box could not be fetched: $failure. Retrying in ${box_wait}s (${box_spent}s of ${BOX_RETRY_BOUND}s spent)..." >&2
            # Its own output: a wait this long must not hold a caller's pipe
            # open after this process is gone.
            sleep "$box_wait" >/dev/null 2>&1 || return
            box_spent=$((box_spent + box_wait))
            box_wait=$((box_wait * 2))
            [ "$box_wait" -le "$BOX_RETRY_MAX_WAIT" ] || box_wait="$BOX_RETRY_MAX_WAIT"
            continue
        fi
        show_console || true
        if [ "$attempt" -ge "$BOOT_ATTEMPTS" ]; then
            echo "vm: the VM would not boot after $BOOT_ATTEMPTS attempts." >&2
            confirmed_stopped || true
            exit 1
        fi
        echo "[vm] boot failed, retrying in ${BOOT_RETRY_WAIT}s (attempt $attempt of $BOOT_ATTEMPTS)..." >&2
        sleep "$BOOT_RETRY_WAIT" || return
        # A half-started machine holds what the next attempt needs.
        engine_down --force >/dev/null 2>&1 || true
        attempt=$((attempt + 1))
    done
}

# A STOP IS WHAT THE STATE SAYS, never what an attempt reported. A halt that
# reported success while the VM kept running is not a stop, and a state that
# could not be read is not one either.
confirmed_stopped() {
    local state
    state="$(engine_state)"
    case "$state" in
        stopped | absent)
            rm -f "$(unfinished_boot_marker)"
            return 0
            ;;
        running)
            echo "vm: the VM is still running." >&2
            ;;
        *)
            echo "vm: could not read the VM's state, so it is not taken to be stopped." >&2
            echo "    'chore vm:status' shows it; 'chore vm:destroy' reclaims it." >&2
            ;;
    esac
    return 1
}

# THE HOST HAS ROOM FOR THE GUEST, or the boot is refused. The guest's memory and
# HOST_MEMORY_RESERVE_MIB for the host must both fit in what the host has
# available: MemAvailable on Linux, free, inactive and speculative pages on macOS.
# A measurement that could not be made refuses too, since a guess is how a full
# machine starts.
HOST_MEMORY_RESERVE_MIB=2048

guest_memory_mib() {
    case "$CFG_vm_memory" in
        *G) echo "$(( ${CFG_vm_memory%G} * 1024 ))" ;;
        *M) echo "${CFG_vm_memory%M}" ;;
    esac
}

host_memory_mib() {
    case "$(uname -s)" in
        Linux)
            awk '/^MemAvailable:/ {print int($2 / 1024); found=1} END {if (!found) exit 1}' /proc/meminfo ;;
        Darwin)
            local stats
            stats="$(vm_stat)" || return 1
            printf '%s\n' "$stats" | awk '
                /page size of/ {for (field=1; field<=NF; field++) if ($field == "bytes)") size=$(field-1)}
                /^Pages (free|inactive|speculative):/ {gsub(/\./, "", $NF); pages+=$NF; found++}
                END {if (!size || found != 3) exit 1; print int(pages * size / 1048576)}' ;;
        *) return 1 ;;
    esac
}

host_memory_check() {
    local available requested
    requested="$(guest_memory_mib)"
    available="$(host_memory_mib)" || available=""
    case "$available" in
        '' | *[!0-9]*)
            echo "vm: the host's free memory could not be measured, so the shared guest is not booted." >&2
            return 1 ;;
    esac
    if [ "$available" -lt "$((requested + HOST_MEMORY_RESERVE_MIB))" ]; then
        echo "vm: not enough host memory for the shared guest: $available MiB available, and it needs" >&2
        echo "    $requested MiB for the guest and $HOST_MEMORY_RESERVE_MIB MiB left for the host. FLTH_SHARED_MEMORY asks for less." >&2
        return 1
    fi
}

vm_down() {
    rm -f "$FLTH_HOLD"
    watchdog_stop
    # The engine's own exit status is not the answer; the state is. This
    # runs as a chore `defer:`, where its exit status is the only thing
    # between a leaked VM and a green run.
    engine_down || true
    # A graceful halt that does not finish -- a long run's guest slow or
    # wedged at shutdown -- is forced before down gives up (#51). An
    # ordinary boot runs on a throwaway overlay, so nothing is lost by
    # forcing it.
    if [ "$(engine_state 2>/dev/null)" = running ]; then
        echo "vm: the graceful halt left the VM running; forcing it down." >&2
        engine_down --force || true
    fi
    if ! confirmed_stopped; then
        echo "vm: halt did not leave the VM confirmed stopped." >&2
        exit 1
    fi
}

vm_hold() {
    mkdir -p "$FLTH_MACHINE_DIR"
    : > "$FLTH_HOLD"
    if engine_run "touch $FLTH_GUEST_HOLD_MARKER; shutdown -c" >/dev/null 2>&1; then
        echo "vm: held — reap will leave it up, and the guest deadline is cancelled." >&2
    else
        echo "vm: held for reap, but the guest is not reachable: its own deadline" >&2
        echo "    still stands and it will power off on schedule. Hold again once it is up." >&2
    fi
}

# The safety net, run from a chore `lifecycle: after_all`. The shared guest is
# there for the next run, so an idle one is not a leak: what this stops is a boot
# that did not finish, and the list it tidies is of suites that have gone.
#
# It FAILS SOFT by design: chore reports an after_all failure without
# failing the run, and turning an unrelated `chore build` red because
# something else left a VM up would teach people to ignore it.
#
# The probe is a process check, not an engine call: it runs on every
# invocation, so it has to cost milliseconds.
vm_reap() {
    if ! engine_alive "$(engine_identity)"; then
        return 0
    fi
    if stop_unfinished_boot; then
        return 0
    fi
    live_sessions >/dev/null
    # A device whose run has no live session: one killed outright, before it could end
    # its run. A worktree's standing run has no session, and keeps its device.
    local run
    while IFS= read -r run; do
        case "$run" in '' | *-worktree) continue ;; esac
        shared_run_gone "$run"
    done < <(engine_attached_runs)
    echo "[vm] left running: the shared guest stays up for the next run. 'chore vm:down' stops it when nobody is using it." >&2
}

# SESSIONS: "IN USE" AS A STATE THE REAPER CAN SEE.
#
# vm-session.sh keeps the VM up for the length of the script that
# sourced it, or the command it runs — `vm:test`, `vm:guest-test`, a
# consumer's fixture build, a consumer's test runner — and deliberately does not `hold`, because a hold must outlive the
# invocation that set it. Without this, a VM in use by a forty-minute
# fixture build was indistinguishable from a leak, and the reaper, run
# by any other chore invocation (another terminal, another agent),
# stopped it mid-build.
#
# So a session leaves a marker naming its process, and the reaper leaves
# the VM alone while any marker's process is alive. A marker whose
# process has died is exactly the leak the reaper exists for, so it is
# removed and ignored. The process's start time is recorded beside its
# pid, so a pid the system has since handed to something else does not
# keep a VM alive.
#
# The markers live in the machine directory, set once a consumer is
# loaded, and they are the list of suites using the shared guest.
sessions_dir() { printf '%s/sessions\n' "$FLTH_MACHINE_DIR"; }

process_start() {
    ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'
}

# The pids of live sessions on this machine, one per line, except $1.
# Markers whose process is gone are removed on the way.
live_sessions() {
    local except="${1:-}" dir marker pid start now run
    dir="$(sessions_dir)"
    [ -d "$dir" ] || return 0
    for marker in "$dir"/*; do
        [ -f "$marker" ] || continue
        IFS=$'\t' read -r pid start _ run < "$marker" || true
        case "$pid" in '' | *[!0-9]*) rm -f "$marker"; continue ;; esac
        [ "$pid" = "$except" ] && continue
        # `|| now=""`: a process that has gone is what this looks for, and this runs
        # under `set -e` when it is not called in a substitution.
        now="$(process_start "$pid")" || now=""
        if [ -z "$now" ] || [ "$now" != "$start" ]; then
            rm -f "$marker"
            shared_run_gone "$run"
            continue
        fi
        printf '%s\n' "$pid"
    done
}

vm_session_begin() {
    local pid="$1" start
    start="$(process_start "$pid")"
    [ -n "$start" ] || flth_die "session-begin: no running process $pid"
    mkdir -p "$(sessions_dir)"
    shared_register "$pid" "$start"
}

# A SESSION'S END STOPS NOTHING BUT ITS RUN: the guest is there for the next one.
vm_session_end() {
    local pid="$1" run
    run="$(cut -f4 "$(sessions_dir)/$pid" 2>/dev/null || true)"
    rm -f "$(sessions_dir)/$pid"
    shared_session_ended "$pid" "$run"
    shared_tell_oops
}

# A GUEST WITH LITTLE MEMORY LEFT (#185). Six suites building at once ran a 10G guest
# out of memory, and none of them was told. A suite joining is told the numbers and who
# is using it when what the guest has available is under FLTH_SHARED_MIN_AVAILABLE
# (2048 MiB). It still joins: whether it fits is the suite's to know.
shared_tell_room() {
    local numbers total available floor="${FLTH_SHARED_MIN_AVAILABLE:-2048}"
    case "$floor" in '' | *[!0-9]*) floor=2048 ;; esac
    numbers="$(engine_run "awk '\$1 == \"MemTotal:\" { t = \$2 } \$1 == \"MemAvailable:\" { a = \$2 } END { print int(t / 1024), int(a / 1024) }' /proc/meminfo" 2>/dev/null)" || return 0
    read -r total available <<< "$numbers"
    case "$total$available" in '' | *[!0-9]*) return 0 ;; esac
    [ "$total" -gt 0 ] && [ "$available" -lt "$floor" ] || return 0
    echo "vm: the shared guest has $available MiB of $total MiB available, in use by: $(shared_suites)." >&2
    echo "    A suite that needs more may be killed for memory. FLTH_SHARED_MEMORY sizes the guest at its next boot." >&2
}

# A KERNEL THAT HAS OOPSED KEEPS ANSWERING (#196), so a suite on it goes on and reports
# what follows as its own result. The console is on the host and starts afresh with
# each boot, so an oops in it is this boot's. A suite is told as it joins and as it
# ends, naming the first oops and the process it hit; a single call is not.
shared_tell_oops() {
    local file first
    file="$(engine_console_log)"
    [ -s "$file" ] || return 0
    first="$(LC_ALL=C awk '
        oops != "" && /Comm: / {
            p = $0; sub(/.*PID: */, "", p); pid = p; sub(/ .*/, "", pid)
            name = p; sub(/.*Comm: */, "", name); sub(/ .*/, "", name)
            print oops ", in process " pid " (" name ")"; exit
        }
        oops == "" && /Oops: .*\[#[0-9]+\]/ { oops = substr($0, index($0, "Oops: ")); sub(/[[:space:]]+$/, "", oops) }
        ' "$file" 2>/dev/null || true)"
    if [ -z "$first" ]; then
        first="$(LC_ALL=C grep -m1 -oE 'Oops: .*\[#[0-9]+\].*' "$file" 2>/dev/null || true)"
    fi
    [ -n "$first" ] || return 0
    echo "vm: the shared guest's kernel has oopsed: $first." >&2
    echo "    What a suite saw on it since may be the kernel's failure, not its own. The console is $file;" >&2
    echo "    'chore vm:down' then a new boot gives a kernel that has not." >&2
}

# THE LIST OF SUITES USING A SHARED GUEST (#153). The session markers are the list:
# an entry names a process, and one whose process has gone is dropped before anyone
# counts. In this mode the end of a session stops nothing, because the guest is
# there for the next run. Only a shutdown request stops it, and only with the list
# empty. Registering and that check hold the up lock, so a suite that registers
# during a shutdown waits for it: its `up` then finds no guest and boots a new one.
# Deregistering needs no lock. A shutdown that reads an entry just before it goes
# leaves the guest up, as it would have a moment earlier.
shared_register() {
    up_lock_take
    # Before this one counts: what a killed suite holds is free for this one.
    live_sessions >/dev/null
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$CFG_project_name" "$(shared_run_id)" > "$(sessions_dir)/$1"
    up_lock_drop
}

# WHICH RUN THIS CALL BELONGS TO. A session names one in the environment of what it
# starts, led by a hash of the tree it is for, because a suite that drives another
# consumer's harness calls must not land in this one's run. A call outside any
# session belongs to its worktree's standing run, which lasts as long as the guest:
# a `chore vm:exec` by hand still finds what the last one left.
shared_run_prefix() { flth_hash8 "$FLTH_ROOT"; }

shared_run_id() {
    local prefix
    prefix="$(shared_run_prefix)"
    case "${FLTH_RUN_ID:-}" in
        "$prefix"-*[!a-z0-9-]*) ;;
        "$prefix"-?*) printf '%s\n' "$FLTH_RUN_ID"; return 0 ;;
    esac
    printf '%s-worktree\n' "$prefix"
}

# What a session names, for itself and everything it starts.
shared_new_run_id() {
    local inherited
    inherited="$(shared_run_id)"
    case "$inherited" in
        *-worktree) ;;
        *) printf '%s\n' "$inherited"; return 0 ;;
    esac
    printf '%s-%s\n' "$(shared_run_prefix)" "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
}

# The words after a run's id on lib/guest-run.sh's command line: where its tree and
# its share are in the guest, its cache, and whose run it is.
#
# A DECLARED CACHE IS A DIRECTORY OF THE GUEST'S, per consumer, for as long as the
# guest runs: every consumer's own disk could not be attached to a guest already up.
shared_run_places() {
    local cache=-
    [ -z "$FLTH_SHARED_CACHE" ] || cache="/var/lib/fs-linux-test-harness/caches/$CFG_project_name"
    printf '%s %s %s %s' "$(shared_run_id)" "$(quote_for_guest "$CFG_share_dir")" "$cache" "$CFG_project_name"
}

# THE RUN'S TREE IS A DEVICE OF ITS OWN (#222), attached to the running guest the
# first time the run needs it, tagged with the run id, and mounted over /repo in the
# run's namespace (lib/guest-run.sh). A call outside any session uses its worktree's
# standing run, whose device lasts as long as the guest. Attaching takes the up
# lock, so two calls of one run attach it once, and a free slot is taken by one.
shared_attach() {
    local run rc=0
    run="$(shared_run_id)"
    engine_tree_attached "$run" || rc=$?
    case "$rc" in
        0) return 0 ;;
        3) shared_tree_lost "$run" ;;
    esac
    if [ "$UP_LOCK_HELD" = 1 ]; then
        engine_attach_tree "$run" "$FLTH_ROOT"
        return
    fi
    up_lock_take
    rc=0
    engine_tree_attached "$run" || rc=$?
    if [ "$rc" != 0 ] && ! engine_attach_tree "$run" "$FLTH_ROOT"; then
        up_lock_drop
        return 1
    fi
    up_lock_drop
}

# A RUN WHOSE virtiofsd HAS GONE. A request the guest sends to a device whose daemon
# has gone never completes, and removing the device after one wedges hot-plug for the
# whole guest. So the device goes first, before anything else runs in that run, and
# only then are the run's processes stopped and its namespace dropped. The call that
# found it fails with the interrupted status: the suite did not fail, its tree went.
shared_tree_lost() {
    local run="$1"
    echo "vm: the virtiofsd serving $FLTH_ROOT to run $run has gone. Its device is removed before anything" >&2
    echo "    else runs there, and the run is ended. This is not a failure of the suite: run it again." >&2
    engine_detach_tree "$run" || true
    engine_run "bash $FLTH_GUEST_RUNS/run.sh end $run" >&2 || true
    exit "$WATCHDOG_STATUS"
}

shared_in_run() {
    printf 'bash %s/run.sh enter %s %s %s\n' "$FLTH_GUEST_RUNS" "$(shared_run_id)" "$(shared_run_places)" \
        "$(quote_for_guest "$1")"
}

# Every call into the guest goes in its run.
guest_call_script() { shared_in_run "$1"; }

# A guest-test's run has its own copy of the tree (lib/guest-run.sh).
vm_guest_tree() {
    shared_attach || return
    engine_run "bash $FLTH_GUEST_RUNS/run.sh tree $(shared_run_id) $(shared_run_places) $(quote_for_guest "$CFG_share_dir")" >&2
}

# The tool the calls above use, on every boot: the disk it would be kept on is
# thrown away with the boot, and so is /run. Before the boot counts as finished.
shared_prepare_guest() {
    engine_run "mkdir -p $FLTH_GUEST_RUNS
cat > $FLTH_GUEST_RUNS/run.sh <<'FLTH_GUEST_RUN_END'
$(cat "$FLTH_HARNESS/scripts/lib/guest-run.sh")
FLTH_GUEST_RUN_END
bash $FLTH_GUEST_RUNS/run.sh prepare" >&2
}

# A CALL OUTSIDE ANY SESSION IS A USER OF THE GUEST TOO. It goes on the list for as long
# as it lasts, so a shutdown request waits for it, and an entry naming a process that has
# gone is dropped like any other. It names no run: the worktree's standing run outlives
# the call. A `run` is listed before its `up` takes the lock, so a shutdown holding the
# lock either sees it or has finished, and the `up` then boots. An `exec` never boots, so
# one that starts in the moment after a shutdown has counted loses the guest and says so.
SHARED_CALL_ENTRY=""

shared_call_begin() {
    case "$(shared_run_id)" in *-worktree) ;; *) return 0 ;; esac
    mkdir -p "$(sessions_dir)"
    SHARED_CALL_ENTRY="$(sessions_dir)/$$"
    printf '%s\t%s\t%s\n' "$$" "$(process_start "$$")" "$CFG_project_name" > "$SHARED_CALL_ENTRY"
}

guest_run_listed() {
    local rc=0
    guest_run "$1" || rc=$?
    [ -z "$SHARED_CALL_ENTRY" ] || rm -f "$SHARED_CALL_ENTRY"
    return "$rc"
}

# WHAT A BOOT FIXED FOR EVERYONE WHO JOINS: the lib/guest-run.sh it carries. A join
# from a harness with another tool would call it with the wrong words, so it is
# refused here, where it can say why. Nobody is stopped for it: the guest is in use,
# and it can be joined by that version, or later by a new boot.
shared_boot_record() { printf '%s/shared-boot\n' "$FLTH_MACHINE_DIR"; }

shared_boot_identity() {
    flth_hash8 "$(cat "$FLTH_HARNESS/scripts/lib/guest-run.sh")"
}

refuse_other_boot() {
    local recorded
    recorded="$(cat "$(shared_boot_record)" 2>/dev/null || true)"
    [ "$recorded" != "$(shared_boot_identity)" ] || return 0
    if [ -z "$recorded" ]; then
        echo "vm: the shared guest has no record of how it was booted, so joining it is refused." >&2
    else
        echo "vm: the shared guest was booted by another version of the harness." >&2
    fi
    echo "    Nothing ran. Join with that version, or again once it has stopped." >&2
    exit 1
}

# A run nobody is on the list for any more: stop what it left and delete its root,
# if the guest is there to ask. Nothing depends on this having worked. What it fails
# to free goes with the boot.
#
# THE RUN ENDS IN THE GUEST BEFORE ITS DEVICE IS DETACHED: its processes are stopped,
# its loop devices detached and its namespace dropped, so nothing can use the mount
# when the device and then its virtiofsd go (#222). A daemon that has already gone
# is the exception: its device goes first (shared_tree_lost says why).
shared_run_gone() {
    local run="$1" marker attached=0
    [ -n "$run" ] || return 0
    for marker in "$(sessions_dir)"/*; do
        [ -f "$marker" ] || continue
        [ "$(cut -f4 "$marker" 2>/dev/null || true)" != "$run" ] || return 0
    done
    engine_tree_attached "$run" || attached=$?
    if [ "$attached" = 3 ]; then
        engine_detach_tree "$run" || true
        attached=1
    fi
    if engine_alive "$(engine_identity)"; then
        engine_run "bash $FLTH_GUEST_RUNS/run.sh end $run" >&2 ||
            echo "vm: run $run could not be cleaned up in the guest; what it left goes when the guest stops." >&2
    fi
    if [ "$attached" = 0 ] && ! engine_detach_tree "$run"; then
        echo "vm: run $run's tree is still attached; it goes when the guest stops." >&2
    fi
}

# The live suites, as `name (pid N)`, comma-separated.
shared_suites() {
    local pid name list=""
    while IFS= read -r pid; do
        name="$(cut -f3 "$(sessions_dir)/$pid" 2>/dev/null || true)"
        list="$list${list:+, }${name:-unknown} (pid $pid)"
    done < <(live_sessions)
    printf '%s\n' "$list"
}

# A guest that stopped itself gets no halt, so what its boot left on the host goes
# here, once nobody else is on the list and no `up` has taken the machine.
shared_session_ended() {
    local alive=0
    if stop_unfinished_boot; then
        return 0
    fi
    shared_run_gone "$2"
    engine_alive "$(engine_identity)" || alive=$?
    [ "$alive" -eq 1 ] || return 0
    up_lock_try || return 0
    if [ -z "$(live_sessions "$1")" ]; then
        engine_stop_host_daemons
        rm -f "$(unfinished_boot_marker)"
    fi
    up_lock_drop
}

# `vm.sh down`. The shared guest stops only if nobody is using it.
vm_shutdown() {
    local suites
    up_lock_take
    suites="$(shared_suites)"
    if [ -n "$suites" ]; then
        echo "[vm] left running: the shared guest is in use by $suites. The last one's shutdown request stops it." >&2
    else
        vm_down
    fi
    up_lock_drop
}

# Re-apply this consumer's setup script, even when unchanged. The shared guest is
# not stopped for one consumer's setup: it runs again in place.
vm_provision() {
    PROVISION_MODE=force
    vm_up
}

# The live sessions this call is not itself running inside.
other_sessions() {
    local ancestors=" " pid="$VM_PARENT" parent depth=0 session
    while [ "$pid" -gt 1 ] && [ "$depth" -lt 64 ]; do
        ancestors="$ancestors$pid "
        parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || break
        case "$parent" in '' | *[!0-9]*) break ;; esac
        pid="$parent"
        depth=$((depth + 1))
    done
    while IFS= read -r session; do
        case "$ancestors" in *" $session "*) ;; *) printf '%s\n' "$session" ;; esac
    done < <(live_sessions)
}

# RESTART THE GUEST IN PLACE (#122). The engine's own restart is not used: the
# harness has to confirm the stop before the boot, and an `up` between a `down`
# and an `up` would boot beside a guest still stopping. The lock is held across
# both. The boot is an ordinary disposable one, and only this consumer's setup
# runs again on it: another consumer's runs when that one next joins.
vm_reload() {
    local rc=0
    up_lock_take
    vm_reload_locked || rc=$?
    up_lock_drop
    return "$rc"
}

vm_reload_locked() {
    local state others
    state="$(engine_state)"
    case "$state" in
        running) ;;
        stopped | absent)
            echo "vm: $CFG_project_name is not running, so there is nothing to reload. 'chore vm:up' boots it." >&2
            exit 1
            ;;
        *)
            echo "vm: could not read the VM's state; not restarting it until it can be read." >&2
            exit 1
            ;;
    esac
    others="$(other_sessions)"
    if [ -n "$others" ]; then
        echo "vm: not reloading: another invocation is using the VM (pid ${others//$'\n'/, })." >&2
        echo "    Run it again once that has finished." >&2
        exit 1
    fi
    require_host_tools
    engine_down || true
    if [ "$(engine_state 2>/dev/null)" = running ]; then
        echo "vm: the graceful halt left the VM running; forcing it down." >&2
        engine_down --force || true
    fi
    if [ "$(engine_state)" != stopped ]; then
        echo "vm: the VM could not be confirmed stopped, so nothing is booted beside it." >&2
        echo "    'chore vm:status', then 'chore vm:down' or 'chore vm:destroy'." >&2
        exit 1
    fi
    boot_vm || return 1
    apply_setup boot
    if [ -f "$FLTH_HOLD" ]; then
        vm_hold
    fi
}

vm_destroy() {
    local suites
    up_lock_take
    suites="$(shared_suites)"
    if [ -n "$suites" ]; then
        echo "vm: not destroying the shared guest: it is in use by $suites." >&2
        exit 1
    fi
    rm -f "$FLTH_HOLD"
    engine_destroy || true
    if ! confirmed_stopped; then
        echo "vm: destroy did not leave the VM confirmed gone." >&2
        exit 1
    fi
    up_lock_drop
}

vm_status() {
    local state
    state="$(engine_state)"
    case "$state" in
        running)
            echo "vm: the shared guest is running"
            if boot_stopped_short; then
                echo "vm: its last boot did not finish, so its guest has no shares. 'chore vm:up' replaces it."
            fi
            echo "vm: in use by: $(shared_suites)"
            if [ -s "$FLTH_MACHINE_DIR/watchdog.last" ]; then
                echo "vm: watchdog: $(cat "$FLTH_MACHINE_DIR/watchdog.last")"
            fi
            ;;
        *)
            echo "vm: the shared guest is not running ($state)"
            if [ -f "$(watchdog_record)" ]; then
                echo "vm: the watchdog ended it: $(cat "$(watchdog_record)")"
            fi
            exit 1
            ;;
    esac
}

# Run the consumer's [test] command on the host, from the repository
# root, with the guest up, as a run of its own (vm-session.sh). The guest
# stays up for the next run.
#
# Extra arguments are appended to the command. The command reaches the
# guest through FLTH_VM (this script), so it can `run` and `put`.
vm_test() {
    [ -n "$CFG_test_command" ] ||
        flth_die "$FLTH_CONFIG has no [test] command"
    cd "$FLTH_ROOT"
    # THE SESSION STAYS ABLE TO HEAR A SIGNAL. A script that sources the session has
    # its command in the foreground, so a TERM to that shell alone waits for the
    # command, for the length of the suite. On the shared guest a signal to one suite
    # has to stop it while others run, and a session running a command passes it on.
    FLTH_VM="$SELF" FLTH_SHARE_HOST="$FLTH_SHARE_HOST" FLTH_SHARE_GUEST="$FLTH_SHARE_GUEST" \
    FLTH_TEST_COMMAND="$CFG_test_command" \
        exec "$FLTH_HARNESS/scripts/vm-session.sh" bash -c '
            "$FLTH_VM" up || exit
            exec bash -c "$FLTH_TEST_COMMAND \"\$@\"" flth-test "$@"
        ' flth-session "$@"
}

# THE GUEST DEADLINE MEASURES IDLENESS, NOT LIFETIME. deadline.sh arms
# the guest's poweroff once, at boot; left at that, `deadline_minutes` is
# a cap on the whole boot, and a suite longer than it loses its VM
# mid-run. So every call into the guest re-arms it, when the call starts
# and again when it ends: the guest powers off after `deadline_minutes`
# with nothing asking anything of it, and a suite of many calls is never
# interrupted however long it runs. What is still bounded is a SINGLE
# call, which is the hang the deadline exists to catch.
#
# `shutdown` replaces a scheduled shutdown rather than adding a second,
# so re-arming cannot stack timers. It is rate-limited by a stamp in the
# guest's /run, so a test process asking hundreds of questions a minute
# makes one logind call a minute, not hundreds; the price is that the
# deadline can fall up to a window early. THE WINDOW FITS INSIDE THE DEADLINE
# (#152): a sixth of it, at most a minute. A window as long as a one-minute
# deadline let a call find the stamp fresh with a second of the guest left.
# A held guest (`vm.sh hold`) is never re-armed. --no-wall, because a person
# in the guest does not need a broadcast a minute.
#
# It never fails the call: a guest whose timer could not be re-armed
# keeps the one it had, which is the behaviour before this existed.
#
# A SIGNAL ON THE HOST STOPS THE COMMAND IN THE GUEST (#139). The command runs in a
# process group of its own, and the call's stdin stays open while the host side
# lives (engine_run_held). A watcher in the guest reads it. End-of-file with the
# command still running means the host side has gone, by a signal or a lost
# connection, and nobody can receive the result: the watcher sends TERM to that
# group and to the command's descendants, which `timeout` or job control can have
# moved to groups of their own, and KILL to what is left after 50 ticks of 0.1
# seconds. The guest finds these with `ps`, from the group's id and the parent of
# each process. Other calls are other groups, so they are not touched. A command
# that ends on its own ends the watcher, so what it left in the background stays.
#
# Everything is one compound command because `bash -s` reads its script from the
# stdin the watcher reads: the shell has to have read all of it first. The command
# goes in as a quoted string, and its stdin is empty, as it was when the script's
# end was the end of stdin.
#
# THE COMMAND MAKES ITS OWN GROUP. Perl, in every Debian and macOS base install,
# moves itself into a group of its own and then runs the command, and it sets INT
# and QUIT back to their defaults first, since a background job without job control
# starts with them ignored. Job control (`set -m`) would make the group from both
# sides, the shell and the child at once, as POSIX asks; on macOS the two calls
# race, the child's fails with EPERM although the group is made, and Bash prints
# "child setpgid ... Operation not permitted" into the call's stderr. The tests
# run this script on the host as the guest's shell. A group made from one side
# exists only once the child has made it, so the watcher also stops the command by
# its pid: a host side gone before then still stops it.
REARM_WINDOW_SECS=60
rearm_window_secs() {
    local window=$((CFG_vm_deadline_minutes * 60 / 6))
    [ "$window" -le "$REARM_WINDOW_SECS" ] || window="$REARM_WINDOW_SECS"
    printf '%s\n' "$window"
}
guest_call() {
    local single="'" escaped="'\\''" window
    window="$(rearm_window_secs)"
    cat <<EOF
{
flth_rearm() {
    local now last=0
    [ -f $FLTH_GUEST_HOLD_MARKER ] && return 0
    printf -v now '%(%s)T' -1
    { read -r last < $FLTH_GUEST_REARM_STAMP; } 2>/dev/null || true
    case "\$last" in '' | *[!0-9]*) last=0 ;; esac
    [ \$((now - last)) -ge $window ] || return 0
    printf '%s\n' "\$now" > $FLTH_GUEST_REARM_STAMP
    shutdown --no-wall -h +$CFG_vm_deadline_minutes >/dev/null 2>&1 ||
        echo "vm: could not re-arm the guest's poweroff deadline; the previous one stands" >&2
}
flth_members() {
    ps -A -o pid=,ppid=,pgid=,stat= | awk -v group="\$1" -v known="\$2" '
        BEGIN { n = split(known, seen, " "); for (i = 1; i <= n; i++) keep[seen[i]] = 1 }
        { pid[NR] = \$1; parent[NR] = \$2; state[NR] = \$4; if (\$3 == group) keep[\$1] = 1 }
        END {
            do {
                grew = 0
                for (i = 1; i <= NR; i++)
                    if (!(pid[i] in keep) && (parent[i] in keep)) { keep[pid[i]] = 1; grew = 1 }
            } while (grew)
            for (i = 1; i <= NR; i++)
                if ((pid[i] in keep) && state[i] !~ /^Z/) printf "%s ", pid[i]
        }'
}
flth_stop() {
    local members ticks=0
    members="\$(flth_members "\$1" "\$1")"
    [ -n "\$members" ] || return 0
    kill -TERM -- "-\$1" \$members
    while [ "\$ticks" -lt 50 ]; do
        members="\$(flth_members "\$1" "\$members")"
        [ -n "\$members" ] || return 0
        command -p sleep 0.1
        ticks=\$((ticks + 1))
    done
    ticks=0
    while [ -n "\$members" ] && [ "\$ticks" -lt 50 ]; do
        kill -KILL -- "-\$1" \$members
        command -p sleep 0.1
        members="\$(flth_members "\$1" "\$members")"
        ticks=\$((ticks + 1))
    done
}
flth_rearm
trap flth_rearm EXIT
perl -e '\$SIG{INT} = \$SIG{QUIT} = "DEFAULT"; setpgrp(0, 0) or die "vm: the guest command has no process group of its own: \$!\n"; exec { \$ARGV[0] } @ARGV or exit 127' \\
"\$BASH" -c '${1//$single/$escaped}' < /dev/null &
flth_command=\$!
(
    trap '' HUP
    while read -r flth_line; do :; done
    trap '' TERM
    flth_stop "\$flth_command"
) <&0 > /dev/null 2>&1 &
flth_watcher=\$!
wait "\$flth_command"
flth_status=\$?
{ kill -TERM "\$flth_watcher"; wait "\$flth_watcher"; } 2> /dev/null
exit "\$flth_status"
}
EOF
}

# THE PER-CALL PATH, for a test process that asks the guest hundreds of
# questions. `run` boots when the VM is down, which is what makes it
# convenient for a script and wrong for a test: a boot in the middle of a
# test binary is a minute nobody asked for, and a VM nothing will bring
# down. `exec` never boots. It checks the process table (milliseconds),
# runs the command, and says what to run when the VM is not there.
#
# It also skips the setup check: the suite's task brought the VM up, and
# the setup script cannot change while it runs.
vm_exec() {
    if [ -s "$(shared_kernel_record)" ]; then
        shared_kernel_explain "$(cat "$(shared_kernel_record)")" "the kernel it booted with"
        exit 1
    fi
    if ! engine_alive "$(engine_identity)"; then
        if [ -f "$(watchdog_record)" ]; then
            watchdog_explain "$(cat "$(watchdog_record)")"
            exit "$WATCHDOG_STATUS"
        fi
        echo "vm: $CFG_project_name's VM is not running, and 'exec' never boots one." >&2
        echo "    Bring it up for the run first ('chore vm:up', which also holds it)," >&2
        echo "    or use 'chore vm:run -- <command>', which boots on demand." >&2
        exit 1
    fi
    refuse_unfinished_boot
    shared_call_begin
    guest_run_listed "$*"
}

# THE CONSUMER'S SUITE, RUN IN THE GUEST, from the repository mounted at
# $FLTH_REPO_GUEST. For a host that cannot run the tests natively — a Mac
# for a Linux suite — and for a CI job that proves that path still works.
#
# The harness knows nothing about what the command is: the consumer's
# [setup] script prepares the guest (a compiler, an interpreter, its
# tools) and [test] guest_command says what to run. Output streams as it
# happens, the exit status is the command's, and anything the run should
# leave behind goes in the shared directory, which both sides see.
#
# A run of its own, under vm-session.sh's rules, exactly like `test`.
vm_guest_test() {
    [ -n "$CFG_test_guest_command" ] ||
        flth_die "$FLTH_CONFIG has no [test] guest_command"
    local script arg
    script="cd $(quote_for_guest "$FLTH_REPO_GUEST") && $CFG_test_guest_command"
    for arg in "$@"; do
        script="$script $(quote_for_guest "$arg")"
    done
    FLTH_VM="$SELF" FLTH_GUEST_SCRIPT="$script" \
        exec "$FLTH_HARNESS/scripts/vm-session.sh" bash -c '
            "$FLTH_VM" up || exit
            "$FLTH_VM" guest-tree || exit
            exec "$FLTH_VM" exec "$FLTH_GUEST_SCRIPT"
        '
}

# One argument, as the guest's shell will read it. Single quotes so
# nothing in it is a variable, a command or a word boundary there.
quote_for_guest() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

vm_config() {
    cat <<EOF
config=$FLTH_CONFIG
root=$FLTH_ROOT
project.name=$CFG_project_name
vm.memory=$CFG_vm_memory
vm.cpus=$CFG_vm_cpus
vm.disk=$CFG_vm_disk
vm.ssh_port=$CFG_vm_ssh_port
vm.deadline_minutes=$CFG_vm_deadline_minutes
vm.guest=$CFG_vm_guest
share.dir=$CFG_share_dir
share.host=$FLTH_SHARE_HOST
share.guest=$FLTH_SHARE_GUEST
repo.guest=$FLTH_REPO_GUEST
setup.script=$CFG_setup_script
test.command=$CFG_test_command
test.guest_command=$CFG_test_guest_command
cache.size=${FLTH_SHARED_CACHE:-none}
cache.guest=$([ -n "$FLTH_SHARED_CACHE" ] && echo "$FLTH_CACHE_GUEST" || echo none)
machine=$FLTH_MACHINE_DIR
run.standing=$(shared_run_prefix)-worktree
qmp=${FLTH_VM_QMP:-none}
slots=${FLTH_SHARED_SLOTS:-32}
identity=$(engine_identity)
EOF
}

command="${1:-}"
case "$command" in
    '' | -h | --help | help)
        usage
        [ -n "$command" ] || exit 2
        exit 0
        ;;
    session)
        # Before any consumer is loaded: where no VM can run (in the guest,
        # on a host without the tools) the command runs with no engine
        # call at all, and vm-session.sh is what decides that.
        shift
        exec "$(dirname "$SELF")/vm-session.sh" "$@"
        ;;
    up | up-boot | run | watchdog-end | watchdog-told | tree-lost | exec | put | share | provision | reload | test | guest-test | down | status | hold | reap | destroy | config | session-begin | session-end | run-id | guest-tree) ;;
    *)
        echo "vm: unknown command '$command'" >&2
        usage >&2
        exit 2
        ;;
esac
shift

flth_load || exit 1
engine_prepare

case "$command" in
    up)
        vm_up
        shared_tell_oops
        shared_tell_room
        ;;
    up-boot)
        [ $# -eq 2 ] || flth_die "usage: vm.sh up-boot <provision mode> <pid>"
        vm_up_boot "$1" "$2"
        ;;
    run)
        [ $# -gt 0 ] || flth_die "usage: vm.sh run <command...>"
        shared_call_begin
        vm_up
        # Joined, and run by the guest's shell: a pipeline or `&&` in the
        # command belongs to the guest, not the host.
        guest_run_listed "$*"
        ;;
    exec)
        [ $# -gt 0 ] || flth_die "usage: vm.sh exec <command...>"
        vm_exec "$*"
        ;;
    put)
        [ $# -eq 1 ] || flth_die "usage: vm.sh put <file>"
        [ -f "$1" ] || flth_die "no such file: $1"
        engine_copy "$1"
        ;;
    share) echo "$FLTH_SHARE_HOST" ;;
    provision) vm_provision ;;
    reload) vm_reload ;;
    test) vm_test "$@" ;;
    guest-test) vm_guest_test "$@" ;;
    down) vm_shutdown ;;
    status) vm_status ;;
    hold) vm_hold ;;
    reap) vm_reap ;;
    destroy) vm_destroy ;;
    config) vm_config ;;
    watchdog-end) vm_watchdog_end "$1" ;;
    watchdog-told) vm_watchdog_told "$1" ;;
    tree-lost) vm_tree_lost "$1" ;;
    run-id) shared_new_run_id ;;
    guest-tree) vm_guest_tree ;;
    session-begin | session-end)
        if [ $# -ne 1 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
            flth_die "usage: vm.sh $command <pid>"
        fi
        "vm_${command/-/_}" "$1"
        ;;
esac
