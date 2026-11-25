#!/usr/bin/env bash
# The chain: a container on the host compiles ([build]), the guest tests what it
# compiled (guest-test). Driven through a stand-in Docker (tests/stubs/docker).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
export FLTH_TEST_DOCKER="$SANDBOX/docker"
mkdir -p "$FLTH_TEST_DOCKER"
# Never the host's own Docker: every call goes to the stand-in.
export FLTH_DOCKER="$REPO/tests/stubs/docker"
export FLTH_BUILD_JOBS=2
ARCH="$(uname -m)"
case "$ARCH" in arm64) ARCH=aarch64 ;; esac
case "$ARCH" in x86_64) PLATFORM=amd64 ;; aarch64) PLATFORM=arm64 ;; *) PLATFORM=unknown ;; esac

C="$SANDBOX/work/consumer"
make_consumer "$C" chain '[build]' 'dockerfile = "builder/Dockerfile"' \
    'command = "bash build.sh"' 'siblings = "core"' \
    '[test]' 'guest_command = "bash suite.sh"'
mkdir -p "$C/builder" "$SANDBOX/work/core"
printf 'FROM scratch\n' > "$C/builder/Dockerfile"
printf 'pinned 1\n' > "$C/builder/recipe.txt"
printf 'core\n' > "$SANDBOX/work/core/marker"
cat > "$C/build.sh" <<'BUILD'
printf 'built for %s from %s with %s\n' "$FLTH_GUEST_ARCH" "$(cat ../core/marker 2>/dev/null || echo "$FLTH_BUILD_SOURCE")" "$*" > "$FLTH_BUILD_OUTPUT/artifact"
printf '%s %s %s\n' "$FLTH_BUILD" "$FLTH_PROJECT" "$FLTH_BUILD_JOBS" > "$FLTH_BUILD_OUTPUT/env"
[ ! -f "$FLTH_BUILD_OUTPUT/../fail-build" ] || exit 3
BUILD
cat > "$C/suite.sh" <<'SUITE'
printf 'suite reads %s: %s\n' "$FLTH_BUILD_DIR" "$(cat "$FLTH_BUILD_DIR/artifact")"
SUITE
mkdir -p "$FLTH_TEST_STUB/guest-repo"
cp "$C/suite.sh" "$FLTH_TEST_STUB/guest-repo/suite.sh"
vm() { (cd "$C" && "$VM" "$@"); }
builds() { grep -c '^build ' "$FLTH_TEST_DOCKER/calls" 2>/dev/null; }

# --- the configuration ---
config="$(vm config 2>&1)"
check_contains "$config" 'build.dockerfile=builder/Dockerfile' 'config reports the build image recipe'
check_contains "$config" 'build.siblings=core' 'config reports the mounted siblings'
check_contains "$(cd "$SANDBOX" && make_consumer plain plain && cd plain && "$VM" config 2>&1)" \
    'build.command=none' 'a consumer with no [build] section has no build step'
for case in 'command = "x"|dockerfile is required' \
    'dockerfile = "builder/Dockerfile"|command is required' \
    'dockerfile = "missing/Dockerfile"|command = "x"|which is not a file' \
    'dockerfile = "../Dockerfile"|command = "x"|must stay inside the repository' \
    'dockerfile = "builder/Dockerfile"|command = "x"|context = "nope.sh"|context names nope.sh' \
    'dockerfile = "builder/Dockerfile"|command = "x"|siblings = "../up"|siblings must be directory names' \
    'dockerfile = "builder/Dockerfile"|command = "x"|image = "y"|unknown key'; do
    IFS='|' read -r -a parts <<< "$case"
    expect="${parts[${#parts[@]}-1]}"
    unset 'parts[${#parts[@]}-1]'
    bad="$SANDBOX/bad"
    rm -rf "$bad"
    make_consumer "$bad" bad '[build]' "${parts[@]}"
    mkdir -p "$bad/builder" && printf 'FROM scratch\n' > "$bad/builder/Dockerfile"
    out="$(FLTH_CONFIG="$bad/fs-linux-test-harness.toml" "$VM" config 2>&1)"; rc=$?
    check_eq "$rc" 1 "a [build] section is refused: $expect"
    check_contains "$out" "$expect" "the refusal says why: $expect"
done

# --- no Docker: the build fails, names Docker, and no guest boots ---
stub_reset_calls
out="$(cd "$C" && FLTH_DOCKER="$SANDBOX/absent/docker" "$VM" guest-test 2>&1)"; rc=$?
check_eq "$rc" 1 'guest-test with [build] and no docker fails'
check_contains "$out" "has no '$SANDBOX/absent/docker'" 'the failure names the missing client'
check_contains "$out" 'Install Docker' 'and says what to install'
check_contains "$out" 'no build to fall back to' 'and says the guest never compiles instead'
check_lacks "$(stub_calls)" 'up' 'no guest is booted without a build'
touch "$FLTH_TEST_DOCKER/down"
out="$(vm build 2>&1)"; rc=$?
check_eq "$rc" 1 'a Docker with no daemon fails the build'
check_contains "$out" 'docker info' 'the failure says what could not be reached'
rm -f "$FLTH_TEST_DOCKER/down"

