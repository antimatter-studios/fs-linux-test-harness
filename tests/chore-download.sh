#!/usr/bin/env bash
#
# chore-download.sh — the chore download retries a transient server error.
#
# GitHub's release download answers an occasional HTTP 500, and a `curl` with
# no retry turns that one answer into a red job before anything under test has
# run. Every chore download, in the install-chore action and in any workflow
# that fetches a chore release itself, must retry at least three times and on
# any error. The checksum check that follows the download still guards what
# was fetched, so retrying is safe.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# curl_commands <file> — every `curl` command in the file, one per line, with
# comments dropped and `\` continuations joined, so a flag on the next line
# still counts.
curl_commands() {
    awk '
        { sub(/^[ \t]+/, "") }
        /^#/ { next }
        {
            continued = sub(/\\$/, "")
            joined = joined $0 " "
            if (continued) next
            if (joined ~ /(^|[ \t(|])curl[ \t]/) print joined
            joined = ""
        }
    ' "$1"
}

# retries_a_transient_error <command> — at least three retries, on any error.
retries_a_transient_error() {
    local retries
    retries="$(printf '%s\n' "$1" | sed -n 's/.*--retry \([0-9][0-9]*\).*/\1/p')"
    [ "${retries:-0}" -ge 3 ] && case "$1" in *--retry-all-errors*) true ;; *) false ;; esac
}

downloads=0
action="$REPO/.github/actions/install-chore/action.yml"
for f in "$action" "$REPO"/.github/workflows/*.yml; do
    [ -f "$f" ] || continue
    while IFS= read -r command; do
        if [ "$f" != "$action" ]; then
            case "$command" in *chore/releases/download*) ;; *) continue ;; esac
        fi
        downloads=$((downloads + 1))
        if retries_a_transient_error "$command"; then
            ok "${f#"$REPO"/} retries: ${command%% -o *}"
        else
            bad "${f#"$REPO"/} fails the job on one transient HTTP 5xx; add --retry 5 --retry-all-errors --retry-delay 2: $command"
        fi
    done < <(curl_commands "$f")
done

if [ "$downloads" -gt 0 ]; then
    ok "found $downloads chore downloads to check"
else
    bad "found no chore download to check; the guard is looking in the wrong place"
fi

finish chore-download
