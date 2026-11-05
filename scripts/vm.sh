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
#   vm.sh reload           restart the running VM in place, keeping its slot
#   vm.sh test [args...]   boot, run the consumer's [test] command, tear down
#   vm.sh guest-test [args...]  boot, run the [test] guest_command INSIDE the guest, tear down
#   vm.sh session <cmd...> run a command on the host inside a session: the VM comes down when it ends
#   vm.sh down             halt, confirm it stopped, release the slot
#   vm.sh status           exit 0 when the VM is running, 1 otherwise
#   vm.sh hold             keep the VM up: reap leaves it, the guest deadline is cancelled
#   vm.sh reap             stop a VM nothing cleaned up (the safety net)
#   vm.sh destroy          delete the VM and its disk, release the slot
#   vm.sh config           print the resolved configuration
#
# NOT IN THE USAGE, AND NO CHORE TASK, ON PURPOSE: `session-begin <pid>`,
# `session-end <pid>`, `boot-finished`, `run-id` and `guest-tree` are vm-session.sh's
# and guest-test's plumbing, the calls that make a session visible to the reaper,
# tell it whether there is a VM it may keep and set up a run on a shared guest. A
# person has no reason to run them, so
# they stay out of the list above, which is what tests/generic.sh reads as
# the public commands every one of which needs a task in vm.chores.yml.
#
# The consumer is found from fs-linux-test-harness.toml in the working
# directory or a parent, or from FLTH_CONFIG. See README.md.
#
# The VM is kept running between invocations on purpose: booting is the
# slow part, and an iterate-and-check loop should pay it once. What stops
# it is, in order: `down` (a chore `defer:`, or a vm-session.sh session
# ending, which leaves a held VM up), `reap` (a chore `after_all`), and
# the guest's own poweroff deadline.
#
# WHAT A BOOT WRITES IS GONE WHEN IT STOPS. The machine's disk carries the
# consumer's setup and nothing else: every boot that runs anything is
# disposable (lib/engine.sh, engine_up), and only a provisioning boot —
# one that applies a setup script the disk does not carry yet, and is
# stopped before anything runs — writes it. See provision_disk. The one
# thing a run writes that is kept is what it puts in a cache the consumer
# declared ([cache] size), which is a disk of its own at FLTH_CACHE_GUEST.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
. "$(dirname "$SELF")/lib/common.sh"

SLOT="$FLTH_HARNESS/scripts/vm-slot.sh"
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

# What a boot of the machine's disk starts from: the hash of the setup
# script the disk carries, recorded when a provisioning boot stopped
# cleanly. Absent when the disk carries none, or nobody knows.
base_record() { printf '%s/base.sha256\n' "$FLTH_MACHINE_DIR"; }

# Present while the VM is up on a provisioning boot, whose writes are
# kept. Nothing is run there: see refuse_provisioning_boot.
provisioning_marker() { printf '%s/provisioning\n' "$FLTH_MACHINE_DIR"; }

# `boot` provisions only when the disk does not carry the script; `force`
# (`vm.sh provision`) re-applies it regardless.
PROVISION_MODE=boot

