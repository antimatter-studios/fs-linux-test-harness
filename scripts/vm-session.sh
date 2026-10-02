#!/usr/bin/env bash
# shellcheck shell=bash
#
# vm-session.sh — keep the VM for the length of some work, and bring it
# down when the work finishes, however it finishes. Two ways in:
#
#   vm.sh session <command> [args...]      run a command inside a session
#   . ../fs-linux-test-harness/scripts/vm-session.sh   make the sourcing script one
#
# RUN A COMMAND INSIDE A SESSION. For a consumer's test runner, whose test
# processes boot the VM themselves from their first guest call:
#
#   exec ../fs-linux-test-harness/scripts/vm.sh session <test command> "$@"
#
# `vm.sh session` execs this file with the command; that is the public
# spelling, because a harness checkout older than it answers `vm.sh
# session` with "unknown command" — where executing an older copy of this
# file would end a session at once and never run the command at all.
#
# The VM is ONE SLOT FOR THE WHOLE MACHINE. A run that boots it and leaves
# the cleanup to chore's `after_all` reaper holds that slot whenever it was
# started some other way (the consumer's own script, a command by hand),
# and every other repository queues behind it until the guest's idle
# deadline. Run through this, the VM comes down and the slot is released
# when the command ends: passed, failed or killed.
#
# The command is the session's child, not exec'd: the trap that brings
# the VM down belongs to this shell, which has to outlive the command. A
# TERM, INT or HUP sent to this shell is passed on to the command, and the
# VM is brought down only once the command has finished with it — bash
# would otherwise run its exit trap at once, under a test process that
# would boot the VM again outside any session. Its status is the
# command's; killed by a signal, 128 plus the signal's number.
#
# NO SESSION WHERE NO VM CAN RUN. With FLTH_GUEST=1 the command is already
# inside the guest, and on a host that fails `host-tools.sh --quiet` (a CI
# runner without KVM) no VM can ever start: either way the command is
# exec'd as it is, and the engine is asked nothing. A test that needs the
# VM there fails on its own, naming what it needed.
#
# SOURCED, it makes the script that sourced it the session: an EXIT trap
# brings the VM down when that script finishes, so teardown also happens
# on failure, on a `set -e` abort and on Ctrl-C. That is how `vm.sh test`,
# `vm.sh guest-test` and a consumer's fixture build use it.
#
# `vm.sh run` and `put` boot the VM when it is not up, which is what makes
# wrappers convenient. Nothing brought it back down: every wrapper left a
# QEMU process holding gigabytes until somebody noticed, and "somebody
# noticed" was the teardown mechanism.
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
# somebody asked for. A VM held with `chore vm:up` (or `vm:hold`) is left
# running too: a session's end is not `vm:down`.
#
# The consumer is resolved when the session begins, not when the trap
# fires: the script may have changed directory by then.
#
# THE SESSION IS VISIBLE TO THE REAPER. Beginning one records the
# session's process on the machine (`vm.sh session-begin`), so `vm.sh
# reap` — which any other chore invocation runs — leaves the VM alone
# while it is alive, instead of taking an unheld VM for a leak. Ending
# runs `vm.sh session-end`, which brings the VM down unless it is held or
# another live session is still using it. A session killed outright
# leaves a marker whose process is dead, and the reaper treats that as
# the leak it is.

_flth_session_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

_flth_session_run=0
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _flth_session_run=1
    [ "${1:-}" = "--" ] && shift
    case "${1:-}" in
        '' | -h | --help)
            echo "usage: vm.sh session <command> [args...]   run a command inside a VM session" >&2
            echo "       . vm-session.sh                      make the sourcing script a session" >&2
            [ -n "${1:-}" ] && exit 0
            exit 2
            ;;
    esac
    if [ "${FLTH_GUEST:-}" = 1 ] ||
        ! "$_flth_session_scripts/host-tools.sh" --quiet >/dev/null 2>&1; then
        exec "$@"
    fi
fi

# shellcheck source=lib/config.sh
. "$_flth_session_scripts/lib/config.sh"
# `exit` when run, `return` when sourced: a `return` outside a function
# or a sourced file is an error bash reports and then carries on past.
if ! { FLTH_CONFIG="$(flth_find_config)" && export FLTH_CONFIG &&
    "$_flth_session_scripts/vm.sh" session-begin "$$"; }; then
    [ "$_flth_session_run" = 1 ] && exit 1
    return 1
fi

flth_session_end() {
    local code=$?
    # Cleared first: a failing `down` must not re-enter this.
    trap - EXIT

    if [ "${FLTH_KEEP_VM:-0}" = "1" ]; then
        echo "[vm] FLTH_KEEP_VM=1 — leaving the VM running, as asked." >&2
        exit "$code"
    fi

    if "$_flth_session_scripts/vm.sh" session-end "$$"; then
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

if [ "$_flth_session_run" = 1 ]; then
    _flth_session_child=
    _flth_session_signalled=0
    _flth_session_forward() {
        # _flth_session_forward <status to report> <signal>
        _flth_session_signalled="$1"
        [ -z "$_flth_session_child" ] || kill -"$2" "$_flth_session_child" 2>/dev/null || true
    }
    trap '_flth_session_forward 129 HUP' HUP
    trap '_flth_session_forward 130 INT' INT
    trap '_flth_session_forward 143 TERM' TERM

    # A background job is the only way to keep receiving signals while the
    # command runs. Without job control bash starts one with INT and QUIT
    # ignored and stdin from /dev/null; the reset and the explicit
    # redirection give the command what it would have had in the foreground.
    (
        trap - INT QUIT
        exec "$@"
    ) 0<&0 &
    _flth_session_child=$!

    # `wait` returns early when a trapped signal arrives; the command is
    # still running then (or not yet reaped), so wait again until it is gone.
    while :; do
        wait "$_flth_session_child"
        _flth_session_status=$?
        kill -0 "$_flth_session_child" 2>/dev/null || break
    done
    [ "$_flth_session_signalled" = 0 ] || _flth_session_status="$_flth_session_signalled"
    exit "$_flth_session_status"
fi
