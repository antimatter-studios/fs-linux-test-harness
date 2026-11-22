#!/usr/bin/env bash
#
# up-output.sh — what a macOS boot leaves running does not hold the caller's
# output open (#80).
#
# The macOS forwarder plugin starts its `notify-forwarder watch` processes
# during `vagrant up` with no redirection, so they keep Vagrant's stdout and
# stderr for as long as they live, which outlasts the VM. A test process that
# captures the output of `vm.sh up` waits for end-of-file on a pipe, and with
# one of those holding it the call never returned: rust-fs-ntfs's kernel tests
# sat for 47 minutes on their first `vm.sh up`, with the guest up and idle.
#
# `vagrant` is stubbed to do the same, with a process that lives for
# HOLD_SECONDS: a capture that takes that long waited for it to die.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

# Short on purpose, as in tests/engine-vagrant.sh: on macOS the socket
# directory under it is refused when too long.
FLTH_STATE_DIR="$(mktemp -d "${FLTH_TEST_SOCKET_ROOT:-/tmp}/flth.XXXXXX")"
export FLTH_STATE_DIR
trap '[ ! -f "$STUBDIR/daemon.pid" ] || kill "$(cat "$STUBDIR/daemon.pid")" 2>/dev/null; rm -rf "$SANDBOX" "$FLTH_STATE_DIR"' EXIT

HOLD_SECONDS=15
export HOLD_SECONDS
BIN="$SANDBOX/bin"
export STUBDIR="$SANDBOX/stubdir"
mkdir -p "$BIN" "$STUBDIR"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    up)
        echo "first line of the boot"
        /bin/sleep "$HOLD_SECONDS" &
        echo "$!" > "$STUBDIR/daemon.pid"
        echo "a line on stderr" >&2
        echo "last line of the boot"
        exit "$(cat "$STUBDIR/up-exit" 2>/dev/null || echo 0)"
        ;;
    ssh-config) printf 'Host default\n' ;;
esac
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

make_consumer "$SANDBOX/c" up-output-test
export FLTH_CONFIG="$SANDBOX/c/fs-linux-test-harness.toml"
. "$REPO/scripts/lib/common.sh"
flth_load
engine_prepare

started="$(date +%s)"
out="$(engine_up 2>&1)"
rc=$?
took=$(( $(date +%s) - started ))
check_eq "$rc" 0 "up succeeds"
check_eq "$([ "$took" -lt "$HOLD_SECONDS" ] && echo returned || echo held)" returned \
    "a capture of up's output ends when up does, not when what it started dies (took ${took}s)"
check_contains "$out" "first line of the boot" "the boot's stdout still reaches the caller"
check_contains "$out" "a line on stderr" "and its stderr"
check_contains "$out" "last line of the boot" "to the last line"
kill "$(cat "$STUBDIR/daemon.pid")" 2>/dev/null

# A consumer's first `vm.sh up` is a provisioning boot, which is the call #80
# was found on.
started="$(date +%s)"
out="$(engine_up --persist 2>&1)"
rc=$?
took=$(( $(date +%s) - started ))
check_eq "$rc" 0 "a provisioning boot succeeds"
check_eq "$([ "$took" -lt "$HOLD_SECONDS" ] && echo returned || echo held)" returned \
    "and a capture of its output ends when it does (took ${took}s)"
check_contains "$out" "last line of the boot" "with all of what it printed"
kill "$(cat "$STUBDIR/daemon.pid")" 2>/dev/null

echo 3 > "$STUBDIR/up-exit"
started="$(date +%s)"
out="$(engine_up 2>&1)"
rc=$?
took=$(( $(date +%s) - started ))
check_eq "$rc" 3 "a boot that fails fails up, with Vagrant's status"
check_eq "$([ "$took" -lt "$HOLD_SECONDS" ] && echo returned || echo held)" returned "and returns too (took ${took}s)"
check_contains "$out" "last line of the boot" "with all of what it printed"

finish up-output