# Set by apply_setup when the setup script actually ran in the guest.
SETUP_APPLIED=0

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Run the consumer's setup script inside the guest.
#
#   boot    after a boot: run it unless the guest records this exact
#           script as already applied
#   auto    the VM was already up: trust the host's record of what was
#           applied, and only ask the guest when the script has changed
#   force   run it regardless
#
# The guest's stamp is the authority, because it lives with the disk the
# tooling was installed on. The host's stamp only saves an ssh round
# trip on every `run` against a VM that is already up.
#
# The script travels base64-encoded inside the command, so nothing in it
# can be mistaken for the end of anything, and it runs with stdin from
# /dev/null so an `apt-get` inside cannot swallow what follows. Its output
# goes to stderr, so the stdout of `vm.sh run` is only the command's.
apply_setup() {
    local mode="$1" script hash host_stamp guest force=0 payload out rc stamp take_turn="" with_tree=""
    script="$FLTH_ROOT/$CFG_setup_script"
    hash="$(sha256_of "$script")" || return
    host_stamp="$FLTH_MACHINE_DIR/setup.sha256"

    if [ "$mode" = auto ] && [ "$(cat "$host_stamp" 2>/dev/null || true)" = "$hash" ]; then
        return 0
    fi
    [ "$mode" = force ] && force=1
    payload="$(base64 < "$script")" || return
    SETUP_APPLIED=0
    stamp=/var/lib/fs-linux-test-harness/setup.sha256

    # ON A SHARED GUEST each consumer has a stamp of its own and its setup runs with
    # its own tree. Two setups at once would collide on the package manager's lock,
    # and nothing merges them, so they take turns. The stamp is read again after the
    # wait: another suite of this consumer may have applied it. They install
    # alongside each other.
    if flth_shared; then
        stamp="/var/lib/fs-linux-test-harness/setup-$CFG_project_name.sha256"
        take_turn="exec 9> $FLTH_GUEST_RUNS/setup.lock
flock -n 9 || { echo '[vm] waiting for another consumer'\\''s setup to finish' >&2; flock 9; }
if [ $force = 0 ] && [ \"\$(cat \"\$stamp\" 2>/dev/null || true)\" = '$hash' ]; then
    exit 0
fi"
        with_tree="bash $FLTH_GUEST_RUNS/run.sh setup $(shared_run_places)"
    fi

    guest="set -euo pipefail
stamp=$stamp
if [ $force = 0 ] && [ \"\$(cat \"\$stamp\" 2>/dev/null || true)\" = '$hash' ]; then
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
echo applied"

    rc=0
    out="$(engine_run "$guest")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$host_stamp"
        [ "$rc" -ne 255 ] || report_lost_guest
        echo "vm: the setup script ($CFG_setup_script) failed inside the VM." >&2
        echo "    The VM is left running so it can be inspected; 'chore vm:down' stops it." >&2
        exit 1
    fi
    printf '%s\n' "$hash" > "$host_stamp" || return
    [ "$out" = applied ] && SETUP_APPLIED=1
    return 0
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
    trap 'rm -rf "$FLTH_MACHINE_DIR/up.lock"' EXIT
}

# Held only while up decides and boots: `run` comes through up on every
# call, and parallel runs on a VM that is up must not queue behind each
# other. The EXIT trap covers up's own `exit` paths.
up_lock_drop() {
    rm -rf "$FLTH_MACHINE_DIR/up.lock"
    trap - EXIT
}

# A BOOT THAT DID NOT FINISH IS NOT A VM (#134). QEMU daemonizes early in a boot
# and the shares are mounted late, so a signal between the two ends the boot and
# leaves a guest with /share and /repo never mounted. It answers ssh and its state
# reads running, so a run against it exits 0 having seen empty directories. Measured
# on an Apple Silicon host with FLTH_KEEP_VM=1.
#
# So a marker exists from before a boot starts until the engine says it finished,
# and is written and removed under the up lock. A marker with no live process
# holding that lock is a boot that stopped short, however it stopped: a signal, a
# KILL or three failed attempts. Nothing keeps what it left: a session's end and the
# reaper stop it whatever would have kept a VM, and `up` replaces it.
unfinished_boot_marker() { printf '%s/boot-unfinished\n' "$FLTH_MACHINE_DIR"; }

boot_vm() {
    : > "$(unfinished_boot_marker)" || return
    boot_engine "$@" || return
    if flth_shared; then
        shared_prepare_guest || return
        shared_boot_identity > "$(shared_boot_record)" || return
    fi
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
        "$SLOT" release
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

# vm-session.sh asks before it keeps a VM for FLTH_KEEP_VM=1.
vm_boot_finished() {
    if boot_stopped_short; then
        return 1
    fi
    return 0
}

# THE MACHINE IS NAMED FOR THE PROJECT AND THE GUEST'S /repo IS ONE WORKTREE.
# Every worktree of a repository shares a machine, and its guest mounts the one
# that booted it, so a command from another worktree would run against the wrong
# files while reporting success or an unrelated failure (#112). Each boot records
# its worktree and the running VM process's identity. A record from another
# boot, or one whose boot cannot be identified, says nothing about the guest's
# current mount and is treated like no record.
mounted_worktree_record() { printf '%s\n' "$FLTH_MACHINE_DIR/mounted-worktree"; }
mounted_worktree_boot_record() { printf '%s\n' "$FLTH_MACHINE_DIR/mounted-worktree-boot"; }

# Print the worktree the guest has mounted, when that is not this one.
mounted_elsewhere() {
    local mounted recorded current pending owner
    if flth_shared; then
        return 1
    fi
    mounted="$(cat "$(mounted_worktree_record)" 2>/dev/null || true)"
    [ -n "$mounted" ] && [ "$mounted" != "$FLTH_ROOT" ] || return 1
    recorded="$(cat "$(mounted_worktree_boot_record)" 2>/dev/null || true)"
    if [ -n "$recorded" ]; then
        current="$(engine_boot_identity)" || return 1
        [ "$recorded" = "$current" ] || return 1
    else
        pending="$(cat "$FLTH_MACHINE_DIR/up.lock/mounted-worktree" 2>/dev/null || true)"
        [ "$pending" = "$mounted" ] || return 1
        owner="$(cat "$FLTH_MACHINE_DIR/up.lock/pid" 2>/dev/null || true)"
        case "$owner" in '' | *[!0-9]*) return 1 ;; esac
        kill -0 "$owner" 2>/dev/null || return 1
    fi
    printf '%s\n' "$mounted"
}

# For a caller that knows the VM is up.
refuse_other_worktree() {
    local mounted
    mounted="$(mounted_elsewhere)" || return 0
    echo "vm: $CFG_project_name's VM has $mounted mounted at $FLTH_REPO_GUEST, and this is $FLTH_ROOT." >&2
    echo "    Nothing ran: this command would have used the other worktree's files." >&2
    echo "    Run it from that worktree, or again once that VM has stopped. 'chore vm:down' stops it, ending any run there." >&2
    exit 1
}

up_forward() {
    up_signalled="$1"
    [ -n "$up_child" ] || return 0
    kill -"$2" -- "-$up_child" 2>/dev/null || true
    [ -z "$up_killer" ] || return 0
    local monitor=0
    case "$-" in *m*) monitor=1 ;; esac
    set -m
    (
        trap - EXIT
        trap '' HUP INT TERM
        exec 6>&-
        ticks=0
        while kill -0 -- "-$up_child" 2>/dev/null && [ "$ticks" -lt 50 ]; do
            command -p sleep 0.1
            ticks=$((ticks + 1))
        done
        kill -KILL -- "-$up_child" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    up_killer=$!
    [ "$monitor" = 1 ] || set +m
}

vm_up() {
    local rc=0 up_child='' up_killer='' up_signalled=0 monitor=0 watcher
    up_lock_take
    trap 'up_forward 129 HUP' HUP
    trap 'up_forward 130 INT' INT
    trap 'up_forward 143 TERM' TERM
    mkfifo "$FLTH_MACHINE_DIR/up.lock/owner" || return
    exec 6<> "$FLTH_MACHINE_DIR/up.lock/owner"
    exec 5< "$FLTH_MACHINE_DIR/up.lock/owner"
    rm -f "$FLTH_MACHINE_DIR/up.lock/owner"
    case "$-" in *m*) monitor=1 ;; esac
    set -m
    if [ "$up_signalled" = 0 ]; then
        (
            trap - EXIT INT QUIT
            exec 6>&-
            set +m
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
        ) 0<&0 &
        up_child=$!
    fi
    exec 5<&-
    [ "$monitor" = 1 ] || set +m
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
        release_if_confirmed_stopped || true
    fi
    up_lock_drop
    trap - HUP INT TERM
    if [ "$rc" -eq 0 ] && flth_shared; then
        # Outside the lock: a consumer's setup can take many minutes, and nothing
        # about another suite joining depends on it. The guest serialises them.
        apply_setup "$([ "$PROVISION_MODE" = force ] && echo force || echo boot)" || rc=$?
    fi
    return "$rc"
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
            # every call, and a VM that is up needs nothing installed.
            refuse_other_worktree
            refuse_provisioning_boot
            if flth_shared; then
                refuse_other_boot
                return 0
            fi
            apply_setup auto || return
            forget_disk_if_setup_ran || return
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
        absent)
            # A machine that does not exist has no disk to carry anything.
            rm -f "$(base_record)" || return
            engine_forget_kernel || return
            ;;
    esac
    require_host_tools

    # TAKE THE SLOT BEFORE BOOTING, and only when actually booting. A VM
    # that is already up took it when it started, so asking again would
    # deadlock a second `up` against itself.
    "$SLOT" acquire || {
        echo "vm: could not get the VM slot; not booting a second VM." >&2
        exit 1
    }
    record_boot_invocation || return
    # Not running, so not on a provisioning boot, whatever a marker says.
    rm -f "$(provisioning_marker)" || return

    echo "[vm] booting $CFG_project_name (a first boot downloads the box and provisions)..." >&2
    # A shared guest's disk carries nobody's setup: each consumer's runs when it
    # joins, on the boot it joined, and goes with that boot.
    if flth_shared; then
        boot_vm
        return
    fi
    if [ "$PROVISION_MODE" = force ] || ! engine_kernel_known ||
        [ "$(cat "$(base_record)" 2>/dev/null || true)" != "$(sha256_of "$FLTH_ROOT/$CFG_setup_script")" ]; then
        provision_disk || return
    fi
    boot_vm || return
    apply_setup boot || return
    forget_disk_if_setup_ran
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
    if flth_shared && [ "$answered" = 0 ]; then
        echo "vm: this guest is shared, so every suite using it lost it too: $(shared_suites)." >&2
    fi
}

# A call into the guest. Keeps its status, and reports when that is ssh's own.
guest_run() {
    local rc=0 script
    script="$(guest_call "$(guest_call_script "$1")")" || return
    engine_run_held "$script" || rc=$?
    [ "$rc" -ne 255 ] || report_lost_guest
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
# THE WAIT FITS INSIDE WHAT IS WAITING ON IT. The slot's lease is renewed by
# check-memory before each attempt, and a holder with no VM is only trusted for
# FLTH_SLOT_BOOT_GRACE (180 s), so no single wait reaches that. The bound is well
# inside the up lock's wait (FLTH_UP_LOCK_WAIT_SECS), the slot's (FLTH_SLOT_WAIT),
# and the shortest job limit around a first boot in the family, 45 minutes. The
# time an attempt takes counts, so a catalog that fails slowly is bounded too.
boot_engine() {
    local attempt=1 box_spent=0 box_wait="$BOX_RETRY_FIRST_WAIT" failure started identity
    while :; do
        if ! "$SLOT" check-memory; then
            release_if_confirmed_stopped || true
            return 1
        fi
        mkdir -p "$FLTH_MACHINE_DIR" || return
        rm -f "$(mounted_worktree_boot_record)" || return
        printf '%s\n' "$FLTH_ROOT" > "$(mounted_worktree_record)" || return
        printf '%s\n' "$FLTH_ROOT" > "$FLTH_MACHINE_DIR/up.lock/mounted-worktree" || return
        started="$SECONDS"
        if engine_up "$@"; then
            if identity="$(engine_boot_identity)" && [ -n "$identity" ]; then
                printf '%s\n' "$identity" > "$(mounted_worktree_boot_record)" || return
            fi
            return 0
        fi
        if failure="$(engine_box_failure)"; then
            box_spent=$((box_spent + SECONDS - started))
            if [ "$box_spent" -ge "$BOX_RETRY_BOUND" ]; then
                echo "vm: the box could not be fetched: $failure, and was still failing after ${box_spent}s. No VM was started." >&2
                release_if_confirmed_stopped || true
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
            release_if_confirmed_stopped || true
            exit 1
        fi
        echo "[vm] boot failed, retrying in ${BOOT_RETRY_WAIT}s (attempt $attempt of $BOOT_ATTEMPTS)..." >&2
        sleep "$BOOT_RETRY_WAIT" || return
        # A half-started machine holds what the next attempt needs.
        engine_down --force >/dev/null 2>&1 || true
        attempt=$((attempt + 1))
    done
}

# THE ONLY BOOT WHOSE WRITES REACH THE DISK. Applies the setup script on
# a --persist boot, then stops it and CONFIRMS the stop before anything
# else boots: a disposable boot started over a disk still being written
# would read a half-written one. Called with the slot held.
#
# A setup script that fails leaves this boot up to be inspected, as
# before; while it is up nothing is run on it (refuse_provisioning_boot),
# because whatever a run wrote would be kept.
provision_disk() {
    local hash
    hash="$(sha256_of "$FLTH_ROOT/$CFG_setup_script")" || return
    echo "[vm] provisioning boot: applying $CFG_setup_script to the machine's disk..." >&2
    : > "$(provisioning_marker)" || return
    boot_vm --persist || return
    apply_setup "$PROVISION_MODE" || return
    if ! engine_keep_kernel; then
        echo "vm: the newest kernel on the disk could not be kept for the next boot, so the disk is not" >&2
        echo "    recorded as provisioned. The VM is left running so it can be inspected; 'chore vm:down' stops it." >&2
        exit 1
    fi
    # Graceful halt flushes the guest's caches; this makes sure of it.
    engine_run sync >/dev/null 2>&1 || true
    # The setup can have outlived the boot grace, and a waiter must not find an
    # old lease and no VM between this stop and the next boot. A failure here
    # stops nothing: the next boot refuses to start without a reservation.
    "$SLOT" renew || true
    engine_down || true
    if [ "$(engine_state)" != stopped ]; then
        echo "vm: the provisioning boot could not be confirmed stopped, so its writes are not known to be" >&2
        echo "    on the disk; nothing is booted over it. 'chore vm:status', then 'chore vm:down' or 'chore vm:destroy'." >&2
        exit 1
    fi
    rm -f "$(provisioning_marker)" || return
    printf '%s\n' "$hash" > "$(base_record)"
}

# A provisioning boot's writes are kept, so a run there would reach the
# disk every later boot starts from.
refuse_provisioning_boot() {
    [ -f "$(provisioning_marker)" ] || return 0
    echo "vm: $CFG_project_name is up on its provisioning boot, whose writes are kept on its disk," >&2
    echo "    so nothing is run there. Another 'up' may be provisioning it: try again when that is done." >&2
    echo "    If its setup failed and it was left up to be inspected, 'chore vm:down' stops it," >&2
    echo "    and the next boot provisions again." >&2
    exit 1
}

# The setup script ran on a disposable boot, so the disk does not carry
# it, whatever the record said: drop the record, and the next cold boot
# provisions.
forget_disk_if_setup_ran() {
    if [ "$SETUP_APPLIED" = 1 ]; then
        rm -f "$(base_record)" || return
    fi
    return 0
}

# Release the slot ON THE STRENGTH OF A CONFIRMED STOP, never of an
# attempt. A halt that reported success while the VM kept running must
# keep the slot, or the next repository exceeds the configured limit; and
# a state that could not be read is not a stop.
release_if_confirmed_stopped() {
    local state
    state="$(engine_state)"
    case "$state" in
        stopped | absent)
            rm -f "$(provisioning_marker)" "$(unfinished_boot_marker)"
            "$SLOT" release
            return 0
            ;;
        running)
            echo "vm: the VM is still running; the slot is kept." >&2
            ;;
        *)
            echo "vm: could not read the VM's state; the slot is kept rather than" >&2
            echo "    released on a guess. 'chore vm:status' shows it; 'chore vm:destroy' reclaims it." >&2
            ;;
    esac
    return 1
}

