#!/usr/bin/env bash
# shellcheck shell=bash
#
# vm-session.sh — one run on the shared guest, for the length of some work, ended
# when the work finishes, however it finishes. Two ways in:
#
#   vm.sh session <command> [args...]      run a command inside a session
#   . ../fs-linux-test-harness/scripts/vm-session.sh   make the sourcing script one
#
# RUN A COMMAND INSIDE A SESSION. For a consumer's test runner, whose test
# processes boot the guest themselves from their first guest call:
#
#   exec ../fs-linux-test-harness/scripts/vm.sh session <test command> "$@"
#
# `vm.sh session` execs this file with the command; that is the public
# spelling, because a harness checkout older than it answers `vm.sh
# session` with "unknown command" — where executing an older copy of this
# file would end a session at once and never run the command at all.
#
# A SESSION IS A RUN (#153). Its id is in the environment of everything the session
# starts, so every call into the guest finds the run's own root and mounts, and a
# session inside a session belongs to the same run. When the session ends, what the
# run left in the guest is cleaned up and the run leaves the list of suites using
# the guest. The guest itself stays up for the next run, of this consumer or another:
# `chore vm:down` stops it when nobody is using it, and its idle deadline does when
# nobody asks.
#
# The command is the session's child, not exec'd: the trap that ends the run
# belongs to this shell, which has to outlive the command. A TERM, INT or HUP sent
# to this shell is passed on to the command, and the run ends only once the
# command has finished with it — bash would otherwise run its exit trap at once,
# under a test process that would go on calling into the guest outside any run.
# Its status is the command's; killed by a signal, 128 plus the signal's number.
#
# NO SESSION WHERE NO VM CAN RUN. With FLTH_GUEST=1 the command is already
# inside the guest, and on a host that fails `host-tools.sh --quiet` (a CI
# runner without KVM) no VM can ever start: either way the command is
# exec'd as it is, and the engine is asked nothing. A test that needs the
# VM there fails on its own, naming what it needed.
#
# SOURCED, it makes the script that sourced it the session: an EXIT trap ends
# the run when that script finishes, so the end also happens on failure, on a
# `set -e` abort and on Ctrl-C. That is how a consumer's fixture build uses it.
#
# A BOOT THAT DID NOT FINISH IS STOPPED when the session ends (#134): that guest has
# no shares. A FAILING STOP FAILS THE SCRIPT, even when the work succeeded, and when
# the work ALSO failed, the work's status wins: it is the more informative failure,
# and both are printed.
#
# THE SESSION IS VISIBLE TO THE REAPER AND TO `down`. Beginning one records the
# session's process on the machine (`vm.sh session-begin`), so `vm.sh down` leaves
# the guest up while it is alive. A session killed outright leaves a marker whose
# process is dead, and the next look at the list drops it.

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
    FLTH_RUN_ID="$("$_flth_session_scripts/vm.sh" run-id)" && export FLTH_RUN_ID &&
    "$_flth_session_scripts/vm.sh" session-begin "$$"; }; then
    [ "$_flth_session_run" = 1 ] && exit 1
    return 1
fi

flth_session_end() {
    local code=$?
    # Cleared first: a failing `down` must not re-enter this.
    trap - EXIT

    # An interrupted run is not to be read as a failure of what it was testing (#190).
    if [ "$("$_flth_session_scripts/vm.sh" watchdog-told "$$")" = told ]; then
        code=75
    fi

    if "$_flth_session_scripts/vm.sh" session-end "$$"; then
        exit "$code"
    fi

    echo "vm: THE SESSION'S END FAILED — a guest whose boot did not finish is still running" >&2
    echo "    (or could not be confirmed stopped). 'chore vm:status', then 'chore vm:down'" >&2
    echo "    or 'chore vm:destroy'." >&2
    if [ "$code" -eq 0 ]; then
        exit 1
    fi
    echo "vm: the work had already failed with status $code." >&2
    exit "$code"
}

trap flth_session_end EXIT

