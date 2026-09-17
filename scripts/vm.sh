#!/usr/bin/env bash
#
# vm.sh — drive a consumer's Linux test VM.
#
#   vm.sh up               boot (idempotent) and apply the consumer's setup
#   vm.sh run <cmd...>     boot if needed, run a command as root in the guest
#   vm.sh put <file>       copy a file into the shared directory; print its guest path
#   vm.sh share            print the host path of the shared directory
#   vm.sh provision        boot if needed, re-run the setup script unconditionally
#   vm.sh test [args...]   boot, run the consumer's [test] command, tear down
#   vm.sh down             halt, confirm it stopped, release the slot
#   vm.sh status           exit 0 when the VM is running, 1 otherwise
#   vm.sh hold             keep the VM up: reap leaves it, the guest deadline is cancelled
#   vm.sh reap             stop a VM nothing cleaned up (the safety net)
#   vm.sh destroy          delete the VM and its disk, release the slot
#   vm.sh config           print the resolved configuration
#
# The consumer is found from fs-linux-test-harness.toml in the working
# directory or a parent, or from FLTH_CONFIG. See README.md.
#
# The VM is kept running between invocations on purpose: booting is the
# slow part, and an iterate-and-check loop should pay it once. What stops
# it is, in order: `down` (a chore `defer:` or vm-session.sh), `reap` (a
# chore `after_all`), and the guest's own poweroff deadline.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
. "$(dirname "$SELF")/lib/common.sh"

SLOT="$FLTH_HARNESS/scripts/vm-slot.sh"
HOST_TOOLS="$FLTH_HARNESS/scripts/host-tools.sh"
BOOT_ATTEMPTS=3
BOOT_RETRY_WAIT=5

usage() {
    sed -n '3,16p' "$SELF" | sed 's/^# \{0,1\}//'
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
    local mode="$1" script hash host_stamp guest force=0 payload
    script="$FLTH_ROOT/$CFG_setup_script"
    hash="$(sha256_of "$script")"
    host_stamp="$FLTH_MACHINE_DIR/setup.sha256"

    if [ "$mode" = auto ] && [ "$(cat "$host_stamp" 2>/dev/null || true)" = "$hash" ]; then
        return 0
    fi
    [ "$mode" = force ] && force=1
    payload="$(base64 < "$script")"

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
printf '%s\n' '$hash' > \"\$stamp\""

    if ! engine_run "$guest"; then
        rm -f "$host_stamp"
        echo "vm: the setup script ($CFG_setup_script) failed inside the VM." >&2
        echo "    The VM is left running so it can be inspected; 'chore vm:down' stops it." >&2
        exit 1
    fi
    printf '%s\n' "$hash" > "$host_stamp"
}

vm_up() {
    local state attempt
    state="$(engine_state)"
    case "$state" in
        running)
            # No host-tool check on this path: `run` comes through here on
            # every call, and a VM that is up needs nothing installed.
            apply_setup auto
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
    esac
    require_host_tools

    # TAKE THE SLOT BEFORE BOOTING, and only when actually booting. A VM
    # that is already up took it when it started, so asking again would
    # deadlock a second `up` against itself.
    "$SLOT" acquire || {
        echo "vm: could not get the VM slot; not booting a second VM." >&2
        exit 1
    }

    echo "[vm] booting $CFG_project_name (a first boot downloads the box and provisions)..." >&2
    # RETRIED, because the forwarded SSH port is not always free the
    # instant a previous machine stops (`Could not set up host forwarding
    # rule`). Waiting for the port to look free does not work — `lsof`
    # reports it free while QEMU still cannot bind it — so the retry is
    # where the failure happens, and covers causes nobody has guessed.
    attempt=1
    while ! engine_up; do
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

    apply_setup boot
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
# invocation cleans up a VM that nothing else did — a bare `cargo test`
# that booted it, a run killed outright.
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
    if [ -f "$FLTH_HOLD" ]; then
        echo "[vm] left running: it was held with 'chore vm:hold'. 'chore vm:down' stops it." >&2
        return 0
    fi
    echo "vm: a VM was left running by something that did not clean up — stopping it." >&2
    vm_down
}

vm_destroy() {
    rm -f "$FLTH_HOLD" "$FLTH_MACHINE_DIR/setup.sha256"
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
setup.script=$CFG_setup_script
test.command=$CFG_test_command
machine=$FLTH_MACHINE_DIR
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
    up | run | put | share | provision | test | down | status | hold | reap | destroy | config) ;;
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
        engine_run "$*"
        ;;
    put)
        [ $# -eq 1 ] || flth_die "usage: vm.sh put <file>"
        [ -f "$1" ] || flth_die "no such file: $1"
        engine_copy "$1"
        ;;
    share) echo "$FLTH_SHARE_HOST" ;;
    provision) vm_up; apply_setup force ;;
    test) vm_test "$@" ;;
    down) vm_down ;;
    status) vm_status ;;
    hold) vm_hold ;;
    reap) vm_reap ;;
    destroy) vm_destroy ;;
    config) vm_config ;;
esac