vm_down() {
    rm -f "$FLTH_HOLD"
    # The engine's own exit status is not the answer; the state is. This
    # runs as a chore `defer:`, where its exit status is the only thing
    # between a leaked VM and a green run.
    engine_down || true
    # A graceful halt that does not finish -- a long run's guest slow or
    # wedged at shutdown -- is forced before down gives up (#51). An
    # ordinary boot runs on a throwaway overlay, so nothing is lost by
    # forcing it.
    #
    # A PROVISIONING boot is the exception (#57): its writes are kept on
    # the disk every later boot starts from, and killing it can leave that
    # disk damaged -- measured once as a root filesystem with errors and a
    # guest that stopped in its initramfs on every boot after. So the guest
    # is synced before it is forced, and a provisioning boot that still had
    # to be forced is destroyed: the next boot provisions again from a
    # clean disk rather than trusting one that may be damaged.
    if [ "$(engine_state 2>/dev/null)" = running ]; then
        if [ -f "$(provisioning_marker)" ]; then
            engine_run sync >/dev/null 2>&1 || true
            echo "vm: the provisioning boot's graceful halt left it running; forcing it down." >&2
            engine_down --force || true
            case "$(engine_state 2>/dev/null)" in
                stopped | absent)
                    echo "vm: a provisioning boot that had to be forced may have left its disk damaged," >&2
                    echo "    so the machine is destroyed; the next boot provisions again from a clean disk." >&2
                    engine_destroy || true
                    rm -f "$(base_record)" "$FLTH_MACHINE_DIR/setup.sha256"
                    ;;
            esac
        else
            echo "vm: the graceful halt left the VM running; forcing it down." >&2
            engine_down --force || true
        fi
    fi
    if ! release_if_confirmed_stopped; then
        echo "vm: halt did not leave the VM confirmed stopped." >&2
        exit 1
    fi
}

