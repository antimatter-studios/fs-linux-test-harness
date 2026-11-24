#!/usr/bin/env bash
#
# install-chore.sh — the install-chore action survives an outage of the
# release download and still installs only a checksum-verified chore.
#
# On 2026-11-09 every attempt at the chore release download answered HTTP 504,
# for the first try and all five retries, in two CI jobs, and the jobs failed
# before anything under test ran (#212). The release's assets are also served
# through the GitHub REST API, so once the retries are spent the action fetches
# the same assets that way, authenticated with the job's token.
#
# Both paths end at the same storage host, so an outage of that host fails
# both. The SHA-256 of each platform's tarball is therefore pinned in the
# action, and a verified tarball is kept in actions/cache: a cached copy that
# matches its pinned hash installs with no network at all (#212).
#
# This runs the action's own scripts, in order, against a stub `curl` that
# serves a fake release from the sandbox and injects the outage, with the
# cache restore stood in for by a copy into the cache directory. Whichever way
# the tarball arrives, the pinned hash must still refuse one that does not
# match, and an outage with no way around it must still fail the job.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_sandbox
action="$REPO/.github/actions/install-chore/action.yml"
version=0.11.0
token=test-token
tarball="chore-$version-linux-x86_64.tar.gz"

# The action's `run:` blocks, unindented, one file per block in the order the
# runner runs them: steps/1, steps/2, ... A block ends at the first line
# indented less than its own body.
steps="$SANDBOX/steps"
mkdir -p "$steps"
awk -v dir="$steps" '
    found && indent == "" && /[^ ]/ { match($0, /^ */); indent = RLENGTH }
    found && indent != "" && /[^ ]/ { match($0, /^ */); if (RLENGTH < indent) found = 0 }
    found { print (length($0) > indent ? substr($0, indent + 1) : "") > (dir "/" n) }
    /^ *run: \|$/ { found = 1; indent = ""; n++ }
' "$action"
nsteps="$(find "$steps" -type f | wc -l | tr -d ' ')"
# The last block installs; every block before it runs first, as the runner
# runs them, and the cache restore comes between them and the last.
script="$steps/$nsteps"
if [ "$nsteps" -ge 1 ] && grep -q 'curl ' "$script"; then
    ok "the action's install script is its last run block"
else
    bad "found no install script in $action"
fi
check_lacks "$(cat "$steps"/*)" '${{' "the run scripts take everything through env, so the extract is what runs"
# action_says <text> <what> — the action file holds the line, without
# reciting the whole file when it does not.
action_says() {
    if grep -qF -- "$1" "$action"; then ok "$2"; else bad "$2 (no '$1' in ${action#"$REPO"/})"; fi
}
action_says 'default: ${{ github.token }}' "the token input defaults to the job's own token"
action_says 'CHORE_TOKEN: ${{ inputs.token }}' "the run script reads the token from CHORE_TOKEN"
# The install step reads what the pin step wrote, under these names, and the
# cache steps use the pin step's path and key: the stand-ins below rely on it.
action_says 'CHORE_TARBALL: ${{ steps.pin.outputs.tarball }}' "the install step reads the pinned tarball's name"
action_says 'CHORE_SHA256: ${{ steps.pin.outputs.sha256 }}' "the install step reads the pinned SHA-256"
action_says 'CHORE_CACHE_DIR: ${{ steps.pin.outputs.dir }}' "the install step reads the cache directory"
action_says 'uses: actions/cache/restore@v4' "the action restores a cached tarball"
action_says 'uses: actions/cache/save@v4' "the action saves a verified tarball"
action_says "if: steps.restore.outputs.cache-hit != 'true'" "the action saves only when nothing was restored"
if [ "$(grep -c 'key: ${{ steps.pin.outputs.key }}' "$action")" = 2 ] &&
    [ "$(grep -c 'path: ${{ steps.pin.outputs.dir }}' "$action")" = 2 ]; then
    ok "the cache restore and save use the pin step's path and key"
else
    bad "the cache restore and save do not both use the pin step's path and key"
fi
if awk '/uses: actions\/cache\/save@/ { save = NR } /id: install$/ { install = NR } END { exit !(save > install && install > 0) }' "$action"; then
    ok "the cache is saved only after the install step verified the tarball"
else
    bad "the cache save does not come after the install step"
fi

