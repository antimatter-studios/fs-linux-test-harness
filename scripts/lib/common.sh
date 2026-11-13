# shellcheck shell=bash
#
# lib/common.sh — where things live, for every script in the harness.
#
# Sourced, never executed. Loading a consumer is separate from sourcing
# this file so that a command which needs no consumer (the usage text)
# never fails for want of one.

FLTH_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# shellcheck source=scripts/lib/config.sh
. "$FLTH_HARNESS/scripts/lib/config.sh"
# shellcheck source=scripts/lib/engine.sh
. "$FLTH_HARNESS/scripts/lib/engine.sh"
# shellcheck source=scripts/lib/profile.sh
. "$FLTH_HARNESS/scripts/lib/profile.sh"

# Machines, their disks and the firmware links are CACHE: regenerable,
# large, and nothing a repository should carry. Sockets and Vagrant's
# temporary directory are STATE: small, and on a path short enough for a
# socket, outside every repository.
FLTH_CACHE_DIR="${FLTH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fs-linux-test-harness}"
FLTH_STATE_DIR="${FLTH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fs-linux-test-harness}"

flth_die() {
    echo "fs-linux-test-harness: $*" >&2
    exit 1
}

# Find and load the consumer, then derive every path from it.
#
#   FLTH_CONFIG       absolute path of the consumer's config
#   FLTH_ROOT         the consumer repository
#   FLTH_SHARE_HOST   the shared directory, host side
#   FLTH_MACHINE_DIR  the shared guest's machine: engine state, hold
#                     marker, setup stamps
#   FLTH_HOLD         the hold marker
#
# The machine directory is keyed by the resolved run profile, or by the
# guest release for consumers using its default kernel (flth_shared_load).
# shellcheck disable=SC2034  # read by the scripts that source this
flth_load() {
    FLTH_CONFIG="$(flth_find_config)" || return 1
    export FLTH_CONFIG
    flth_config_load "$FLTH_CONFIG" || return 1
    flth_profile_load || return 1
    FLTH_SHARE_HOST="$FLTH_ROOT/$CFG_share_dir"
    flth_shared_load || return 1
    FLTH_MACHINE_DIR="$FLTH_CACHE_DIR/machines/$FLTH_MACHINE_NAME"
    FLTH_HOLD="$FLTH_MACHINE_DIR/keep-running"
}

# THE SHARED GUEST (#153, #220, #222). Suites with the same run environment use
# one guest. The machine is therefore nobody's: it is named for its profile (or
# its default guest release), and what a
# consumer's [vm] section says about memory, CPUs, disk, the SSH port and the
# deadline is not read. A host with other needs says so here.
FLTH_SHARED_MEMORY_DEFAULT=8G
FLTH_SHARED_CPUS_DEFAULT=8
FLTH_SHARED_DISK_DEFAULT=64G
FLTH_SHARED_SSH_PORT=50200
FLTH_SHARED_DEADLINE_MINUTES=480

# THE GUEST SEES NO HOST DIRECTORY OF ITS OWN (#222). Each run attaches its own
# tree to the running guest (lib/engine.sh, engine_attach_tree), so a tree anywhere
# on the host can be tested, and there is no root to set or derive.
# shellcheck disable=SC2034  # read by the scripts that source this
flth_shared_load() {
    # Where the /cache a consumer asks for is: a directory of the guest's in a run,
    # not a disk of the machine's.
    FLTH_SHARED_CACHE="$CFG_cache_size"
    CFG_cache_size=""
    FLTH_MACHINE_NAME="shared-$CFG_vm_guest"
    [ -z "$FLTH_PROFILE_ID" ] || FLTH_MACHINE_NAME="$FLTH_MACHINE_NAME-p${FLTH_PROFILE_ID:0:20}"
    CFG_vm_memory="${FLTH_SHARED_MEMORY:-$FLTH_SHARED_MEMORY_DEFAULT}"
    CFG_vm_cpus="${FLTH_SHARED_CPUS:-$FLTH_SHARED_CPUS_DEFAULT}"
    CFG_vm_disk="${FLTH_SHARED_DISK:-$FLTH_SHARED_DISK_DEFAULT}"
    CFG_vm_ssh_port="$FLTH_SHARED_SSH_PORT"
    CFG_vm_deadline_minutes="${FLTH_SHARED_DEADLINE:-$FLTH_SHARED_DEADLINE_MINUTES}"
    case "$CFG_vm_deadline_minutes" in
        '' | *[!0-9]*)
            flth_config_error "FLTH_SHARED_DEADLINE must be a whole number of minutes, got $CFG_vm_deadline_minutes"
            return 1 ;;
    esac
    case "${FLTH_SHARED_SLOTS:-32}" in
        [1-9] | [1-5][0-9] | 6[0-4]) ;;
        *)
            flth_config_error "FLTH_SHARED_SLOTS must be a whole number from 1 to 64, got $FLTH_SHARED_SLOTS"
            return 1 ;;
    esac
    flth_config_validate "$FLTH_CONFIG"
}

