# shellcheck shell=bash
#
# lib/common.sh — where things live, for every script in the harness.
#
# Sourced, never executed. Loading a consumer is separate from sourcing
# this file so that a command which needs no consumer (`vm-slot.sh
# status`, the usage text) never fails for want of one.

FLTH_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# shellcheck source=config.sh
. "$FLTH_HARNESS/scripts/lib/config.sh"
# shellcheck source=engine.sh
. "$FLTH_HARNESS/scripts/lib/engine.sh"

# Machines, their disks and the firmware links are CACHE: regenerable,
# large, and nothing a repository should carry. The slot lock is STATE:
# small, and its whole meaning is that it is shared by every repository
# on the machine, so it lives outside all of them.
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
#   FLTH_MACHINE_DIR  this consumer's machine: engine state, hold marker,
#                     setup stamp
#   FLTH_HOLD         the hold marker
#
# The machine directory is keyed by [project] name, so two checkouts of
# one project share a machine and two projects never do.
# shellcheck disable=SC2034  # read by the scripts that source this
flth_load() {
    FLTH_CONFIG="$(flth_find_config)" || return 1
    export FLTH_CONFIG
    flth_config_load "$FLTH_CONFIG" || return 1
    FLTH_SHARE_HOST="$FLTH_ROOT/$CFG_share_dir"
    FLTH_MACHINE_DIR="$FLTH_CACHE_DIR/machines/$CFG_project_name"
    FLTH_HOLD="$FLTH_MACHINE_DIR/keep-running"
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