# Every platform of the chore version CI pins has its SHA-256 in the action,
# so a version bump without the hashes fails here, before CI downloads anything.
ci_version="$(sed -n 's/^ *CHORE_VERSION: "\(.*\)"$/\1/p' "$REPO/.github/workflows/ci.yml")"
for platform in darwin-arm64 darwin-x86_64 linux-arm64 linux-x86_64; do
    if grep -qE "^ *[0-9a-f]{64}  chore-${ci_version:-none}-$platform\.tar\.gz$" "$action"; then
        ok "CI's chore ${ci_version:-none} has a pinned SHA-256 for $platform"
    else
        bad "CI's chore ${ci_version:-none} has no pinned SHA-256 for $platform in ${action#"$REPO"/}"
    fi
done

# A fake release: one chore binary, a decoy for another platform, the
# checksums of both, and the bytes the API serves for each asset id.
release="$SANDBOX/release"
mkdir -p "$release/pkg/chore-$version" "$release/download" "$release/assets" "$SANDBOX/decoy"
cat > "$release/pkg/chore-$version/chore" <<'EOF'
#!/bin/sh
echo "chore 0.11.0 (the fake release)"
EOF
chmod 0755 "$release/pkg/chore-$version/chore"
tar -czf "$release/download/$tarball" -C "$release/pkg" "chore-$version"
printf 'not this one\n' > "$SANDBOX/decoy/chore"
tar -czf "$release/download/chore-$version-darwin-arm64.tar.gz" -C "$SANDBOX/decoy" chore
# A release nobody pinned: served and listed in checksums.txt like any other.
tar -czf "$release/download/chore-0.12.0-linux-x86_64.tar.gz" -C "$release/pkg" "chore-$version"
(cd "$release/download" && sha256sum "chore-$version-darwin-arm64.tar.gz" "$tarball" chore-0.12.0-linux-x86_64.tar.gz) > "$release/download/checksums.txt"
# The pinned hash the scripts see for the fake tarball, put in place of the
# real release's below; FLTH_TEST_PIN changes it for a case.
fake_sha256="$(sha256sum "$release/download/$tarball" | cut -d' ' -f1)"
cp "$release/download/checksums.txt" "$release/assets/201"
cp "$release/download/chore-$version-darwin-arm64.tar.gz" "$release/assets/202"
cp "$release/download/$tarball" "$release/assets/203"
api=https://api.github.com/repos/antimatter-studios/chore
# The shape of GET /releases/tags/<tag>: assets each with their API url, an
# uploader whose own url comes after the asset's name, and a body with commas.
cat > "$release/release.json" <<EOF
{
  "url": "$api/releases/100",
  "assets_url": "$api/releases/100/assets",
  "id": 100,
  "tag_name": "v$version",
  "name": "v$version",
  "assets": [
    {
      "url": "$api/releases/assets/201",
      "id": 201,
      "name": "checksums.txt",
      "uploader": {
        "login": "github-actions[bot]",
        "url": "https://api.github.com/users/github-actions%5Bbot%5D"
      },
      "browser_download_url": "https://github.com/antimatter-studios/chore/releases/download/v$version/checksums.txt"
    },
    {
      "url": "$api/releases/assets/202",
      "id": 202,
      "name": "chore-$version-darwin-arm64.tar.gz",
      "uploader": {
        "url": "https://api.github.com/users/github-actions%5Bbot%5D"
      }
    },
    {
      "url": "$api/releases/assets/203",
      "id": 203,
      "name": "$tarball",
      "uploader": {
        "url": "https://api.github.com/users/github-actions%5Bbot%5D"
      }
    }
  ],
  "body": "Fixed, in order: one, two, \"name\": \"$tarball\", three."
}
EOF

# The stub curl: answers the release download, the release lookup and the
# asset endpoint from the fake release; FLTH_TEST_OUTAGE names the paths that
# answer HTTP 504 on every attempt, as the release download did on 2026-11-09.
bin="$SANDBOX/bin"
mkdir -p "$bin"
cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url="" accept="" auth="" retries=0 write_out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -H)
            case "$2" in
                Accept:*) accept="${2#Accept: }" ;;
                Authorization:*) auth="${2#Authorization: }" ;;
            esac
            shift 2 ;;
        --retry) retries="$2"; shift 2 ;;
        --retry-delay) shift 2 ;;
        -w | --write-out) write_out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s|accept=%s|auth=%s|retries=%s\n' "$url" "$accept" "$auth" "$retries" >> "$FLTH_TEST_CURL_LOG"