vm_hold() {
    if engine_alive "$(engine_identity)"; then
        refuse_other_worktree
    fi
    mkdir -p "$FLTH_MACHINE_DIR"
    : > "$FLTH_HOLD"
    if engine_run "touch $FLTH_GUEST_HOLD_MARKER; shutdown -c" >/dev/null 2>&1; then
        echo "vm: held — reap will leave it up, and the guest deadline is cancelled." >&2
    else
        echo "vm: held for reap, but the guest is not reachable: its own deadline" >&2
        echo "    still stands and it will power off on schedule. Hold again once it is up." >&2
    fi
}

# The safety net, run from a chore `lifecycle: after_all`: an invocation
# cleans up only a VM it booted. Another run's idle VM is not a leak.
#
# It FAILS SOFT by design: chore reports an after_all failure without
# failing the run, and turning an unrelated `chore build` red because
# something else left a VM up would teach people to ignore it.
#
# The probe is a process check, not an engine call: it runs on every
# invocation, so it has to cost milliseconds.
vm_reap() {
    local others invocation owner mounted
    if ! engine_alive "$(engine_identity)"; then
        return 0
    fi
    if flth_shared; then
        shared_reap
        return 0
    fi
    if stop_unfinished_boot; then
        return 0
    fi
    if mounted="$(mounted_elsewhere)"; then
        echo "[vm] left running: it has $mounted mounted, and this is $FLTH_ROOT." >&2
        return 0
    fi
    if [ -f "$FLTH_HOLD" ]; then
        echo "[vm] left running: it was held with 'chore vm:hold'. 'chore vm:down' stops it." >&2
        return 0
    fi
    others="$(live_sessions)"
    if [ -n "$others" ]; then
        echo "[vm] left running: another invocation is using it (pid ${others//$'\n'/, })." >&2
        return 0
    fi
    invocation="$(chore_invocation direct)"
    if [ -n "$invocation" ]; then
        owner="$(cat "$FLTH_MACHINE_DIR/boot-invocation" 2>/dev/null || true)"
        if [ "$invocation" = unknown ] || [ "$invocation" != "$owner" ]; then
            echo '[vm] left running: another invocation owns this VM; after_all stops only its own VM.' >&2
            return 0
        fi
    fi
    echo "vm: a VM was left running by something that did not clean up — stopping it." >&2
    vm_down
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
# The same rule applies when a session ends: two sessions on one machine
# (two worktrees of one project share it) must not have the first to
# finish stop the VM under the second. The last one out brings it down.
# The markers live in the machine directory, set once a consumer is
# loaded.
sessions_dir() { printf '%s/sessions\n' "$FLTH_MACHINE_DIR"; }

process_start() {
    ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'
}

chore_invocation() {
    local pid="$PPID" command parent arguments start depth=0
    while [ "$pid" -gt 1 ] && [ "$depth" -lt 64 ]; do
        command="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//')" || { echo unknown; return 0; }
        if [ "${command##*/}" = chore ]; then
            start="$(process_start "$pid")"
            [ -n "$start" ] || { echo unknown; return 0; }
            printf '%s\t%s\n' "$pid" "$start"
            return 0
        fi
        if [ "${1:-}" = direct ]; then
            case "${command##*/}" in sh | bash | zsh) ;; *) return 0 ;; esac
            arguments="$(ps -o args= -p "$pid" 2>/dev/null)" || { echo unknown; return 0; }
            case "$arguments" in *' -c '*) ;; *) return 0 ;; esac
        fi
        parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || { echo unknown; return 0; }
        case "$parent" in '' | *[!0-9]*) break ;; esac
        [ "$parent" != "$pid" ] || break
        pid="$parent"
        depth=$((depth + 1))
    done
    return 0
}

