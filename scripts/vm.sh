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
# NOT IN THE USAGE, AND NO CHORE TASK, ON PURPOSE: `session-begin <pid>`
# and `session-end <pid>` are vm-session.sh's plumbing, the calls that make
# a session visible to the reaper. A person has no reason to run them, so
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

usage() {
    sed -n '3,19p' "$SELF" | sed 's/^# \{0,1\}//'
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
    local mode="$1" script hash host_stamp guest force=0 payload out
    script="$FLTH_ROOT/$CFG_setup_script"
    hash="$(sha256_of "$script")"
    host_stamp="$FLTH_MACHINE_DIR/setup.sha256"

    if [ "$mode" = auto ] && [ "$(cat "$host_stamp" 2>/dev/null || true)" = "$hash" ]; then
        return 0
    fi
    [ "$mode" = force ] && force=1
    payload="$(base64 < "$script")"
    SETUP_APPLIED=0

    guest="set -euo pipefail
stamp=/var/lib/fs-linux-test-harness/setup.sha256
if [ $force = 0 ] && [ \"\$(cat \"\$stamp\" 2>/dev/null || true)\" = '$hash' ]; then
    exit 0
fi
echo '[vm] running setup script $CFG_setup_script' >&2
tmp=\"\$(mktemp)\"
printf '%s\n' '$payload' | base64 -d > \"\$tmp\"
FLTH_PROJECT='$CFG_project_name' FLTH_SHARE='$FLTH_SHARE_GUEST' bash \"\$tmp\" </dev/null >&2
rm -f \"\$tmp\"
mkdir -p \"\$(dirname \"\$stamp\")\"
printf '%s\n' '$hash' > \"\$stamp\"
echo applied"

    if ! out="$(engine_run "$guest")"; then
        rm -f "$host_stamp"
        echo "vm: the setup script ($CFG_setup_script) failed inside the VM." >&2
        echo "    The VM is left running so it can be inspected; 'chore vm:down' stops it." >&2
        exit 1
    fi
    printf '%s\n' "$hash" > "$host_stamp"
    [ "$out" = applied ] && SETUP_APPLIED=1
    return 0
}

vm_up() {
    local state
    state="$(engine_state)"
    case "$state" in
        running)
            # No host-tool check on this path: `run` comes through here on
            # every call, and a VM that is up needs nothing installed.
            refuse_provisioning_boot
            apply_setup auto
            forget_disk_if_setup_ran
            return 0
            ;;
        unknown)
            # A missing engine is the likeliest reason a state cannot be
            # read, so say that first if it is so. Then refuse: booting on
            # a state nobody could read is how a second VM starts beside
            # the first.
            require_host_tools
            echo "vm: could not read the VM's state; not booting until it can be read." >&2
            exit 1
            ;;
        absent)
            # A machine that does not exist has no disk to carry anything.
            rm -f "$(base_record)"
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
    # Not running, so not on a provisioning boot, whatever a marker says.
    rm -f "$(provisioning_marker)"

    echo "[vm] booting $CFG_project_name (a first boot downloads the box and provisions)..." >&2
    if [ "$PROVISION_MODE" = force ] ||
        [ "$(cat "$(base_record)" 2>/dev/null || true)" != "$(sha256_of "$FLTH_ROOT/$CFG_setup_script")" ]; then
        provision_disk
    fi
    boot_engine
    apply_setup boot
    forget_disk_if_setup_ran
}

# Boot, retrying.
#
# RETRIED, because the forwarded SSH port is not always free the instant
# a previous machine stops (`Could not set up host forwarding rule`).
# Waiting for the port to look free does not work — `lsof` reports it
# free while QEMU still cannot bind it — so the retry is where the
# failure happens, and covers causes nobody has guessed.
boot_engine() {
    local attempt=1
    while ! engine_up "$@"; do
        if [ "$attempt" -ge "$BOOT_ATTEMPTS" ]; then
            echo "vm: the VM would not boot after $BOOT_ATTEMPTS attempts." >&2
            release_if_confirmed_stopped || true
            exit 1
        fi
        echo "[vm] boot failed, retrying in ${BOOT_RETRY_WAIT}s (attempt $attempt of $BOOT_ATTEMPTS)..." >&2
        sleep "$BOOT_RETRY_WAIT"
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
    hash="$(sha256_of "$FLTH_ROOT/$CFG_setup_script")"
    echo "[vm] provisioning boot: applying $CFG_setup_script to the machine's disk..." >&2
    : > "$(provisioning_marker)"
    boot_engine --persist
    apply_setup "$PROVISION_MODE"
    # Graceful halt flushes the guest's caches; this makes sure of it.
    engine_run sync >/dev/null 2>&1 || true
    engine_down || true
    if [ "$(engine_state)" != stopped ]; then
        echo "vm: the provisioning boot could not be confirmed stopped, so its writes are not known to be" >&2
        echo "    on the disk; nothing is booted over it. 'chore vm:status', then 'chore vm:down' or 'chore vm:destroy'." >&2
        exit 1
    fi
    rm -f "$(provisioning_marker)"
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
    [ "$SETUP_APPLIED" = 1 ] && rm -f "$(base_record)"
    return 0
}