fail() {
    local i
    for i in $(seq 0 "$retries"); do echo "curl: (22) The requested URL returned error: $1" >&2; done
    if [ -n "$write_out" ]; then
        host=api.github.com
        case "$url" in https://github.com/antimatter-studios/chore/releases/download/*) host=release-assets.githubusercontent.com ;; esac
        printf '%s from %s\n' "$1" "$host" >&2
    fi
    exit 22
}
# FLTH_TEST_FAILING_CALLS=N: the first N calls answer 504 whatever they ask
# for, as the storage host behind both paths would during an outage of its own.
if [ -n "${FLTH_TEST_FAILING_CALLS:-}" ] && [ "$(wc -l < "$FLTH_TEST_CURL_LOG")" -le "$FLTH_TEST_FAILING_CALLS" ]; then
    fail 504
fi
serve() { if [ -n "$out" ]; then cp "$1" "$out"; else cat "$1"; fi; }
api=https://api.github.com/repos/antimatter-studios/chore/releases
case "$url" in
    https://github.com/antimatter-studios/chore/releases/download/v*/*)
        case " $FLTH_TEST_OUTAGE " in *" download "*) fail 504 ;; esac
        name="${url##*/}"
        [ -f "$FLTH_TEST_RELEASE/download/$name" ] || fail 404
        serve "$FLTH_TEST_RELEASE/download/$name" ;;
    "$api/tags/v0.11.0" | "$api/tags/v0.12.0")
        case " $FLTH_TEST_OUTAGE " in *" api "*) fail 504 ;; esac
        [ "$auth" = "Bearer test-token" ] || fail 401
        serve "$FLTH_TEST_RELEASE/release.json" ;;
    "$api/assets/"*)
        case " $FLTH_TEST_OUTAGE " in *" api "*) fail 504 ;; esac
        [ "$auth" = "Bearer test-token" ] || fail 401
        # Without this Accept the endpoint answers with the asset's JSON.
        [ "$accept" = application/octet-stream ] || { echo '{"id": 0}' > "$out"; exit 0; }
        id="${url##*/}"
        [ -f "$FLTH_TEST_RELEASE/assets/$id" ] || fail 404
        serve "$FLTH_TEST_RELEASE/assets/$id" ;;
    *) echo "curl: (6) Could not resolve host: $url" >&2; exit 6 ;;
esac
STUB
cat > "$bin/uname" <<'STUB'
#!/bin/sh
case "$1" in -m) echo x86_64 ;; -s) echo Linux ;; *) exec /usr/bin/uname "$@" ;; esac
STUB
# The stub sleep logs how long the action waited and returns at once.
cat > "$bin/sleep" <<'STUB'
#!/bin/sh
echo "$1" >> "$FLTH_TEST_SLEEP_LOG"
STUB
chmod +x "$bin/curl" "$bin/uname" "$bin/sleep"
export FLTH_TEST_RELEASE="$release"

# The real release's pinned hash for the tarball the stub uname picks, which
# the cases replace with the fake tarball's (or FLTH_TEST_PIN's).
real_sha256="$(sed -n "s/^\([0-9a-f]\{64\}\)  $tarball\$/\1/p" "$steps"/* | head -1)"

# output <name> — what the earlier steps wrote to GITHUB_OUTPUT as <name>.
output() { sed -n "s/^$1=//p" "$runner/github_output" | tail -1; }

# install <case> [outage...] — run the action's scripts in order in a fresh
# runner; sets status, out (stdout and stderr) and calls (the stub's log).
# FLTH_TEST_CACHED=<file> stands in for a cache hit: the file is put where
# the restore would put the pinned tarball, before the install step runs.
# FLTH_TEST_VERSION runs the action for another chore version.
install() {
    local name="$1" step pinned="${FLTH_TEST_PIN:-$fake_sha256}" cache
    shift
    runner="$SANDBOX/runner-$name"
    mkdir -p "$runner/temp" "$runner/home" "$runner/steps"
    : > "$runner/github_path"
    : > "$runner/github_output"
    export FLTH_TEST_CURL_LOG="$runner/curl.log"
    : > "$FLTH_TEST_CURL_LOG"
    export FLTH_TEST_SLEEP_LOG="$runner/sleep.log"
    : > "$FLTH_TEST_SLEEP_LOG"
    out="" status=0
    for step in $(seq 1 "$nsteps"); do
        if [ -n "$real_sha256" ]; then
            sed "s/^$real_sha256  /$pinned  /" "$steps/$step" > "$runner/steps/$step"
        else
            cp "$steps/$step" "$runner/steps/$step"
        fi
        if [ "$step" = "$nsteps" ] && [ -n "${FLTH_TEST_CACHED:-}" ]; then
            cache="$(output dir)"
            mkdir -p "${cache:=$runner/temp/chore-cache}"
            cp "$FLTH_TEST_CACHED" "$cache/$(output tarball | grep . || echo "$tarball")"
        fi
        out="$out$(cd "$runner" && env PATH="$bin:$PATH" HOME="$runner/home" RUNNER_TEMP="$runner/temp" \
            GITHUB_PATH="$runner/github_path" GITHUB_OUTPUT="$runner/github_output" \
            CHORE_VERSION="${FLTH_TEST_VERSION:-$version}" CHORE_TOKEN="$token" \
            CHORE_TARBALL="$(output tarball)" CHORE_SHA256="$(output sha256)" CHORE_CACHE_DIR="$(output dir)" \
            FLTH_TEST_OUTAGE="$*" bash --noprofile --norc -e -o pipefail "$runner/steps/$step" 2>&1)"
        status=$?
        [ "$status" = 0 ] || break
    done
    calls="$(cat "$FLTH_TEST_CURL_LOG")"
    slept="$(awk '{ s += $1 } END { print s + 0 }' "$FLTH_TEST_SLEEP_LOG")"
}