# The guest path of the shared directory. Fixed, not configurable: every
# consumer script and every `put` answer is written against it.
FLTH_SHARE_GUEST="/share"

# The guest path of the CONSUMER REPOSITORY itself, mounted read-write on
# every boot. Fixed for the same reason as the share: a consumer's guest
# command (`vm.sh guest-test`) names paths inside it, and a path that
# moved with configuration would be a path every consumer has to compute.
#
# It is what makes a suite runnable IN the guest: the sources are there,
# so a host that is not Linux — or has none of the tooling — still runs
# the same tests against the same tree.
# shellcheck disable=SC2034  # read by vm.sh
FLTH_REPO_GUEST="/repo"

# The guest path of a consumer's DECLARED CACHE ([cache] size), mounted on
# every boot of a consumer that declares one and absent otherwise. Fixed
# for the same reason as the share: a consumer's suite points its build
# state there by name.
#
# It is the one place a run's writes outlive the boot that made them.
# Everything else a disposable boot writes is thrown away when it stops
# (lib/engine.sh, engine_up); this is a disk of its own, outside that
# overlay, so a build directory or package cache kept here is
# incremental from one run to the next. The harness provides the place
# and knows nothing about what is kept in it.
# shellcheck disable=SC2034  # read by vm.sh
FLTH_CACHE_GUEST="/cache"

# Eight hex characters of a string, for names that must be short.
flth_hash8() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -c1-8
    else
        printf '%s' "$1" | shasum -a 256 | cut -c1-8
    fi
}

# shellcheck disable=SC2034  # read by vm.sh
# Marks the guest as deliberately kept up. On tmpfs, so it lasts exactly
# as long as the boot it was granted on.
FLTH_GUEST_HOLD_MARKER="/run/fs-linux-test-harness-held"

# shellcheck disable=SC2034  # read by vm.sh
# When a call last re-armed the guest's poweroff deadline, in epoch
# seconds. On tmpfs with the hold marker, for the same reason.
FLTH_GUEST_REARM_STAMP="/run/fs-linux-test-harness-rearmed"

# shellcheck disable=SC2034  # read by vm.sh
# Where lib/guest-run.sh goes on a shared guest, for the length of a boot.
FLTH_GUEST_RUNS="/run/fs-linux-test-harness-runs"

# flth_run_holding_stdin <text> <command...>
#
# Run a command whose stdin is <text> and then stays open for as long as this
# process lives, with no end-of-file while it does. The write end is held by this
# process alone, not by the command or by a helper, so the kernel closes it however
# this process ends, KILL included, and the command then reads end-of-file. A
# signal needs no trap here and leaves nothing behind on the host.
#
# A FIFO because Bash 3.2 has no other way to hold one end of a pipe while the
# command's status stays readable. It is unlinked as soon as both ends are open.
# The text is written in the background: it can be longer than a pipe holds.
flth_run_holding_stdin() {
    local text="$1" fifo rc=0 writer
    shift
    fifo="$FLTH_MACHINE_DIR/held-stdin.$$.$RANDOM"
    mkfifo "$fifo" || return 1
    exec 8<> "$fifo"
    exec 7< "$fifo"
    rm -f "$fifo"
    ( printf '%s\n' "$text" >&8 ) 7<&- &
    writer=$!
    "$@" <&7 7<&- 8>&- || rc=$?
    exec 7<&- 8>&-
    wait "$writer" 2>/dev/null || true
    return "$rc"
}