# --- the build: image built once per recipe, output fresh, sources read-only ---
mkdir -p "$C/.vm-share/build" && printf 'stale\n' > "$C/.vm-share/build/stale"
out="$(vm build one two 2>&1)"; rc=$?
check_eq "$rc" 0 'vm build succeeds'
check_eq "$(builds)" 1 'the first build makes the image'
check_eq "$(cat "$FLTH_TEST_DOCKER/last-context")" "$(printf './Dockerfile\n./recipe.txt')" \
    "the image's context is the Dockerfile's directory"
check_contains "$(grep '^build ' "$FLTH_TEST_DOCKER/calls")" "--platform linux/$PLATFORM" 'the image is built for the guest architecture'
check_eq "$(cat "$C/.vm-share/build/artifact" 2>/dev/null)" "built for $ARCH from core with one two" \
    'the command ran with the guest architecture, the sibling and its arguments'
check_eq "$(cat "$C/.vm-share/build/env" 2>/dev/null)" '1 chain 2' 'the command gets the build markers and job limit'
if [ -e "$C/.vm-share/build/stale" ]; then
    bad 'a stale output is removed before the build'
else
    ok 'a stale output is removed before the build'
fi
run_call="$(grep '^run ' "$FLTH_TEST_DOCKER/calls" | tail -1)"
check_contains "$run_call" "src=$C,dst=/source/chain,readonly" 'the repository is mounted read-only'
check_contains "$run_call" "src=$(cd "$SANDBOX/work/core" && pwd -P),dst=/source/core,readonly" 'the sibling is mounted read-only beside it'
check_contains "$run_call" "src=$C/.vm-share/build,dst=/output" 'the output is the share'"'"'s build directory'
check_contains "$run_call" '--pull=never' 'the container runs the image built here'
check_contains "$run_call" "type=volume,src=fs-linux-test-harness-chain-$ARCH-build-cache,dst=/cache" \
    'a build cache volume of the project and architecture is kept across builds'
check_contains "$run_call" 'FLTH_BUILD_CACHE=/cache' 'the command is told where the cache is'
check_contains "$out" '/share/build' 'the build says where the guest finds it'
vm build >/dev/null 2>&1
check_eq "$(builds)" 1 'an unchanged recipe reuses its image'
printf 'pinned 2\n' > "$C/builder/recipe.txt"
vm build >/dev/null 2>&1
check_eq "$(builds)" 2 'a changed recipe file builds a new image'

# --- a context script assembles the context ---
cat > "$C/context.sh" <<'CTX'
cp builder/recipe.txt "$1/extra.txt"
CTX
sed -i.bak 's|^command = "bash build.sh"|command = "bash build.sh"\ncontext = "context.sh"|' "$C/fs-linux-test-harness.toml"
rm -f "$C/fs-linux-test-harness.toml.bak"
vm build >/dev/null 2>&1; rc=$?
check_eq "$rc" 0 'a build with a context script succeeds'
check_eq "$(cat "$FLTH_TEST_DOCKER/last-context")" "$(printf './Dockerfile\n./extra.txt')" \
    'the context script writes the context, and the Dockerfile is added at its root'

# --- an image of another architecture is refused ---
printf 'riscv64\n' > "$FLTH_TEST_DOCKER/arch"
printf 'pinned 3\n' > "$C/builder/recipe.txt"
out="$(vm build 2>&1)"; rc=$?
check_eq "$rc" 1 'an image of another architecture is refused'
check_contains "$out" 'would not run there' 'the refusal says why'
rm -f "$FLTH_TEST_DOCKER/arch"
printf 'pinned 3, native\n' > "$C/builder/recipe.txt"

# --- a failed build: its status, and no guest ---
touch "$C/.vm-share/fail-build"
stub_reset_calls
out="$(vm guest-test 2>&1)"; rc=$?
check_eq "$rc" 3 'a failed build fails guest-test with the build status'
check_contains "$out" 'the guest is not started for it' 'the failure says the guest was not started'
check_lacks "$(stub_calls)" 'up' 'no guest is booted for a failed build'
rm -f "$C/.vm-share/fail-build"
touch "$FLTH_TEST_DOCKER/build_fails"
printf 'pinned 4\n' > "$C/builder/recipe.txt"
out="$(vm build 2>&1)"; rc=$?
check_eq "$rc" 1 'an image that does not build fails the build'
check_contains "$out" 'did not build' 'the failure names the image'
rm -f "$FLTH_TEST_DOCKER/build_fails"

# --- the chain: guest-test builds, then the guest reads what was built ---
out="$(vm guest-test 2>&1)"; rc=$?
check_eq "$rc" 0 'guest-test builds and then runs the guest command'
check_contains "$out" "suite reads $C/.vm-share/build: built for $ARCH" \
    'the guest command finds the build at FLTH_BUILD_DIR'
before="$(grep -n 'building chain for' <<< "$out" | head -1 | cut -d: -f1)"
after="$(grep -n 'suite reads' <<< "$out" | head -1 | cut -d: -f1)"
if [ -n "$before" ] && [ -n "$after" ] && [ "$before" -lt "$after" ]; then
    ok 'the build runs before the guest command'
else
    bad 'the build runs before the guest command'
fi
finish build
