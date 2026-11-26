# shellcheck shell=bash
#
# lib/build.sh — THE BUILD BEFORE THE GUEST: `vm.sh build`, and the first step
# of `vm.sh guest-test` for a consumer with a [build] section.
#
# Sourced by vm.sh, never executed.
#
# A CHAIN, AS A PIPELINE RUNS IT. One step compiles, in a container on the
# host, and hands what it made to the next step, which tests it in the guest.
# The guest never compiles, so it needs no compiler, and a run on a workstation
# goes through the same two steps as a run in CI.
#
# The harness knows nothing about what is built. The consumer's Dockerfile
# says what the container has, and [build] command says what runs in it. The
# harness builds the image, mounts the repository and the siblings it names
# read-only, gives the command an empty output directory, and puts what it
# wrote where the guest finds it: $FLTH_SHARE_HOST/build on the host, which is
# $FLTH_SHARE_GUEST/build in the guest, named there by FLTH_BUILD_DIR.
#
# THE CONTAINER IS THE GUEST'S ARCHITECTURE, run natively. The shared guest is
# the host's architecture (lib/profile.sh), so the image is built for it and a
# container of any other architecture is refused: what it built would not run.
#
# A BUILD CACHE THAT OUTLIVES THE CONTAINER. Every build is a fresh container,
# so it would compile from nothing every time. A Docker volume of this
# project's and architecture's is mounted at /cache (FLTH_BUILD_CACHE), kept
# across builds, for the command to keep its build directory in. The harness
# knows nothing about what is kept there; `docker volume rm` clears it.
#
# THE IMAGE IS BUILT ONCE PER RECIPE. Its tag carries a SHA-256 of every file
# in its build context and the architecture, so a changed recipe is a new
# image and an unchanged one is reused, without asking a registry anything.

FLTH_BUILD_KEY_VERSION=1
# Where the repository and its siblings are in the container, and where the
# command writes what the guest is to run.
FLTH_BUILD_SOURCE=/source
FLTH_BUILD_OUTPUT=/output
FLTH_BUILD_CACHE=/cache
# The container client. A path or a name on PATH; tests point it at a stand-in.
FLTH_DOCKER="${FLTH_DOCKER:-docker}"

build_configured() { [ -n "$CFG_build_command" ]; }

# The guest's architecture, as the kernel names it.
build_guest_arch() { flth_guest_arch; }

# The same, as an image platform names it.
build_platform_arch() {
    case "$1" in
        x86_64) echo amd64 ;;
        aarch64) echo arm64 ;;
        *) return 1 ;;
    esac
}

build_require_docker() {
    if ! command -v "$FLTH_DOCKER" >/dev/null 2>&1; then
        echo "vm: [build] in $FLTH_CONFIG compiles in a container, and this host has no '$FLTH_DOCKER'." >&2
        echo "    Install Docker (Docker Desktop on macOS, docker.io on Debian), then retry." >&2
        echo "    The guest never compiles, so there is no build to fall back to." >&2
        return 1
    fi
    if ! "$FLTH_DOCKER" info >/dev/null 2>&1; then
        echo "vm: [build] needs a running Docker daemon, and 'docker info' cannot reach one." >&2
        echo "    Start Docker (or select a working context with 'docker context use'), then retry." >&2
        return 1
    fi
}

# Fill an empty directory with the image's build context: the consumer's
# [build] context script writes it, or it is the Dockerfile's own directory.
# Either way the Dockerfile is at its root, named Dockerfile.
build_context() {
    local dir="$1"
    if [ -n "$CFG_build_context" ]; then
        (cd "$FLTH_ROOT" && bash "$FLTH_ROOT/$CFG_build_context" "$dir") || {
            echo "vm: [build] context script $CFG_build_context failed." >&2
            return 1
        }
    else
        cp -R "$(dirname "$FLTH_ROOT/$CFG_build_dockerfile")/." "$dir/" || return 1
    fi
    cp "$FLTH_ROOT/$CFG_build_dockerfile" "$dir/Dockerfile"
}

# The recipe's key: every file of the context, by path and content, and the
# architecture it is built for.
build_key() {
    local dir="$1" arch="$2" file
    {
        printf 'fs-linux-test-harness build %s %s\n' "$FLTH_BUILD_KEY_VERSION" "$arch"
        (cd "$dir" && find . -type f | LC_ALL=C sort) | while IFS= read -r file; do
            printf '%s %s\n' "$(sha256_of "$dir/$file")" "$file"
        done
    } | {
        if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
    } | awk '{print $1}'
}

# Build the image for this recipe unless it is already here, and print its tag.
build_image() {
    local arch="$1" platform context key tag actual rc=0
    platform="$(build_platform_arch "$arch")" ||
        { echo "vm: no container platform for a $arch guest." >&2; return 1; }
    context="$(mktemp -d "${TMPDIR:-/tmp}/flth-build.XXXXXX")" || return 1
    build_context "$context" || rc=1
    if [ "$rc" = 0 ]; then
        key="$(build_key "$context" "$arch")" || rc=1
    fi
    if [ "$rc" = 0 ]; then
        tag="fs-linux-test-harness/$CFG_project_name-build:${key:0:32}"
        if ! "$FLTH_DOCKER" image inspect "$tag" >/dev/null 2>&1; then
            echo "[vm] building the $CFG_project_name build image for linux/$platform ($tag)..." >&2
            "$FLTH_DOCKER" build --platform "linux/$platform" \
                --label "fs-linux-test-harness.build-key=$key" \
                --tag "$tag" "$context" >&2 || {
                echo "vm: the [build] image from $CFG_build_dockerfile did not build." >&2
                rc=1
            }
        fi
    fi
    rm -rf "$context"
    [ "$rc" = 0 ] || return 1
    actual="$("$FLTH_DOCKER" image inspect --format '{{.Architecture}}' "$tag")" || return 1
    if [ "$actual" != "$platform" ]; then
        echo "vm: the [build] image $tag is $actual, and the guest is $arch ($platform)." >&2
        echo "    What it builds would not run there. Remove the image ('docker image rm $tag') and retry." >&2
        return 1
    fi
    printf '%s\n' "$tag"
}

# THE BUILD STEP. Run [build] command in a fresh container of the recipe's image.
vm_build() {
    build_configured || flth_die "$FLTH_CONFIG has no [build] section"
    build_require_docker || exit 1
    local arch platform tag output sibling path status
    local -a mounts
    arch="$(build_guest_arch)"
    platform="$(build_platform_arch "$arch")" ||
        flth_die "no container platform for a $arch guest"
    tag="$(build_image "$arch")" || exit 1

    mounts=(--mount "type=bind,src=$FLTH_ROOT,dst=$FLTH_BUILD_SOURCE/$CFG_project_name,readonly")
    for sibling in $CFG_build_siblings; do
        path="$(cd "$FLTH_ROOT/../$sibling" 2>/dev/null && pwd -P)" || {
            echo "vm: [build] siblings names $sibling, and $FLTH_ROOT/../$sibling is not a directory." >&2
            exit 1
        }
        mounts+=(--mount "type=bind,src=$path,dst=$FLTH_BUILD_SOURCE/$sibling,readonly")
    done

    # A fresh output every time: the guest runs exactly what this build made.
    output="$FLTH_SHARE_HOST/build"
    rm -rf "$output"
    mkdir -p "$output"
    mounts+=(--mount "type=bind,src=$output,dst=$FLTH_BUILD_OUTPUT")
    mounts+=(--mount "type=volume,src=fs-linux-test-harness-$CFG_project_name-$arch-build-cache,dst=$FLTH_BUILD_CACHE")

    echo "[vm] building $CFG_project_name for the $arch guest in $tag..." >&2
    # The command runs as the image's user. What it wrote is handed back to
    # this host's user afterwards, so the share can be cleaned without root.
    status=0
    "$FLTH_DOCKER" run --rm --pull=never --platform "linux/$platform" \
        "${mounts[@]}" \
        --workdir "$FLTH_BUILD_SOURCE/$CFG_project_name" \
        --env FLTH_BUILD=1 \
        --env "FLTH_PROJECT=$CFG_project_name" \
        --env "FLTH_GUEST_ARCH=$arch" \
        --env "FLTH_BUILD_OUTPUT=$FLTH_BUILD_OUTPUT" \
        --env "FLTH_BUILD_SOURCE=$FLTH_BUILD_SOURCE" \
        --env "FLTH_BUILD_CACHE=$FLTH_BUILD_CACHE" \
        --env "FLTH_BUILD_JOBS=$CFG_vm_build_jobs" \
        --env "FLTH_HOST_OWNER=$(id -u):$(id -g)" \
        "$tag" bash -c '
            bash -c "$0 \"\$@\"" flth-build "$@"
            status=$?
            chown -R "$FLTH_HOST_OWNER" "$FLTH_BUILD_OUTPUT" 2>/dev/null || true
            exit "$status"
        ' "$CFG_build_command" "$@" || status=$?
    if [ "$status" != 0 ]; then
        echo "vm: [build] command '$CFG_build_command' failed with status $status; the guest is not started for it." >&2
        exit "$status"
    fi
    echo "[vm] built: $output (the guest's $FLTH_SHARE_GUEST/build)" >&2
}
