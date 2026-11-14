#!/usr/bin/env bash
# Select the Linux unit runner; routing failures must not prevent CI.
set -euo pipefail
preferred=antimatter-vps-linux-x64
hosted=ubuntu-24.04
fallback() {
    printf 'runner gate: %s; using %s\n' "$*" "$hosted" >&2
    printf '%s\n' "$hosted"
    exit 0
}

# The pool's job-started hook allows only this user. Check every identity
# here too, so bot pushes and contributors go straight to hosted runners.
[ "${GITHUB_ACTOR:-}" = christhomas ] || fallback 'actor is not allowed'
[ "${GITHUB_TRIGGERING_ACTOR:-}" = christhomas ] || fallback 'triggering actor is not allowed'
org="${GITHUB_REPOSITORY_OWNER:-}"
case "$org" in antimatter-studios) ;; *) fallback 'unknown organization' ;; esac
command -v jq >/dev/null 2>&1 || fallback 'jq is unavailable'
command -v curl >/dev/null 2>&1 || fallback 'curl is unavailable'
event="${GITHUB_EVENT_PATH:-}"
[ -r "$event" ] || fallback 'event payload is unavailable'
jq -e 'type == "object"' "$event" >/dev/null || fallback 'invalid event payload'
sender="$(jq -r '.sender.login // ""' "$event")" || fallback 'invalid event payload'
author="$(jq -r '.pull_request.user.login // ""' "$event")" || fallback 'invalid event payload'
for identity in "$sender" "$author"; do
    case "$identity" in ''|christhomas) ;; *) fallback 'sender or PR author is not allowed' ;; esac
done

# Identify this job for admission; the gate can expire unclaimed picks.
# Ask as the last step of the direct predecessor, immediately before the job.
runner="$(curl --fail --silent --show-error --get \
    --connect-timeout 3 --max-time 10 --max-filesize 256 \
    --data-urlencode "org=$org" \
    --data-urlencode "prefer=$preferred" \
    --data-urlencode "fallback=$hosted" \
    --data-urlencode "actor=$GITHUB_TRIGGERING_ACTOR" \
    --data-urlencode "author=$author" \
    --data-urlencode "run=${GITHUB_RUN_ID:-}" \
    --data-urlencode "attempt=${GITHUB_RUN_ATTEMPT:-}" \
    --data-urlencode 'job=unit' \
    https://runner-gate.antimatter-studios.com/pick)" || fallback 'request failed'
case "$runner" in
    "$preferred"|"$hosted") ;;
    *) fallback 'unexpected response' ;;
esac
printf 'runner gate: Linux units use %s\n' "$runner" >&2
printf '%s\n' "$runner"
