# shellcheck shell=bash
#
# lib/apt.sh — apt-get for setting up a CI runner, bounded (#77).
#
# Sourced, never executed. On 2026-10-22 a stalled package mirror held
# ci-setup-linux.sh's QEMU group for up to 26 minutes, printing nothing,
# and cancelled fixture jobs with their budget spent. So each call:
#
#   - retries a failed fetch, and gives up on a connection that goes
#     silent, through apt's own Acquire::Retries and Acquire::http(s)::Timeout;
#   - is bounded as a whole by `timeout`, FLTH_APT_TIMEOUT seconds (600 by
#     default), and fails naming what it was fetching;
#   - prints a line before it starts and one, with its duration, when it
#     ends, so a stall shows in the log where it is.
#
#   flth_apt <what> <apt-get args...>
#       flth_apt "QEMU" install -y -qq qemu-system-x86 qemu-utils

FLTH_APT_OPTIONS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

flth_apt() {
    local what="$1" limit="${FLTH_APT_TIMEOUT:-600}" start rc=0
    shift
    echo "apt: $what: apt-get $1, at most $limit s"
    start=$SECONDS
    timeout --kill-after=30 "$limit" \
        sudo DEBIAN_FRONTEND=noninteractive apt-get "${FLTH_APT_OPTIONS[@]}" "$@" >/dev/null ||
        rc=$?
    case "$rc" in
        0)
            echo "apt: $what: done in $((SECONDS - start)) s"
            ;;
        124 | 137)
            echo "ci-setup-linux: apt-get $1 for $what did not finish within $limit s: a package mirror stalled" >&2
            return 1
            ;;
        *)
            echo "ci-setup-linux: apt-get $1 for $what failed (exit $rc)" >&2
            return "$rc"
            ;;
    esac
}
