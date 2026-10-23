# shellcheck shell=bash
#
# lib/apt.sh — apt-get for setting up a CI runner, bounded (#77).
#
# Sourced, never executed. On 2026-10-22 a stalled package mirror held
# ci-setup-linux.sh's QEMU group for up to 26 minutes, printing nothing,
# and cancelled fixture jobs with their budget spent. A stall is one
# runner's, not the mirror's: in merge-queue run 40013652597 the debian-12
# smoke job installed QEMU in 42 s while the debian-13 one passed 600 s, and
# a healthy install takes 40 to 55 s. So each call:
#
#   - retries a failed fetch, and gives up on a connection that goes
#     silent, through apt's own Acquire::Retries and Acquire::http(s)::Timeout;
#   - bounds each attempt with `timeout`, FLTH_APT_TIMEOUT seconds (240 by
#     default), and makes FLTH_APT_ATTEMPTS attempts (3): a fresh attempt
#     opens fresh connections, and what the last one fetched stays in apt's
#     cache. An attempt cut off mid-install leaves dpkg interrupted, which
#     apt refuses to run past, so the next one runs `dpkg --configure -a`
#     first;
#   - keeps apt-get's output, and prints its tail when the last attempt
#     fails, so the log says what it was waiting on;
#   - prints a line before each attempt and one, with its duration, when it
#     ends, so a stall shows in the log where it is.
#
#   flth_apt <what> <apt-get args...>
#       flth_apt "QEMU" install -y -qq qemu-system-x86 qemu-utils

FLTH_APT_OPTIONS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

flth_apt() {
    local what="$1" limit="${FLTH_APT_TIMEOUT:-240}" attempts="${FLTH_APT_ATTEMPTS:-3}"
    local attempt=1 start rc log
    shift
    log="$(mktemp)" || return 1
    while :; do
        echo "apt: $what: apt-get $1, attempt $attempt of $attempts, at most $limit s"
        start=$SECONDS
        rc=0
        timeout --kill-after=30 "$limit" \
            sudo DEBIAN_FRONTEND=noninteractive apt-get "${FLTH_APT_OPTIONS[@]}" "$@" > "$log" 2>&1 ||
            rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "apt: $what: done in $((SECONDS - start)) s"
            rm -f "$log"
            return 0
        fi
        case "$rc" in
            124 | 137) echo "apt: $what: apt-get $1 did not finish within $limit s" ;;
            *) echo "apt: $what: apt-get $1 failed (exit $rc)" ;;
        esac
        [ "$attempt" -lt "$attempts" ] || break
        attempt=$((attempt + 1))
        timeout --kill-after=30 "$limit" \
            sudo DEBIAN_FRONTEND=noninteractive dpkg --configure -a >> "$log" 2>&1 || true
    done
    echo "ci-setup-linux: the last lines apt-get printed for $what:" >&2
    tail -n 20 "$log" >&2
    rm -f "$log"
    case "$rc" in
        124 | 137)
            echo "ci-setup-linux: apt-get $1 for $what did not finish within $limit s in $attempts attempts: a package mirror stalled" >&2
            return 1
            ;;
        *)
            echo "ci-setup-linux: apt-get $1 for $what failed (exit $rc) in $attempts attempts" >&2
            return "$rc"
            ;;
    esac
}
