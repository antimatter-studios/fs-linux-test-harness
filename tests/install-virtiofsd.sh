#!/usr/bin/env bash
#
# install-virtiofsd.sh — the install-virtiofsd action installs only upstream's
# virtiofsd whose hashes are pinned here, and names it for the engine.
#
# Linux CI needs virtiofsd 1.14.0 or newer: every release before it panics in
# setxattr on an extended attribute name that is not UTF-8, and the guest's call
# hangs (#274). Ubuntu packages 1.10.0. Upstream publishes a static x86_64 build
# with each release, as a zip; the action pins the SHA-256 of the zip and of the
# binary in it, keeps a verified zip in actions/cache, and exports the binary as
# FLTH_VIRTIOFSD, which the engine takes first.
#
# This runs the action's own scripts, in order, against a stub `curl` that
# serves a fake zip from the sandbox and a stub `unzip` that unpacks a fake
# binary, with the cache restore stood in for by a copy into the cache
# directory. Whichever way the zip arrives, a hash that does not match, or a
# binary that is not the version asked for, must fail the job. The real
# download and unpack are proven by CI's smoke job, which runs the action.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

new_sandbox
action="$REPO/.github/actions/install-virtiofsd/action.yml"

# The action's `run:` blocks, unindented, one file per block in the order the
# runner runs them: steps/1, steps/2. A block ends at the first line indented
# less than its own body.
steps="$SANDBOX/steps"
mkdir -p "$steps"
awk -v dir="$steps" '
    found && indent == "" && /[^ ]/ { match($0, /^ */); indent = RLENGTH }
    found && indent != "" && /[^ ]/ { match($0, /^ */); if (RLENGTH < indent) found = 0 }
    found { print (length($0) > indent ? substr($0, indent + 1) : "") > (dir "/" n) }
    /^ *run: \|$/ { found = 1; indent = ""; n++ }
' "$action"
check_eq "$(find "$steps" -type f | wc -l | tr -d ' ')" 2 "the action has two run blocks: the pin and the install"
check_lacks "$(cat "$steps"/*)" '${{' "the run scripts take everything through env, so the extract is what runs"
action_says() {
    if grep -qF -- "$1" "$action"; then ok "$2"; else bad "$2 (no '$1' in ${action#"$REPO"/})"; fi
}
action_says 'VIRTIOFSD_ZIP_SHA256: ${{ steps.pin.outputs.zip_sha256 }}' "the install step reads the pinned zip's SHA-256"
action_says 'VIRTIOFSD_BIN_SHA256: ${{ steps.pin.outputs.bin_sha256 }}' "the install step reads the pinned binary's SHA-256"
action_says 'VIRTIOFSD_CACHE_DIR: ${{ steps.pin.outputs.dir }}' "the install step reads the cache directory"
action_says "if: steps.restore.outputs.cache-hit != 'true'" "the action saves only when nothing was restored"
if awk '/uses: actions\/cache\/save@/ { save = NR } /id: install$/ { install = NR } END { exit !(save > install && install > 0) }' "$action"; then
    ok "the cache is saved only after the install step verified the zip"
else
    bad "the cache save does not come after the install step"
fi

# The default version is the oldest the harness accepts on Linux, and it is pinned.
default="$(sed -n '/^  version:/,/^  [a-z]/s/^    default: "\(.*\)"$/\1/p' "$action")"
linux_min="$(sed -n 's/^VIRTIOFSD_LINUX_MIN=//p' "$REPO/scripts/host-tools.sh")"
check_eq "$default" "${linux_min:-none}" "the action's default version is the oldest host-tools.sh accepts on Linux"
if grep -qE "^ *${default:-none} [0-9a-f]{64} [0-9a-f]{64} [0-9a-f]{32}$" "$action"; then
    ok "the default version $default has a pinned line"
else
    bad "the default version ${default:-none} has no pinned line in ${action#"$REPO"/}"
fi
check_contains "$(cat "$REPO/.github/workflows/ci.yml")" "uses: ./.github/actions/install-virtiofsd" "CI's smoke job installs virtiofsd through the action"

# A fake release: the zip is any bytes, since unzip is stubbed; the stub unzip
# writes the fake binary, which answers --version from FLTH_TEST_SAYS.
release="$SANDBOX/release"
mkdir -p "$release"
printf 'a fake virtiofsd zip\n' > "$release/virtiofsd-v1.14.0.zip"
cat > "$release/virtiofsd" <<'EOF'
#!/bin/sh
[ "$1" = --version ] && echo "${FLTH_TEST_SAYS:-virtiofsd 1.14.0}"
exit 0
EOF
chmod 0755 "$release/virtiofsd"
sha() { sha256sum "$1" | cut -d' ' -f1; }
fake_zip_sha="$(sha "$release/virtiofsd-v1.14.0.zip")"
fake_bin_sha="$(sha "$release/virtiofsd")"

