#!/usr/bin/env bash
# Publish the checked-out version tag after its required CI jobs succeed.
set -euo pipefail

die() { echo "release: $*" >&2; exit 1; }
tag="${1:-}"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die 'expected a stable version tag, vMAJOR.MINOR.PATCH'
repo="${GITHUB_REPOSITORY:-}"
[ -n "$repo" ] || die 'GITHUB_REPOSITORY is required'
commit="$(git rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null)" || die "tag $tag does not exist"
[ "$(git rev-parse HEAD)" = "$commit" ] || die "the checkout does not match tag $tag"
git merge-base --is-ancestor "$commit" refs/remotes/origin/main || die "tag $tag is not on main"

work="$(mktemp -d "${TMPDIR:-/tmp}/flth-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git show "$commit:CHANGELOG.md" > "$work/changelog"
# The first version must be this tag, and its section must occur exactly once.
# Read the committed notes, never an edited working-tree copy.
if ! awk -v tag="$tag" '
    /^## v[0-9]/ {
        if (!newest) { newest=$2; if (newest != tag) exit 1 }
    }
    /^## / {
        copy=($2 == tag)
        if (copy) count++
        next
    }
    copy {
        if (!content && $0 !~ /[^[:space:]]/) next
        print
        if ($0 ~ /[^[:space:]]/) content=1
    }
    END { if (count != 1 || !content) exit 1 }
' "$work/changelog" > "$work/notes"; then
    die "CHANGELOG.md must have one nonempty, newest section for $tag"
fi

# A lookup failure must not be mistaken for an absent release. Pagination also
# keeps retries safe when this repository has more than one page of releases.
gh api --paginate "/repos/$repo/releases?per_page=100" \
    --jq '.[] | [.tag_name, .draft, .prerelease] | @tsv' > "$work/releases"
existing="$(awk -F '\t' -v tag="$tag" '$1 == tag { print; exit }' "$work/releases")"
if [ -n "$existing" ]; then
    [ "$existing" = "$(printf '%s\tfalse\tfalse' "$tag")" ] ||
        die "$tag already exists as a draft or prerelease; publication needs review"
    echo "release: $tag is already published"
    exit 0
fi

# Stable versions compare numerically: 1.10.0 is newer than 1.2.3. An older
# tag may be published, but it must not replace a newer stable latest release.
latest="$(awk -F '\t' -v tag="$tag" '
    function newer(candidate, current, a, b, i) {
        split(substr(candidate, 2), a, ".")
        split(substr(current, 2), b, ".")
        for (i=1; i<=3; i++) {
            if (a[i]+0 > b[i]+0) return 1
            if (a[i]+0 < b[i]+0) return 0
        }
        return 0
    }
    $2 == "false" && $3 == "false" && $1 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
        if (newer($1, tag)) older=1
    }
    END { print older ? "false" : "true" }
' "$work/releases")"
gh release create "$tag" --repo "$repo" --verify-tag --title "$tag" \
    --notes-file "$work/notes" --latest="$latest"
echo "release: $tag published"
