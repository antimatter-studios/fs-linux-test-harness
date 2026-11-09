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
# This runs the action's own script against a stub `curl` that serves a fake
# release from the sandbox and injects the outage. Whichever way the assets
# arrive, the checksum check must still refuse a tarball that does not match,
# and an outage with no way around it must still fail the job.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_sandbox
action="$REPO/.github/actions/install-chore/action.yml"
version=0.11.0
token=test-token
tarball="chore-$version-linux-x86_64.tar.gz"

# The action's `run:` block, unindented: the last key of its only step.
script="$SANDBOX/install-chore.sh"
awk '
    found && indent == "" && /[^ ]/ { match($0, /^ */); indent = RLENGTH }
    found { print (length($0) > indent ? substr($0, indent + 1) : "") }
    /^ *run: \|$/ { found = 1; indent = "" }
' "$action" > "$script"
if [ -s "$script" ] && grep -q 'curl ' "$script"; then
    ok "the action's run script is extracted"
else
    bad "found no run script in $action"
fi
check_lacks "$(cat "$script")" '${{' "the run script takes everything through env, so the extract is what runs"
# action_says <text> <what> — the action file holds the line, without
# reciting the whole file when it does not.
action_says() {
    if grep -qF -- "$1" "$action"; then ok "$2"; else bad "$2 (no '$1' in ${action#"$REPO"/})"; fi
}
action_says 'default: ${{ github.token }}' "the token input defaults to the job's own token"
action_says 'CHORE_TOKEN: ${{ inputs.token }}' "the run script reads the token from CHORE_TOKEN"

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
(cd "$release/download" && sha256sum "chore-$version-darwin-arm64.tar.gz" "$tarball") > "$release/download/checksums.txt"
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
out="" url="" accept="" auth="" retries=0
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
        --retry-delay | -w | --write-out) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s|accept=%s|auth=%s|retries=%s\n' "$url" "$accept" "$auth" "$retries" >> "$FLTH_TEST_CURL_LOG"
fail() {
    local i
    for i in $(seq 0 "$retries"); do echo "curl: (22) The requested URL returned error: $1" >&2; done
    exit 22
}
serve() { if [ -n "$out" ]; then cp "$1" "$out"; else cat "$1"; fi; }
api=https://api.github.com/repos/antimatter-studios/chore/releases
case "$url" in
    https://github.com/antimatter-studios/chore/releases/download/v0.11.0/*)
        case " $FLTH_TEST_OUTAGE " in *" download "*) fail 504 ;; esac
        name="${url##*/}"
        [ -f "$FLTH_TEST_RELEASE/download/$name" ] || fail 404
        serve "$FLTH_TEST_RELEASE/download/$name" ;;
    "$api/tags/v0.11.0")
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
chmod +x "$bin/curl" "$bin/uname"
export FLTH_TEST_RELEASE="$release"

# install <case> [outage...] — run the action's script in a fresh runner;
# sets status, out (stdout and stderr) and calls (the stub's log).
install() {
    local name="$1"
    shift
    runner="$SANDBOX/runner-$name"
    mkdir -p "$runner/temp" "$runner/home"
    : > "$runner/github_path"
    export FLTH_TEST_CURL_LOG="$runner/curl.log"
    : > "$FLTH_TEST_CURL_LOG"
    out="$(cd "$runner" && env PATH="$bin:$PATH" HOME="$runner/home" RUNNER_TEMP="$runner/temp" \
        GITHUB_PATH="$runner/github_path" CHORE_VERSION="$version" CHORE_TOKEN="$token" \
        FLTH_TEST_OUTAGE="$*" bash --noprofile --norc -e -o pipefail "$script" 2>&1)"
    status=$?
    calls="$(cat "$FLTH_TEST_CURL_LOG")"
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
    if [ -n "$calls" ] && ! printf '%s\n' "$calls" | grep -qv '|retries=5$'; then
        ok "$1: every curl call keeps --retry 5"
    else
        bad "$1: a curl call ran with another retry budget: $calls"
    fi
}

# The token goes to api.github.com and nowhere else.
token_only_to_the_api() {
    if printf '%s\n' "$calls" | grep 'auth=Bearer' | grep -qv '^https://api\.github\.com/'; then
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
every_call_keeps_the_retry_budget healthy
token_only_to_the_api healthy

install outage download
check_eq "$status" 0 "outage: the install succeeds when every release download attempt answers 504"
installed_is_the_release outage
check_contains "$out" "returned error: 504" "outage: the 504s are still shown"
check_contains "$out" "$tarball: OK" "outage: the tarball fetched through the API passes the checksum check"
check_contains "$calls" "$api/releases/assets/203|accept=application/octet-stream|auth=Bearer $token" \
    "outage: the tarball comes from its own asset id, as raw bytes, with the job's token"
check_contains "$calls" "$api/releases/assets/201|accept=application/octet-stream|auth=Bearer $token" \
    "outage: checksums.txt comes from its own asset id too"
check_lacks "$calls" "$api/releases/assets/202" "outage: the other platform's tarball is not fetched"
check_eq "$(printf '%s\n' "$calls" | grep -c '/releases/download/')" 2 \
    "outage: each asset tries the release download once, with its retries, before the API"
every_call_keeps_the_retry_budget outage
token_only_to_the_api outage

# The API serves the decoy's bytes for the tarball's id: the checksum refuses it.
cp "$release/assets/202" "$release/assets/203"
install tampered download
check_eq "$((status != 0))" 1 "tampered: a tarball fetched through the API that fails its checksum fails the job"
check_contains "$out" "FAILED" "tampered: the checksum check reports the mismatch"
nothing_installed tampered
cp "$release/download/$tarball" "$release/assets/203"

install unrecoverable download api
check_eq "$((status != 0))" 1 "unrecoverable: a 504 from the API as well fails the job"
nothing_installed unrecoverable
every_call_keeps_the_retry_budget unrecoverable

mv "$release/release.json" "$release/release.json.kept"
sed "s/\"name\": \"$tarball\"/\"name\": \"elsewhere.tar.gz\"/" "$release/release.json.kept" > "$release/release.json"
install missing download
check_eq "$((status != 0))" 1 "missing: a release whose assets lack the tarball fails the job"
check_contains "$out" "$tarball" "missing: the failure names the asset it could not find"
nothing_installed missing
mv "$release/release.json.kept" "$release/release.json"

finish install-chore
