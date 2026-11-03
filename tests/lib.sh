# shellcheck shell=bash
#
# tests/lib.sh — shared by the VM-free tests. Sourced.
#
# Every test works in a sandbox under mktemp and points the harness's
# cache and state there, so nothing touches the real slot or machines.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fails=0
passes=0

ok() { printf 'ok    %s\n' "$1"; passes=$((passes + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

check_eq() {
    # check_eq <got> <want> <what>
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi
}

check_contains() {
    # check_contains <haystack> <needle> <what>
    case "$1" in
        *"$2"*) ok "$3" ;;
        *) bad "$3 (output lacked '$2'; got: $1)" ;;
    esac
}

check_lacks() {
    case "$1" in
        *"$2"*) bad "$3 (output wrongly contained '$2'; got: $1)" ;;
        *) ok "$3" ;;
    esac
}

require_guest_bash() {
    export FLTH_TEST_GUEST_BASH="${FLTH_TEST_GUEST_BASH:-bash}"
    if ! "$FLTH_TEST_GUEST_BASH" -c 'printf -v now "%(%s)T" -1' >/dev/null 2>&1; then
        bad "guest scripts need Bash 4.2 or newer: set FLTH_TEST_GUEST_BASH to that interpreter (macOS: brew install bash)"
        return 1
    fi
}

new_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/flth.XXXXXX")" || exit 1
    # shellcheck disable=SC2064  # expand now: the path is fixed
    trap "rm -rf '$SANDBOX'" EXIT
    export FLTH_CACHE_DIR="$SANDBOX/cache"
    export FLTH_STATE_DIR="$SANDBOX/state"
    unset FLTH_CONFIG FLTH_KEEP_VM FLTH_SLOT_WAIT FLTH_SLOT_BOOT_GRACE FLTH_SLOT_COUNT
    export FLTH_TEST_MEMINFO="$SANDBOX/meminfo"
    printf 'MemAvailable:   67108864 kB\n' > "$FLTH_TEST_MEMINFO"
    mkdir -p "$SANDBOX/memory-bin"
    cat > "$SANDBOX/memory-bin/awk" <<'STUB'
#!/bin/sh
if [ "$#" = 2 ] && [ "$2" = /proc/meminfo ]; then
    exec /usr/bin/awk "$1" "$FLTH_TEST_MEMINFO"
fi
exec /usr/bin/awk "$@"
STUB
    cat > "$SANDBOX/memory-bin/vm_stat" <<'STUB'
#!/bin/sh
printf '%s\n' 'Mach Virtual Memory Statistics: (page size of 16384 bytes)' 'Pages free: 4194304.' 'Pages inactive: 0.' 'Pages speculative: 0.'
STUB
    chmod +x "$SANDBOX/memory-bin/awk" "$SANDBOX/memory-bin/vm_stat"
    export PATH="$SANDBOX/memory-bin:$PATH"
}

# make_consumer <dir> <name> [extra toml...] — a consumer repository with
# a config and a setup script.
make_consumer() {
    local dir="$1" name="$2"
    shift 2
    mkdir -p "$dir"
    {
        printf '[project]\nname = "%s"\n\n[setup]\nscript = "setup.sh"\n' "$name"
        local line
        for line in "$@"; do printf '%s\n' "$line"; done
    } > "$dir/fs-linux-test-harness.toml"
    printf '#!/usr/bin/env bash\necho "setup ran for $FLTH_PROJECT" >> "${SETUP_LOG:-/dev/null}"\n' > "$dir/setup.sh"
}

# A copy of the harness whose engine is tests/stubs/engine.sh, so the
# orchestration can be driven through every engine answer — including
# the ones a real VM will not produce on demand. `sleep` is stubbed on
# PATH so retry and wait loops cost nothing.
make_stub_harness() {
    require_guest_bash || exit 1
    STUB_HARNESS="$SANDBOX/harness"
    mkdir -p "$STUB_HARNESS"
    cp -R "$REPO/scripts" "$STUB_HARNESS/"
    cp "$REPO/tests/stubs/engine.sh" "$STUB_HARNESS/scripts/lib/engine.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_HARNESS/scripts/host-tools.sh"
    chmod +x "$STUB_HARNESS/scripts/host-tools.sh"
    export FLTH_TEST_STUB="$SANDBOX/stub"
    mkdir -p "$FLTH_TEST_STUB/bin"
    printf '#!/bin/sh\nexit 0\n' > "$FLTH_TEST_STUB/bin/sleep"
    printf '#!/bin/sh\necho "shutdown $*" >> "%s/calls"\nexit 0\n' "$FLTH_TEST_STUB" > "$FLTH_TEST_STUB/bin/shutdown"
    chmod +x "$FLTH_TEST_STUB/bin/"*
    echo absent > "$FLTH_TEST_STUB/state"
    : > "$FLTH_TEST_STUB/calls"
    export PATH="$FLTH_TEST_STUB/bin:$PATH"
}

stub_calls() { cat "$FLTH_TEST_STUB/calls"; }
stub_reset_calls() { : > "$FLTH_TEST_STUB/calls"; }
stub_state() { printf '%s\n' "$1" > "$FLTH_TEST_STUB/state"; }

finish() {
    local name="$1"
    if [ "$fails" -eq 0 ]; then
        echo "PASS  $name ($passes checks)"
        exit 0
    fi
    echo "FAIL  $name: $fails of $((passes + fails)) checks failed" >&2
    exit 1
}