# Release the slot ON THE STRENGTH OF A CONFIRMED STOP, never of an
# attempt. A halt that reported success while the VM kept running must
# keep the slot, or the next repository boots a second VM beside it; and
# a state that could not be read is not a stop.
release_if_confirmed_stopped() {
    local state
    state="$(engine_state)"
    case "$state" in
        stopped | absent)
            rm -f "$(provisioning_marker)"
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
    if ! release_if_confirmed_stopped; then
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

# The safety net, run from a chore `lifecycle: after_all` so ANY chore
# invocation cleans up a VM that nothing else did — a test run that
# booted it, a run killed outright.
#
# It FAILS SOFT by design: chore reports an after_all failure without
# failing the run, and turning an unrelated `chore build` red because
# something else left a VM up would teach people to ignore it.
#
# The probe is a process check, not an engine call: it runs on every
# invocation, so it has to cost milliseconds.
vm_reap() {
    local others
    if ! engine_alive "$(engine_identity)"; then
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
# by any other chore invocation (another terminal, another agent,
# another worktree of the same project), stopped it mid-build.
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

# The pids of live sessions on this machine, one per line, except $1.
# Markers whose process is gone are removed on the way.
live_sessions() {
    local except="${1:-}" dir marker pid start now
    dir="$(sessions_dir)"
    [ -d "$dir" ] || return 0
    for marker in "$dir"/*; do
        [ -f "$marker" ] || continue
        IFS=$'\t' read -r pid start < "$marker" || true
        case "$pid" in '' | *[!0-9]*) rm -f "$marker"; continue ;; esac
        [ "$pid" = "$except" ] && continue
        now="$(process_start "$pid")"
        if [ -z "$now" ] || [ "$now" != "$start" ]; then
            rm -f "$marker"
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
    printf '%s\t%s\n' "$pid" "$start" > "$(sessions_dir)/$pid"
}

#
# A HELD VM IS NOT THE SESSION'S TO STOP (#36). `chore vm:up` holds the VM
# so it outlives the invocation that booted it, and the reaper respects
# that; a session's end did not, so a test run started beside a VM a
# person was working in took it down. A session ends exactly as reap
# would treat it: a held VM stays up, and keeps its slot.
vm_session_end() {
    local pid="$1" others
    rm -f "$(sessions_dir)/$pid"
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
    local alive=0
    engine_alive "$(engine_identity)" || alive=$?
    if [ "$alive" -eq 1 ]; then
        "$SLOT" release
        return 0
    fi
    vm_down
}

# Re-apply the setup script to the disk, even when unchanged. That takes a
# provisioning boot, so a running VM is stopped first — unless another
# invocation is using it, which is refused rather than pulled from under
# it. A held VM is held again afterwards.
vm_provision() {
    local held=0 others
    if [ "$(engine_state)" = running ]; then
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

vm_destroy() {
    rm -f "$FLTH_HOLD" "$FLTH_MACHINE_DIR/setup.sha256" "$(base_record)"
    engine_destroy || true
    if ! release_if_confirmed_stopped; then
        echo "vm: destroy did not leave the VM confirmed gone." >&2
        exit 1
    fi
}

vm_status() {
    local state
    state="$(engine_state)"
    case "$state" in
        running) echo "vm: $CFG_project_name is running" ;;
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
# deadline can fall up to a minute early. A held guest (`vm.sh hold`) is
# never re-armed. --no-wall, because a person in the guest does not need
# a broadcast a minute.
#
# It never fails the call: a guest whose timer could not be re-armed
# keeps the one it had, which is the behaviour before this existed.
REARM_WINDOW_SECS=60
guest_call() {
    cat <<EOF
flth_rearm() {
    local now last=0
    [ -f $FLTH_GUEST_HOLD_MARKER ] && return 0
    printf -v now '%(%s)T' -1
    { read -r last < $FLTH_GUEST_REARM_STAMP; } 2>/dev/null || true
    case "\$last" in '' | *[!0-9]*) last=0 ;; esac
    [ \$((now - last)) -ge $REARM_WINDOW_SECS ] || return 0
    printf '%s\n' "\$now" > $FLTH_GUEST_REARM_STAMP
    shutdown --no-wall -h +$CFG_vm_deadline_minutes >/dev/null 2>&1 ||
        echo "vm: could not re-arm the guest's poweroff deadline; the previous one stands" >&2
}
flth_rearm
trap flth_rearm EXIT
$1
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
    refuse_provisioning_boot
    engine_run "$(guest_call "$*")"
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
    up | run | exec | put | share | provision | test | guest-test | down | status | hold | reap | destroy | config | session-begin | session-end) ;;
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
        engine_run "$(guest_call "$*")"
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
    test) vm_test "$@" ;;
    guest-test) vm_guest_test "$@" ;;
    down) vm_down ;;
    status) vm_status ;;
    hold) vm_hold ;;
    reap) vm_reap ;;
    destroy) vm_destroy ;;
    config) vm_config ;;
    session-begin | session-end)
        if [ $# -ne 1 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
            flth_die "usage: vm.sh $command <pid>"
        fi
        "vm_${command/-/_}" "$1"
        ;;
esac