record_boot_invocation() {
    local invocation start
    invocation="$(chore_invocation)"
    if [ -z "$invocation" ]; then
        start="$(process_start "$PPID")"
        invocation=unknown
        [ -z "$start" ] || invocation="$(printf '%s\t%s' "$PPID" "$start")"
    fi
    printf '%s\n' "$invocation" > "$FLTH_MACHINE_DIR/boot-invocation"
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
    if flth_shared; then
        shared_register "$pid" "$start"
        return 0
    fi
    printf '%s\t%s\n' "$pid" "$start" > "$(sessions_dir)/$pid"
}

#
# A HELD VM IS NOT THE SESSION'S TO STOP (#36). `chore vm:up` holds the VM
# so it outlives the invocation that booted it, and the reaper respects
# that; a session's end did not, so a test run started beside a VM a
# person was working in took it down. A session ends exactly as reap
# would treat it: a held VM stays up, and keeps its slot.
vm_session_end() {
    local pid="$1" others run=""
    if flth_shared; then
        run="$(cut -f4 "$(sessions_dir)/$pid" 2>/dev/null || true)"
    fi
    rm -f "$(sessions_dir)/$pid"
    if flth_shared; then
        shared_session_ended "$pid" "$run"
        return 0
    fi
    if stop_unfinished_boot; then
        return 0
    fi
    if [ -f "$FLTH_HOLD" ]; then
        echo "[vm] left running: it was held with 'chore vm:hold'. 'chore vm:down' stops it." >&2
        return 0
    fi
    others="$(live_sessions "$pid")"
    if [ -n "$others" ]; then
        echo "[vm] left running: another invocation is using it (pid ${others//$'\n'/, }); the last one to finish brings it down." >&2
        return 0
    fi
    # NOTHING TO HALT when no VM process is running: a test run whose
    # tests never needed the VM ends here, at the cost of a process check,
    # instead of the engine's slowest answer. The slot is still given back
    # if this machine holds it — on the same evidence the slot's waiters
    # use to call a holder dead. A process table that cannot be read (2)
    # is not that evidence, and takes the full `down`.
    local alive=0 mounted
    engine_alive "$(engine_identity)" || alive=$?
    if [ "$alive" -eq 1 ]; then
        # A guest that powered itself off also ends here, and no halt will run
        # for it, so what its boot left on the host stops now (#135).
        engine_stop_host_daemons
        "$SLOT" release
        return 0
    fi
    if mounted="$(mounted_elsewhere)"; then
        echo "[vm] left running: it has $mounted mounted, and this is $FLTH_ROOT." >&2
        return 0
    fi
    vm_down
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
    printf '%s %s %s %s' \
        "$(quote_for_guest "$FLTH_REPO_GUEST/$FLTH_SHARED_RELATIVE")" \
        "$(quote_for_guest "$FLTH_SHARE_GUEST/$FLTH_SHARED_RELATIVE/$CFG_share_dir")" \
        "$cache" "$CFG_project_name"
}