# cached_copy <case> — after a download, the verified tarball waits in the
# cache directory for the save step.
cached_copy() {
    local cache
    cache="$(output dir)"
    if [ -n "$cache" ] && cmp -s "$cache/$tarball" "$release/download/$tarball"; then
        ok "$1: the verified tarball is left in the cache directory for the save"
    else
        bad "$1: no verified tarball in the cache directory '${cache}'"
    fi
}

# installed_is_the_release <case> — the installed chore is the release's own.
installed_is_the_release() {
    if cmp -s "$runner/home/.local/bin/chore" "$release/pkg/chore-$version/chore"; then
        ok "$1: the installed chore is byte-for-byte the release's binary"
    else
        bad "$1: the installed chore is not the release's binary"
    fi
}

nothing_installed() {
    if [ -e "$runner/home/.local/bin/chore" ]; then
        bad "$1: a chore was installed anyway"
    else
        ok "$1: no chore is installed"
    fi
}

every_call_keeps_the_retry_budget() {
    if [ -n "$calls" ] && ! printf '%s\n' "$calls" | grep -v '|retries=5$' >/dev/null; then
        ok "$1: every curl call keeps --retry 5"
    else
        bad "$1: a curl call ran with another retry budget: $calls"
    fi
}

# The token goes to api.github.com and nowhere else.
token_only_to_the_api() {
    if printf '%s\n' "$calls" | grep 'auth=Bearer' | grep -v '^https://api\.github\.com/' >/dev/null; then
        bad "$1: the token was sent outside api.github.com: $calls"
    else
        ok "$1: the token is sent to api.github.com only"
    fi
}

install healthy
check_eq "$status" 0 "healthy: the install succeeds"
installed_is_the_release healthy
check_contains "$out" "chore 0.11.0 (the fake release)" "healthy: the installed chore runs"
check_eq "$(cat "$runner/github_path")" "$runner/home/.local/bin" "healthy: the install directory goes on GITHUB_PATH"
check_lacks "$calls" "api.github.com" "healthy: the API is not asked when the download answers"
check_lacks "$calls" "checksums.txt" "healthy: the release's checksums.txt is not trusted, or fetched"
check_contains "$out" "$tarball: OK" "healthy: the tarball passes its pinned SHA-256"
check_eq "$(output key)" "chore-$tarball-$fake_sha256" "healthy: the cache key names the version, the platform and the hash"
cached_copy healthy
every_call_keeps_the_retry_budget healthy
token_only_to_the_api healthy

# A cached copy installs with no network at all.
FLTH_TEST_CACHED="$release/download/$tarball" install cached
check_eq "$status" 0 "cached: the install succeeds from the cache"
installed_is_the_release cached
check_contains "$out" "$tarball: OK" "cached: the cached tarball passes its pinned SHA-256"
check_eq "$calls" "" "cached: nothing is downloaded"

# The same while the storage host behind both paths answers 504 to everything.
FLTH_TEST_CACHED="$release/download/$tarball" install cached-outage download api
check_eq "$status" 0 "cached-outage: the install succeeds from the cache during an outage of both paths"
installed_is_the_release cached-outage
check_eq "$calls" "" "cached-outage: nothing is downloaded"
check_eq "$slept" 0 "cached-outage: nothing waits for the outage"

# A cached copy that is not the pinned tarball fails the job: it neither
# installs nor falls through to a download.
FLTH_TEST_CACHED="$release/download/chore-$version-darwin-arm64.tar.gz" install cached-tampered
check_eq "$((status != 0))" 1 "cached-tampered: a cached tarball that fails its pinned SHA-256 fails the job"
check_contains "$out" "does not match its pinned SHA-256" "cached-tampered: the failure says the cached copy does not match"
check_eq "$calls" "" "cached-tampered: it does not fall through to a download"
nothing_installed cached-tampered

