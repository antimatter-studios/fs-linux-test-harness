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
#     ends, so a stall shows in the log where it is;
#   - leaves a stalled Ubuntu mirror behind (#200). A stall that outlasted
#     every fresh attempt on the same mirror failed six CI runs in eight
#     hours, so after a stall the next attempt points the Ubuntu mirror in
#     FLTH_APT_SOURCES at the next of FLTH_APT_MIRRORS, fetches the package
#     index from it, and tries again there. Security updates keep their own
#     host. A stall on every attempt names each mirror it tried, in order.
#
# Environment:
#   FLTH_APT_SOURCES   the sources files to read and rewrite (default: the
#                      runner's /etc/apt/sources.list.d/ubuntu.sources and
#                      /etc/apt/sources.list, whichever exist)
#   FLTH_APT_MIRRORS   the Ubuntu mirrors to move to, in order (default:
#                      http://archive.ubuntu.com/ubuntu/ and
#                      http://mirrors.edge.kernel.org/ubuntu/)
#
#   flth_apt <what> <apt-get args...>
#       flth_apt "QEMU" install -y -qq qemu-system-x86 qemu-utils

FLTH_APT_OPTIONS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

# The sources files that exist, one per line. Every helper here returns 0
# whatever it finds: ci-setup-linux.sh runs under `set -e`, and a search
# that found nothing once ended its setup step there, printing nothing.
flth_apt_sources() {
    local f
    for f in ${FLTH_APT_SOURCES:-/etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list}; do
        if [ -f "$f" ]; then printf '%s\n' "$f"; fi
    done
    return 0
}

# The Ubuntu mirror the sources name now: the first archive URI, from a
# deb822 `URIs:` field or a one-line `deb` entry, that is not the security
# host. GitHub's runner image names a mirror list there, `mirror+file:` a
# file of mirrors, and that URI is the mirror too. Empty when there is none,
# and then nothing switches.
flth_apt_mirror() {
    local files
    files="$(flth_apt_sources)"
    [ -n "$files" ] || return 0
    # shellcheck disable=SC2086  # one path per line, none with spaces
    awk '
        /^[[:space:]]*#/ { next }
        $1 == "URIs:" { for (i = 2; i <= NF; i++) if (keep($i)) { print $i; exit } next }
        $1 == "deb" {
            i = 2
            if ($2 ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
            if (i <= NF && keep($i)) { print $i; exit }
        }
        function keep(u) { return u !~ /:\/\/security\.ubuntu\.com/ }
    ' $files || true
}

# How a log names <mirror>: a mirror list with the first mirror it tries.
flth_apt_mirror_name() {
    local first=""
    case "$1" in
        mirror+file:*)
            first="$(awk 'NF && $1 !~ /^#/ { print $1; exit }' "${1#mirror+file:}" 2>/dev/null || true)"
            ;;
    esac
    printf '%s%s\n' "$1" "${first:+ ($first first)}"
}

# The mirror after <current>: the first of FLTH_APT_MIRRORS that is neither
# it nor one already tried (<tried>, space-separated).
flth_apt_next_mirror() {
    local current="$1" tried="$2" m
    for m in ${FLTH_APT_MIRRORS:-http://archive.ubuntu.com/ubuntu/ http://mirrors.edge.kernel.org/ubuntu/}; do
        [ "$m" = "$current" ] && continue
        case " $tried " in *" $m "*) continue ;; esac
        printf '%s\n' "$m"
        return 0
    done
}

# Point every sources file's <from> at <to>. Written through a copy, so the
# file keeps its owner and mode, and with no `sed -i`, which BSD and GNU
# spell differently.
flth_apt_switch_mirror() {
    local from="$1" to="$2" f tmp
    tmp="$(mktemp)" || return 1
    while IFS= read -r f; do
        awk -v from="$from" -v to="$to" '{
            out = ""; s = $0
            while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) }
            print out s
        }' "$f" > "$tmp" && sudo cp "$tmp" "$f"
    done < <(flth_apt_sources)
    rm -f "$tmp"
}

flth_apt() {
    local what="$1" limit="${FLTH_APT_TIMEOUT:-240}" attempts="${FLTH_APT_ATTEMPTS:-3}"
    local attempt=1 start rc log mirror name="" next tried="" named="" refresh=""
    shift
    log="$(mktemp)" || return 1
    mirror="$(flth_apt_mirror)"
    while :; do
        [ -z "$mirror" ] || name="$(flth_apt_mirror_name "$mirror")"
        echo "apt: $what: apt-get $1, attempt $attempt of $attempts, at most $limit s${mirror:+, from $name}"
        tried="${tried:+$tried }$mirror"
        [ -z "$mirror" ] || named="${named:+$named, then }$name"
        start=$SECONDS
        rc=0
        if [ -n "$refresh" ]; then
            # A new mirror's package index, before an install can use it.
            timeout --kill-after=30 "$limit" \
                sudo DEBIAN_FRONTEND=noninteractive apt-get "${FLTH_APT_OPTIONS[@]}" update -qq > "$log" 2>&1 ||
                rc=$?
            refresh=""
        fi
        [ "$rc" -ne 0 ] ||
            timeout --kill-after=30 "$limit" \
                sudo DEBIAN_FRONTEND=noninteractive apt-get "${FLTH_APT_OPTIONS[@]}" "$@" >> "$log" 2>&1 ||
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
        case "$rc" in
            124 | 137)
                next="$(flth_apt_next_mirror "$mirror" "$tried")"
                if [ -n "$mirror" ] && [ -n "$next" ]; then
                    echo "apt: $what: the mirror $name stalled; the next attempt uses $next"
                    flth_apt_switch_mirror "$mirror" "$next"
                    mirror="$next"
                    [ "$1" = update ] || refresh=1
                fi
                ;;
        esac
    done
    echo "ci-setup-linux: the last lines apt-get printed for $what:" >&2
    tail -n 20 "$log" >&2
    rm -f "$log"
    case "$rc" in
        124 | 137)
            echo "ci-setup-linux: apt-get $1 for $what did not finish within $limit s in $attempts attempts: a package mirror stalled${named:+: $named}" >&2
            return 1
            ;;
        *)
            echo "ci-setup-linux: apt-get $1 for $what failed (exit $rc) in $attempts attempts" >&2
            return "$rc"
            ;;
    esac
}