# Only the traps below call this. It stays outside the branch because ShellCheck
# does not read a trap's command, and counts a function as used only when it is
# still defined where the script ends, which that branch never reaches.
# A PROCESS GROUP IS MADE FROM ONE SIDE (#209). Job control (`set -m`) makes a
# background job's group from both sides at once, the shell and the child, as
# POSIX asks; on macOS the two calls race, the child's fails with EPERM although
# the group is made, and Bash prints "child setpgid ... Operation not permitted"
# into the session's stderr. So the command and the escalation below are started
# by Perl, which makes the group in the child alone and then runs them. The group
# exists only once the child has made it, so until then the command is signalled
# by its pid. Job control a caller turned on is off while they start.
#
# The command: INT and QUIT back to their defaults first, since a background job
# without job control starts with them ignored, then its group, then the command,
# with the status Bash's `exec` gives a command it cannot run.
_flth_session_own_group='$SIG{INT} = $SIG{QUIT} = "DEFAULT";
setpgrp(0, 0) or die "vm: the command has no process group of its own: $!\n";
exec { $ARGV[0] } @ARGV;
print STDERR "vm: $ARGV[0]: $!\n";
exit($!{ENOENT} ? 127 : 126);'
# Escalation: KILL to what is left of the group after 50 ticks of 0.1 seconds. By
# the pid only while the group has not been seen: once it has, the pid is its.
_flth_session_killer_script='setpgrp(0, 0); my ($child, $seen) = (shift, 0);
for (1 .. 50) {
    if (kill 0, -$child) { $seen = 1 } elsif ($seen || !kill 0, $child) { last }
    select undef, undef, undef, 0.1;
}
kill "KILL", -$child;
kill "KILL", $child unless $seen;'

_flth_session_forward() {
    # _flth_session_forward <status to report> <signal>
    _flth_session_signalled="$1"
    [ -n "$_flth_session_child" ] || return 0
    kill -"$2" -- "-$_flth_session_child" 2>/dev/null || kill -"$2" "$_flth_session_child" 2>/dev/null || true
    [ -z "$_flth_session_killer" ] || return 0
    local monitor=0
    case "$-" in *m*) monitor=1 && set +m ;; esac
    (
        trap '' HUP INT TERM
        exec perl -e "$_flth_session_killer_script" "$_flth_session_child"
    ) >/dev/null 2>&1 &
    _flth_session_killer=$!
    [ "$monitor" = 0 ] || set -m
}

if [ "$_flth_session_run" = 1 ]; then
    _flth_session_child=
    _flth_session_killer=
    _flth_session_signalled=0
    trap '_flth_session_forward 129 HUP' HUP
    trap '_flth_session_forward 130 INT' INT
    trap '_flth_session_forward 143 TERM' TERM

    _flth_session_monitor=0
    case "$-" in *m*) _flth_session_monitor=1 && set +m ;; esac
    [ "$_flth_session_signalled" = 0 ] || exit "$_flth_session_signalled"
    # A background job is the only way to keep receiving signals while the
    # command runs. Perl gives it back INT and QUIT, which Bash 3.2 cannot:
    # resetting a background job's traps does not restore them there. The
    # explicit redirection preserves the command's foreground stdin.
    perl -e "$_flth_session_own_group" -- "$@" 0<&0 &
    _flth_session_child=$!
    [ "$_flth_session_monitor" = 0 ] || set -m
    if [ "$_flth_session_signalled" != 0 ]; then
        case "$_flth_session_signalled" in
            129) _flth_session_forward 129 HUP ;;
            130) _flth_session_forward 130 INT ;;
            143) _flth_session_forward 143 TERM ;;
        esac
    fi

    # `wait` returns early when a trapped signal arrives; the command is
    # still running then (or not yet reaped), so wait again until it is gone.
    while :; do
        wait "$_flth_session_child"
        _flth_session_status=$?
        kill -0 "$_flth_session_child" 2>/dev/null || break
    done
    if [ -n "$_flth_session_killer" ]; then
        while kill -0 "$_flth_session_killer" 2>/dev/null; do
            wait "$_flth_session_killer" || true
        done
    fi
    [ "$_flth_session_signalled" = 0 ] || _flth_session_status="$_flth_session_signalled"
    exit "$_flth_session_status"
else
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi
