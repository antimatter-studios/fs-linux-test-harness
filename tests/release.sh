#!/usr/bin/env bash
# Publish only the tagged commit's notes, after CI has accepted the tag.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
PUBLISH="$REPO/scripts/release.sh"
if [ ! -x "$PUBLISH" ]; then
    bad "scripts/release.sh exists and is executable"
    finish release
    exit 1
fi

TREE="$SANDBOX/repo"
TOOLS="$SANDBOX/bin"
mkdir -p "$TREE" "$TOOLS"
git -C "$TREE" init -q
git -C "$TREE" config user.name 'Release test'
git -C "$TREE" config user.email 'release-test@example.invalid'
cat > "$TREE/CHANGELOG.md" <<'NOTES'
# Changelog

## v1.2.3 — 2026-11-13

### Changed

- A literal `$value` and `$(command)` remain unchanged.

## v1.2.2 — 2026-11-12

### Fixed

- Earlier notes do not leak into this release.
NOTES
git -C "$TREE" add CHANGELOG.md
git -C "$TREE" commit -qm 'test: release notes are committed'
git -C "$TREE" tag v1.2.3
git -C "$TREE" update-ref refs/remotes/origin/main HEAD
export GITHUB_REPOSITORY=example/harness
export RELEASE_CALLS="$SANDBOX/calls" RELEASE_NOTES="$SANDBOX/notes"
export RELEASE_LIST="$SANDBOX/releases" RELEASE_API_FAIL=0 RELEASE_CREATE_FAIL=0
: > "$RELEASE_LIST"
cat > "$TOOLS/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    api)
        [ "$RELEASE_API_FAIL" = 0 ] || { echo 'API unavailable' >&2; exit 42; }
        cat "$RELEASE_LIST"
        ;;
    release)
        printf '%s\n' "$*" > "$RELEASE_CALLS"
        while [ "$#" -gt 0 ]; do
            case "$1" in --notes-file) cp "$2" "$RELEASE_NOTES" ;; esac
            shift
        done
        [ "$RELEASE_CREATE_FAIL" = 0 ] || { echo 'publication failed' >&2; exit 43; }
        ;;
    *) exit 99 ;;
esac
STUB
chmod +x "$TOOLS/gh"
export PATH="$TOOLS:$PATH"
run_publish() { (cd "$TREE" && "$PUBLISH" "$@") > "$SANDBOX/out" 2>&1; RESULT=$?; }

run_publish v1.2.3
check_eq "$RESULT" 0 "a valid tag publishes"
check_contains "$(cat "$RELEASE_CALLS")" '--verify-tag' "publication cannot create an absent tag"
check_contains "$(cat "$RELEASE_CALLS")" '--latest=true' "the first release becomes latest"
expected='### Changed

- A literal `$value` and `$(command)` remain unchanged.'
check_eq "$(cat "$RELEASE_NOTES")" "$expected" "notes come only from the tagged version, without evaluation"

printf '\nv1.2.3\tfalse\tfalse\n' > "$RELEASE_LIST"
rm -f "$RELEASE_CALLS"
run_publish v1.2.3
check_eq "$RESULT" 0 "a retry accepts the existing published release"
check_eq "$([ -e "$RELEASE_CALLS" ] && echo called || echo untouched)" untouched "a retry does not duplicate or edit publication"

printf 'v1.2.3\ttrue\tfalse\n' > "$RELEASE_LIST"
run_publish v1.2.3
check_eq "$RESULT" 1 "an existing draft is not reported as published"
printf 'v1.2.3\tfalse\ttrue\n' > "$RELEASE_LIST"
run_publish v1.2.3
check_eq "$RESULT" 1 "an existing prerelease is not reported as stable"

printf 'v1.10.0\tfalse\tfalse\nv9.0.0\ttrue\tfalse\n' > "$RELEASE_LIST"
run_publish v1.2.3
check_eq "$RESULT" 0 "a historical release publishes"
check_contains "$(cat "$RELEASE_CALLS")" '--latest=false' "numeric version ordering preserves a newer latest release"
printf 'v1.2.2\tfalse\tfalse\nv9.0.0\tfalse\ttrue\n' > "$RELEASE_LIST"
run_publish v1.2.3
check_contains "$(cat "$RELEASE_CALLS")" '--latest=true' "a prerelease does not prevent a newer stable latest release"

export RELEASE_API_FAIL=1
rm -f "$RELEASE_CALLS"
run_publish v1.2.3
check_eq "$RESULT" 42 "a release lookup failure fails publication"
check_eq "$([ -e "$RELEASE_CALLS" ] && echo called || echo untouched)" untouched "a failed lookup does not attempt creation"
export RELEASE_API_FAIL=0 RELEASE_CREATE_FAIL=1
run_publish v1.2.3
check_eq "$RESULT" 43 "a publication failure remains a failure"
export RELEASE_CREATE_FAIL=0

for invalid in v01.2.3 v1.2.3-rc.1 main; do
    run_publish "$invalid"
    check_eq "$RESULT" 1 "invalid stable version $invalid is refused"
done
run_publish v1.2.4
check_eq "$RESULT" 1 "a missing tag is refused"
git -C "$TREE" tag v1.2.2
run_publish v1.2.2
check_eq "$RESULT" 1 "an older section cannot publish under this commit's newest version"

printf 'uncommitted edits\n' > "$TREE/CHANGELOG.md"
run_publish v1.2.3
check_eq "$RESULT" 0 "working-tree edits do not replace tagged notes"
check_eq "$(cat "$RELEASE_NOTES")" "$expected" "the committed notes remain the publication source"
git -C "$TREE" add CHANGELOG.md
git -C "$TREE" commit -qm 'test: the checkout has moved'
run_publish v1.2.3
check_eq "$RESULT" 1 "a checkout at another commit cannot publish the tag"
git -C "$TREE" tag v2.0.0
run_publish v2.0.0
check_eq "$RESULT" 1 "a tag outside main is refused"
git -C "$TREE" update-ref refs/remotes/origin/main HEAD
run_publish v2.0.0
check_eq "$RESULT" 1 "a missing changelog section is refused"

for kind in empty duplicate; do
    printf '## v2.0.0 — 2026-11-13\n\n' > "$TREE/CHANGELOG.md"
    if [ "$kind" = duplicate ]; then
        printf '### Fixed\n\n- First section.\n\n## v2.0.0 — 2026-11-13\n\n- Duplicate.\n' >> "$TREE/CHANGELOG.md"
    fi
    git -C "$TREE" add CHANGELOG.md
    git -C "$TREE" commit -qm "test: the changelog section is $kind"
    git -C "$TREE" tag -f v2.0.0 > /dev/null
    git -C "$TREE" update-ref refs/remotes/origin/main HEAD
    run_publish v2.0.0
    check_eq "$RESULT" 1 "the $kind changelog section is refused"
done

run_publish
check_eq "$RESULT" 1 "an absent version argument is refused"
export GITHUB_REPOSITORY=
run_publish v2.0.0
check_eq "$RESULT" 1 "a missing repository is refused"

finish release