bin="$SANDBOX/bin"
mkdir -p "$bin"
# curl: the zip for its upload URL; FLTH_TEST_OUTAGE=1 fails every attempt.
cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --retry | --retry-delay | --write-out) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "$url" >> "$FLTH_TEST_CURL_LOG"
[ -z "${FLTH_TEST_OUTAGE:-}" ] || { echo "curl: (22) The requested URL returned error: 503" >&2; exit 22; }
case "$url" in
    https://gitlab.com/-/project/21523468/uploads/*/virtiofsd-v1.14.0.zip) cp "$FLTH_TEST_RELEASE/virtiofsd-v1.14.0.zip" "$out" ;;
    *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
STUB
# unzip -o -q <zip> <member> -d <dir>: the fake binary at <dir>/<member>.
cat > "$bin/unzip" <<'STUB'
#!/bin/sh
zip="$3" member="$4" dir="$6"
[ -f "$zip" ] || { echo "unzip: cannot find $zip" >&2; exit 9; }
mkdir -p "$dir/$(dirname "$member")"
cp "$FLTH_TEST_RELEASE/virtiofsd" "$dir/$member"
STUB
cat > "$bin/uname" <<'STUB'
#!/bin/sh
case "$1" in -m) echo "${FLTH_TEST_ARCH:-x86_64}" ;; -s) echo Linux ;; esac
STUB
printf '#!/bin/sh\necho "$1" >> "$FLTH_TEST_SLEEP_LOG"\n' > "$bin/sleep"
chmod +x "$bin"/*
export FLTH_TEST_RELEASE="$release"

output() { sed -n "s/^$1=//p" "$runner/github_output" | tail -1; }

# run_action <case>: the pin step, then (when FLTH_TEST_CACHED is set) a cache
# hit, then the install step with the fake hashes in place of the pinned ones
# (FLTH_TEST_ZIP_SHA / FLTH_TEST_BIN_SHA change them). Sets status and out.
run_action() {
    runner="$SANDBOX/runner-$1"
    mkdir -p "$runner/temp"
    : > "$runner/github_output"; : > "$runner/github_env"; : > "$runner/github_path"
    export FLTH_TEST_CURL_LOG="$runner/curl.log" FLTH_TEST_SLEEP_LOG="$runner/sleep.log"
    : > "$FLTH_TEST_CURL_LOG"; : > "$FLTH_TEST_SLEEP_LOG"
    local version="${FLTH_TEST_VERSION:-1.14.0}"
    out="$(cd "$runner" && env PATH="$bin:$PATH" RUNNER_TEMP="$runner/temp" GITHUB_OUTPUT="$runner/github_output" \
        VIRTIOFSD_VERSION="$version" bash --noprofile --norc -e -o pipefail "$steps/1" 2>&1)"
    status=$?
    [ "$status" = 0 ] || return 0
    if [ -n "${FLTH_TEST_CACHED:-}" ]; then
        mkdir -p "$(output dir)"
        cp "$FLTH_TEST_CACHED" "$(output dir)/$(output zip)"
    fi
    out="$out$(cd "$runner" && env PATH="$bin:$PATH" RUNNER_TEMP="$runner/temp" GITHUB_OUTPUT="$runner/github_output" \
        GITHUB_ENV="$runner/github_env" GITHUB_PATH="$runner/github_path" VIRTIOFSD_VERSION="$version" \
        VIRTIOFSD_ZIP="$(output zip)" VIRTIOFSD_URL="$(output url)" VIRTIOFSD_CACHE_DIR="$(output dir)" \
        VIRTIOFSD_ZIP_SHA256="${FLTH_TEST_ZIP_SHA:-$fake_zip_sha}" VIRTIOFSD_BIN_SHA256="${FLTH_TEST_BIN_SHA:-$fake_bin_sha}" \
        bash --noprofile --norc -e -o pipefail "$steps/2" 2>&1)"
    status=$?
}
# shellcheck disable=SC2329 # called through check_true's eval
installed() { [ -x "$runner/temp/virtiofsd-1.14.0/virtiofsd" ]; }
# check_true <condition> <ok message> <failure message>
check_true() { if eval "$1"; then ok "$2"; else bad "$3"; fi; }

run_action download
check_eq "$status" 0 "a download whose hashes match installs"
check_eq "$(output url)" "https://gitlab.com/-/project/21523468/uploads/f505704014ae7a816e515f2a05a93d8b/virtiofsd-v1.14.0.zip" "  from upstream's upload for 1.14.0"
check_eq "$(output zip_sha256)" 2e4fe9571f492b00baa34bc4e708e950039c5da05b830b31a8d179cb6ac8978e "  pinning the zip's SHA-256"
check_eq "$(output bin_sha256)" 15b2e72a78cc08a9bd8a6943e89fb69c88cb3cbeb63069efceade835342ac7d4 "  and the binary's"
check_contains "$(output key)" "virtiofsd-1.14.0-linux-x86_64-" "  cached under a key naming the version and platform"
check_eq "$(cat "$runner/github_env")" "FLTH_VIRTIOFSD=$runner/temp/virtiofsd-1.14.0/virtiofsd" "  and names it in FLTH_VIRTIOFSD"
check_eq "$(cat "$runner/github_path")" "$runner/temp/virtiofsd-1.14.0" "  and puts it on PATH"
check_eq "$(output path)" "$runner/temp/virtiofsd-1.14.0/virtiofsd" "  and gives its path as an output"
check_true installed "  and the binary is in place" "  and no binary was installed"
if cmp -s "$(output dir)/virtiofsd-v1.14.0.zip" "$release/virtiofsd-v1.14.0.zip"; then
    ok "  and the verified zip waits in the cache directory for the save"
else
    bad "  and no verified zip is in the cache directory"
fi

FLTH_TEST_CACHED="$release/virtiofsd-v1.14.0.zip" FLTH_TEST_OUTAGE=1 run_action cached
check_eq "$status" 0 "a cached zip whose hash matches installs with upstream down"
check_contains "$out" "comes from the cache" "  and says where it came from"
check_eq "$(wc -l < "$runner/curl.log" | tr -d ' ')" 0 "  without a download"

printf 'tampered\n' > "$SANDBOX/tampered.zip"
FLTH_TEST_CACHED="$SANDBOX/tampered.zip" run_action cached-tampered
check_true '[ "$status" -ne 0 ]' "a cached zip that does not match its hash fails the job" "a tampered cached zip was accepted"
check_contains "$out" "does not match its pinned SHA-256" "  saying why"
check_true '! installed' "  and installs nothing" "a tampered cached zip installed"

FLTH_TEST_ZIP_SHA="$(printf '0%.0s' $(seq 64))" run_action bad-zip
check_true '[ "$status" -ne 0 ]' "a downloaded zip that does not match its hash fails the job" "a zip with the wrong hash was accepted"
check_contains "$out" "the downloaded virtiofsd-v1.14.0.zip does not match its pinned SHA-256" "  naming the zip"
check_true '! installed' "  and installs nothing" "a zip with the wrong hash installed"
check_true '[ ! -e "$(output dir)/virtiofsd-v1.14.0.zip" ]' "  and caches nothing" "a zip with the wrong hash was left for the cache"

FLTH_TEST_BIN_SHA="$(printf '0%.0s' $(seq 64))" run_action bad-bin
check_true '[ "$status" -ne 0 ]' "a binary that does not match its hash fails the job" "a binary with the wrong hash was accepted"
check_contains "$out" "the virtiofsd in virtiofsd-v1.14.0.zip does not match its pinned SHA-256" "  naming the binary"
check_true '! installed' "  and installs nothing" "a binary with the wrong hash installed"

FLTH_TEST_SAYS="virtiofsd 1.10.0" run_action wrong-version
check_true '[ "$status" -ne 0 ]' "a binary that is not the version asked for fails the job" "a binary saying 1.10.0 was accepted as 1.14.0"
check_contains "$out" "says 'virtiofsd 1.10.0', not 'virtiofsd 1.14.0'" "  saying what it found"
check_eq "$(cat "$runner/github_env")" "" "  and names nothing in FLTH_VIRTIOFSD"

FLTH_TEST_OUTAGE=1 run_action outage
check_true '[ "$status" -ne 0 ]' "an outage that outlasts every attempt fails the job" "an outage passed"
check_contains "$out" "every attempt at https://gitlab.com/" "  naming the URL"
check_eq "$(wc -l < "$runner/curl.log" | tr -d ' ')" 3 "  after three attempts"
check_eq "$(tr '\n' ' ' < "$runner/sleep.log")" "60 120 " "  a minute and then two apart"

FLTH_TEST_VERSION=1.13.3 run_action unpinned
check_true '[ "$status" -ne 0 ]' "a version with no pinned line fails before any download" "an unpinned version was accepted"
check_contains "$out" "no pinned virtiofsd 1.13.3" "  saying so"
check_eq "$(wc -l < "$runner/curl.log" | tr -d ' ')" 0 "  and downloads nothing"

FLTH_TEST_ARCH=aarch64 run_action arm64
check_true '[ "$status" -ne 0 ]' "an arm64 runner fails: upstream publishes no build for it" "an arm64 runner was accepted"
check_contains "$out" "cargo install virtiofsd --version 1.14.0 --locked" "  naming how to build one"

finish install-virtiofsd