shared_in_run() {
    printf 'bash %s/run.sh enter %s %s %s\n' "$FLTH_GUEST_RUNS" "$(shared_run_id)" "$(shared_run_places)" \
        "$(quote_for_guest "$1")"
}

# Whether a call into the guest goes in the run. Off, it goes as it always has.
guest_call_script() {
    if flth_shared; then
        shared_in_run "$1"
    else
        printf '%s\n' "$1"
    fi
}

# A guest-test's run has its own copy of the tree (lib/guest-run.sh).
vm_guest_tree() {
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

# WHAT A BOOT FIXED FOR EVERYONE WHO JOINS. The guest sees one host directory and carries
# one lib/guest-run.sh. A join with another directory would mount a path that is not
# there, and one from a harness with another tool would call it with the wrong words,
# so it is refused here, where it can say why. Nobody is stopped for it: the guest is
# in use, and it can be joined with its own settings, or later by a new boot.
shared_boot_record() { printf '%s/shared-boot\n' "$FLTH_MACHINE_DIR"; }

shared_boot_identity() {
    printf '%s\t%s\n' "$FLTH_SHARED_ROOT" "$(flth_hash8 "$(cat "$FLTH_HARNESS/scripts/lib/guest-run.sh")")"
}

refuse_other_boot() {
    local recorded root
    recorded="$(cat "$(shared_boot_record)" 2>/dev/null || true)"
    [ "$recorded" != "$(shared_boot_identity)" ] || return 0
    if [ -z "$recorded" ]; then
        echo "vm: the shared guest has no record of how it was booted, so joining it is refused." >&2
    else
        root="${recorded%%$'\t'*}"
        if [ "$root" != "$FLTH_SHARED_ROOT" ]; then
            echo "vm: the shared guest was booted with FLTH_SHARED_ROOT=$root, and this call has $FLTH_SHARED_ROOT." >&2
        else
            echo "vm: the shared guest was booted by another version of the harness." >&2
        fi
    fi
    echo "    Nothing ran. Join with what it was booted with, or again once it has stopped." >&2
    exit 1
}

# A run nobody is on the list for any more: stop what it left and delete its root,
# if the guest is there to ask. Nothing depends on this having worked. What it fails
# to free goes with the boot.
shared_run_gone() {
    local run="$1" marker
    [ -n "$run" ] || return 0
    for marker in "$(sessions_dir)"/*; do
        [ -f "$marker" ] || continue
        [ "$(cut -f4 "$marker" 2>/dev/null || true)" != "$run" ] || return 0
    done
    engine_alive "$(engine_identity)" || return 0
    engine_run "bash $FLTH_GUEST_RUNS/run.sh end $run" >&2 ||
        echo "vm: run $run could not be cleaned up in the guest; what it left goes when the guest stops." >&2
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
        "$SLOT" release
    fi
    up_lock_drop
}

# `vm.sh down`. A private VM stops; a shared guest stops only if nobody is using it.
vm_shutdown() {
    local suites
    if ! flth_shared; then
        vm_down
        return
    fi
    up_lock_take
    suites="$(shared_suites)"
    if [ -n "$suites" ]; then
        echo "[vm] left running: the shared guest is in use by $suites. The last one's shutdown request stops it." >&2
    else
        vm_down
    fi
    up_lock_drop
}

shared_reap() {
    if stop_unfinished_boot; then
        return 0
    fi
    live_sessions >/dev/null
    echo "[vm] left running: the shared guest stays up for the next run. 'chore vm:down' stops it when nobody is using it." >&2
}

# Re-apply the setup script to the disk, even when unchanged. That takes a
# provisioning boot, so a running VM is stopped first — unless another
# invocation is using it, which is refused rather than pulled from under
# it. A held VM is held again afterwards.
vm_provision() {
    local held=0 others
    # A shared guest is not stopped for one consumer's setup. It runs again in place.
    if flth_shared; then
        PROVISION_MODE=force
        vm_up
        return
    fi
    if [ "$(engine_state)" = running ]; then
        refuse_other_worktree
        others="$(live_sessions)"
        if [ -n "$others" ]; then
            echo "vm: not provisioning: another invocation is using the VM (pid ${others//$'\n'/, })," >&2
            echo "    and a provisioning boot needs it stopped. Run it again once that has finished." >&2
            exit 1
        fi
        [ -f "$FLTH_HOLD" ] && held=1
        vm_down
    fi
    PROVISION_MODE=force
    vm_up
    if [ "$held" = 1 ]; then
        vm_hold
    fi
}

# The live sessions this call is not itself running inside.
other_sessions() {
    local ancestors=" " pid="$PPID" parent depth=0 session
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

# RESTART THE VM IN PLACE AND KEEP ITS SLOT (#122). The engine's own restart is
# not used: the harness has to renew the lease before the stop and confirm the
# stop before the boot, and `down` then `up` would give the slot away between
# them. The boot is an ordinary disposable one. The VM's owner does not change,
# so a reap treats it as it did before.
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
    refuse_other_worktree
    refuse_provisioning_boot
    others="$(other_sessions)"
    if [ -n "$others" ]; then
        echo "vm: not reloading: another invocation is using the VM (pid ${others//$'\n'/, })." >&2
        echo "    Run it again once that has finished." >&2
        exit 1
    fi
    require_host_tools
    "$SLOT" renew || {
        echo "vm: the VM was left running: restarting it would not keep it within the VM limit." >&2
        exit 1
    }
    engine_down || true
    if [ "$(engine_state 2>/dev/null)" = running ]; then
        echo "vm: the graceful halt left the VM running; forcing it down." >&2
        engine_down --force || true
    fi
    if [ "$(engine_state)" != stopped ]; then
        echo "vm: the VM could not be confirmed stopped, so nothing is booted beside it, and the slot is kept." >&2
        echo "    'chore vm:status', then 'chore vm:down' or 'chore vm:destroy'." >&2
        exit 1
    fi
    boot_vm || return 1
    apply_setup boot
    forget_disk_if_setup_ran
    if [ -f "$FLTH_HOLD" ]; then
        vm_hold
    fi
}

vm_destroy() {
    if flth_shared; then
        local suites
        up_lock_take
        suites="$(shared_suites)"
        if [ -n "$suites" ]; then
            echo "vm: not destroying the shared guest: it is in use by $suites." >&2
            exit 1
        fi
    fi
    rm -f "$FLTH_HOLD" "$FLTH_MACHINE_DIR/setup.sha256" "$(base_record)"
    engine_destroy || true
    if ! release_if_confirmed_stopped; then
        echo "vm: destroy did not leave the VM confirmed gone." >&2
        exit 1
    fi
    if flth_shared; then
        up_lock_drop
    fi
}

vm_status() {
    local state
    state="$(engine_state)"
    case "$state" in
        running)
            echo "vm: $CFG_project_name is running"
            local mounted
            if mounted="$(mounted_elsewhere)"; then
                echo "vm: its guest has $mounted mounted at $FLTH_REPO_GUEST, and this is $FLTH_ROOT"
            fi
            if boot_stopped_short; then
                echo "vm: its last boot did not finish, so its guest has no shares. 'chore vm:up' replaces it."
            fi
            if flth_shared; then
                echo "vm: in use by: $(shared_suites)"
            fi
            ;;
        *) echo "vm: $CFG_project_name is not running ($state)"; exit 1 ;;
    esac
}

# Run the consumer's [test] command on the host, from the repository
# root, with the VM up — and bring it down afterwards with vm-session.sh's
# rules: a failed teardown fails the run, the work's own failure wins
# when both fail, and FLTH_KEEP_VM=1 leaves the VM up.
#
# Extra arguments are appended to the command. The command reaches the
# guest through FLTH_VM (this script), so it can `run` and `put`.
vm_test() {
    [ -n "$CFG_test_command" ] ||
        flth_die "$FLTH_CONFIG has no [test] command"
    cd "$FLTH_ROOT"
    # ON A SHARED GUEST THE SESSION STAYS ABLE TO HEAR A SIGNAL. A script that sources
    # the session has its command in the foreground, so a TERM to that shell alone
    # waits for the command, for the length of the suite. Here a signal to one suite
    # has to stop it while others run, and a session running a command passes it on.
    if flth_shared; then
        FLTH_VM="$SELF" FLTH_SHARE_HOST="$FLTH_SHARE_HOST" FLTH_SHARE_GUEST="$FLTH_SHARE_GUEST" \
        FLTH_TEST_COMMAND="$CFG_test_command" \
            exec "$FLTH_HARNESS/scripts/vm-session.sh" bash -c '
                "$FLTH_VM" up || exit
                exec bash -c "$FLTH_TEST_COMMAND \"\$@\"" flth-test "$@"
            ' flth-session "$@"
    fi
    cd "$FLTH_ROOT"
    FLTH_VM="$SELF" FLTH_SHARE_HOST="$FLTH_SHARE_HOST" FLTH_SHARE_GUEST="$FLTH_SHARE_GUEST" \
    FLTH_TEST_COMMAND="$CFG_test_command" \
        exec bash -c '
            . "$1"
            shift
            "$FLTH_VM" up || exit
            bash -c "$FLTH_TEST_COMMAND \"\$@\"" flth-test "$@"
        ' flth-session "$FLTH_HARNESS/scripts/vm-session.sh" "$@"
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
# end was the end of stdin. `set -m` makes the group; it also keeps INT and QUIT
# from being ignored in the background job.
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
    members="\$(flth_members "\$1" "")"
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
set -m
"\$BASH" -c '${1//$single/$escaped}' < /dev/null &
flth_command=\$!
set +m
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
    if ! engine_alive "$(engine_identity)"; then
        echo "vm: $CFG_project_name's VM is not running, and 'exec' never boots one." >&2
        echo "    Bring it up for the run first ('chore vm:up', which also holds it)," >&2
        echo "    or use 'chore vm:run -- <command>', which boots on demand." >&2
        exit 1
    fi
    refuse_other_worktree
    refuse_provisioning_boot
    refuse_unfinished_boot
    guest_run "$*"
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
# Torn down afterwards under vm-session.sh's rules, exactly like `test`.
vm_guest_test() {
    [ -n "$CFG_test_guest_command" ] ||
        flth_die "$FLTH_CONFIG has no [test] guest_command"
    local script arg
    script="cd $(quote_for_guest "$FLTH_REPO_GUEST") && $CFG_test_guest_command"
    for arg in "$@"; do
        script="$script $(quote_for_guest "$arg")"
    done
    if flth_shared; then
        FLTH_VM="$SELF" FLTH_GUEST_SCRIPT="$script" \
            exec "$FLTH_HARNESS/scripts/vm-session.sh" bash -c '
                "$FLTH_VM" up || exit
                "$FLTH_VM" guest-tree || exit
                exec "$FLTH_VM" exec "$FLTH_GUEST_SCRIPT"
            '
    fi
    FLTH_VM="$SELF" FLTH_GUEST_SCRIPT="$script" \
        exec bash -c '
            . "$1"
            "$FLTH_VM" up || exit
            "$FLTH_VM" exec "$FLTH_GUEST_SCRIPT"
        ' flth-session "$FLTH_HARNESS/scripts/vm-session.sh"
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
cache.size=${CFG_cache_size:-none}
cache.guest=$([ -n "$CFG_cache_size" ] && echo "$FLTH_CACHE_GUEST" || echo none)
machine=$FLTH_MACHINE_DIR
shared.root=${FLTH_SHARED_ROOT:-none}
disk.setup=$(cat "$(base_record)" 2>/dev/null || echo none)
identity=$(engine_identity)
slot=$FLTH_STATE_DIR/slot.lock
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
    up | run | exec | put | share | provision | reload | test | guest-test | down | status | hold | reap | destroy | config | session-begin | session-end | boot-finished | run-id | guest-tree) ;;
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
    up) vm_up ;;
    run)
        [ $# -gt 0 ] || flth_die "usage: vm.sh run <command...>"
        vm_up
        # Joined, and run by the guest's shell: a pipeline or `&&` in the
        # command belongs to the guest, not the host.
        guest_run "$*"
        ;;
    exec)
        [ $# -gt 0 ] || flth_die "usage: vm.sh exec <command...>"
        vm_exec "$*"
        ;;
    put)
        [ $# -eq 1 ] || flth_die "usage: vm.sh put <file>"
        [ -f "$1" ] || flth_die "no such file: $1"
        if engine_alive "$(engine_identity)"; then
            refuse_other_worktree
        fi
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
    boot-finished) vm_boot_finished ;;
    run-id) shared_new_run_id ;;
    guest-tree) vm_guest_tree ;;
    session-begin | session-end)
        if [ $# -ne 1 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
            flth_die "usage: vm.sh $command <pid>"
        fi
        "vm_${command/-/_}" "$1"
        ;;
esac
