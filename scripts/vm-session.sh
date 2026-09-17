# shellcheck shell=bash
#
# vm-session.sh — bring the VM down when the script that sourced this one
# finishes, however it finishes.
#
#   . ../fs-linux-test-harness/scripts/vm-session.sh
#
# `vm.sh run` and `put` boot the VM when it is not up, which is what makes
# wrappers convenient. Nothing brought it back down: every wrapper left a
# QEMU process holding gigabytes until somebody noticed, and "somebody
# noticed" was the teardown mechanism. Sourcing this installs an EXIT
# trap, so teardown also happens on failure, on a `set -e` abort and on
# Ctrl-C.
#
# A FAILING TEARDOWN FAILS THE SCRIPT, even when the work succeeded. A VM
# that would not stop is the condition this exists to prevent, and
# reporting success while it runs is how it went unnoticed. `vm.sh down`
# confirms the stop rather than trusting the engine, so a failure here
# means it really is still up (or could not be confirmed down).
#
# When the work ALSO failed, the work's status wins: it is the more
# informative failure, and both are printed.
#
# KEEPING IT UP ON PURPOSE:
#
#   FLTH_KEEP_VM=1 ./scripts/build-fixtures.sh
#
# for several runs back to back, where booting each time is the slow
# part. It says so on the way out, so a VM left running is always one
# somebody asked for.
#
# The consumer is resolved when this is sourced, not when the trap fires:
# the script may have changed directory by then.

_flth_session_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/config.sh
. "$_flth_session_scripts/lib/config.sh"
FLTH_CONFIG="$(flth_find_config)" || return 1
export FLTH_CONFIG

flth_session_end() {
    local code=$?
    # Cleared first: a failing `down` must not re-enter this.
    trap - EXIT

    if [ "${FLTH_KEEP_VM:-0}" = "1" ]; then
        echo "[vm] FLTH_KEEP_VM=1 — leaving the VM running, as asked." >&2
        exit "$code"
    fi

    if "$_flth_session_scripts/vm.sh" down; then
        exit "$code"
    fi

    echo "vm: TEARDOWN FAILED — the VM is still running (or could not be confirmed" >&2
    echo "    stopped) and is still using memory. 'chore vm:status', then 'chore vm:down'" >&2
    echo "    or 'chore vm:destroy'." >&2
    if [ "$code" -eq 0 ]; then
        exit 1
    fi
    echo "vm: the work had already failed with status $code." >&2
    exit "$code"
}

trap flth_session_end EXIT