# The release serves a tarball that matches its own checksums.txt, but not the
# hash pinned here: the pin wins and the job fails.
FLTH_TEST_PIN="$(printf '%064d' 0)" install pin-mismatch
check_eq "$((status != 0))" 1 "pin-mismatch: a download that does not match the pinned SHA-256 fails the job"
check_contains "$out" "does not match its pinned SHA-256" "pin-mismatch: the failure names the pinned hash"
check_eq "$(printf '%s\n' "$calls" | grep -c '/releases/download/')" 1 "pin-mismatch: a mismatch never falls through to another download"
nothing_installed pin-mismatch
if [ -e "$(output dir)/$tarball" ]; then
    bad "pin-mismatch: the unverified tarball was left for the cache"
else
    ok "pin-mismatch: nothing is left for the cache"
fi

# A chore version with no pinned hash fails before anything downloads, and
# says what a version bump must add.
FLTH_TEST_VERSION=0.12.0 install unpinned
check_eq "$((status != 0))" 1 "unpinned: a chore version with no pinned SHA-256 fails the job"
check_contains "$out" "no pinned SHA-256 for chore-0.12.0-linux-x86_64.tar.gz" "unpinned: the failure names the tarball with no hash"
check_eq "$calls" "" "unpinned: nothing is downloaded"
nothing_installed unpinned

install outage download
check_eq "$status" 0 "outage: the install succeeds when every release download attempt answers 504"
installed_is_the_release outage
check_contains "$out" "returned error: 504" "outage: the 504s are still shown"
check_contains "$out" "504 from release-assets.githubusercontent.com" \
    "outage: the diagnostic names the host that returned the 504"
check_contains "$out" "$tarball: OK" "outage: the tarball fetched through the API passes its pinned SHA-256"
check_contains "$calls" "$api/releases/assets/203|accept=application/octet-stream|auth=Bearer $token" \
    "outage: the tarball comes from its own asset id, as raw bytes, with the job's token"
check_lacks "$calls" "$api/releases/assets/201" "outage: checksums.txt is not fetched through the API either"
check_lacks "$calls" "$api/releases/assets/202" "outage: the other platform's tarball is not fetched"
check_eq "$(printf '%s\n' "$calls" | grep -c '/releases/download/')" 1 \
    "outage: the tarball tries the release download once, with its retries, before the API"
every_call_keeps_the_retry_budget outage
token_only_to_the_api outage

# The API serves the decoy's bytes for the tarball's id: the checksum refuses it.
cp "$release/assets/202" "$release/assets/203"
install tampered download
check_eq "$((status != 0))" 1 "tampered: a tarball fetched through the API that fails its pinned SHA-256 fails the job"
check_contains "$out" "FAILED" "tampered: the hash check reports the mismatch"
nothing_installed tampered
cp "$release/download/$tarball" "$release/assets/203"

install unrecoverable download api
check_eq "$((status != 0))" 1 "unrecoverable: a 504 from the API as well fails the job"
nothing_installed unrecoverable
every_call_keeps_the_retry_budget unrecoverable
# The outage of 2026-11-09 lasted minutes, and both paths end at the same
# storage host, so the action waits out at least five minutes before it gives up.
if [ "$slept" -ge 300 ]; then
    ok "unrecoverable: the action waited ${slept}s across both paths before it failed"
else
    bad "unrecoverable: the action gave up after waiting only ${slept}s; an outage of minutes needs at least 300s"
fi

# Both paths answer 504 for a while, as an outage of the storage host they both
# redirect to would, then recover: the action waits and tries both again.
export FLTH_TEST_FAILING_CALLS=4
install storage
unset FLTH_TEST_FAILING_CALLS
check_eq "$status" 0 "storage: the install succeeds once an outage of both paths ends"
installed_is_the_release storage
check_contains "$out" "$tarball: OK" "storage: the tarball still passes its pinned SHA-256"
check_eq "$((slept > 0))" 1 "storage: the action waited before trying both paths again"
every_call_keeps_the_retry_budget storage
token_only_to_the_api storage

mv "$release/release.json" "$release/release.json.kept"
sed "s/\"name\": \"$tarball\"/\"name\": \"elsewhere.tar.gz\"/" "$release/release.json.kept" > "$release/release.json"
install missing download
check_eq "$((status != 0))" 1 "missing: a release whose assets lack the tarball fails the job"
check_contains "$out" "$tarball" "missing: the failure names the asset it could not find"
nothing_installed missing
mv "$release/release.json.kept" "$release/release.json"

finish install-chore
