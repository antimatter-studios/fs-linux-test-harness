#!/usr/bin/env bash
#
# readme-version.sh — the README names the newest release in CHANGELOG.md,
# and no other version of the harness.
#
# The README carried a "status: unreleased" badge through two tags (#27):
# it named no version, so the release step "fix anything in the README that
# still names the previous version" had nothing to find. The badge now names
# the release, and this test makes a release PR that forgets it fail.
#
# The newest `## vX.Y.Z` heading in CHANGELOG.md is the version, not `git
# tag`: the release PR moves that heading before the tag exists, and CI's
# checkout carries no tags.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

# problems <readme> <changelog> — one line per disagreement; silent if none.
problems() {
    local readme="$1" changelog="$2" latest v
    latest="$(sed -n 's/^## \(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\( .*\)\{0,1\}$/\1/p' "$changelog" | head -n 1)"
    if [ -z "$latest" ]; then
        echo "CHANGELOG.md has no '## vX.Y.Z' release heading"
        return
    fi
    grep -qF "[![Release: $latest](https://img.shields.io/badge/release-$latest-blue.svg)](./CHANGELOG.md)" "$readme" \
        || echo "the README has no release badge naming $latest"
    grep -qi 'unreleased' "$readme" && echo "the README still calls the harness unreleased"
    # Only this harness's versions: the README also pins the box's and
    # Vagrant's own releases, which are not ours to move.
    grep -E 'LINUX_HARNESS_REF|fs-linux-test-harness|badge/release-' "$readme" \
        | grep -o 'v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | sort -u \
        | while read -r v; do
            [ "$v" = "$latest" ] || echo "the README names $v, not the latest release $latest"
        done
}

check_eq "$(problems "$REPO/README.md" "$REPO/CHANGELOG.md")" "" \
    "the committed README names the newest CHANGELOG release and no other version"

# The refusals, on copies in the sandbox: a check that cannot fail is no check.
LATEST="$(sed -n 's/^## \(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$REPO/CHANGELOG.md" | head -n 1)"

# mutated <file> <sed program> — a copy of a committed file, edited.
mutated() {
    local out="$SANDBOX/m$RANDOM$RANDOM"
    sed "$2" "$1" > "$out"
    echo "$out"
}

check_contains "$(problems "$(mutated "$REPO/README.md" \
    's#^\[!\[Release: .*#[![Status: unreleased](https://img.shields.io/badge/status-unreleased-yellow.svg)](./CHANGELOG.md)#')" \
    "$REPO/CHANGELOG.md")" "no release badge naming $LATEST" \
    "the old 'status: unreleased' badge is refused"
check_contains "$(problems "$(mutated "$REPO/README.md" \
    "/badge\/release-/s#$LATEST#v0.0.1#g")" "$REPO/CHANGELOG.md")" "names v0.0.1" \
    "a badge naming an older release is refused"
check_contains "$(problems "$(mutated "$REPO/README.md" \
    "s#LINUX_HARNESS_REF: $LATEST#LINUX_HARNESS_REF: v0.0.1#")" "$REPO/CHANGELOG.md")" "names v0.0.1" \
    "a quickstart pinning an older release is refused"
NEXT="$SANDBOX/next-changelog"
awk '{ print } /^## \[Unreleased\]$/ { print ""; print "## v99.0.0 — 2099-01-01" }' "$REPO/CHANGELOG.md" > "$NEXT"
check_contains "$(problems "$REPO/README.md" "$NEXT")" "no release badge naming v99.0.0" \
    "a release heading the README was not moved to is refused"
check_contains "$(problems "$REPO/README.md" "$(mutated "$REPO/CHANGELOG.md" '/^## v/d')")" \
    "no '## vX.Y.Z' release heading" "a CHANGELOG with no release is refused"

finish readme-version
