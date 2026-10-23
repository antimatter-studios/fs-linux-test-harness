#!/usr/bin/env bash
#
# ci-setup-apt.sh — scripts/lib/apt.sh, the bounded apt-get that
# scripts/ci-setup-linux.sh installs QEMU and Vagrant through (#77). On
# 2026-10-22 the QEMU group's two silenced apt-get calls held hosted runners
# for up to 26 minutes, printing nothing, and cancelled fixture jobs. So
# every call carries apt's own retries and connection timeouts, is bounded
# as a whole by `timeout`, prints a line before it starts and one when it
# ends, and fails naming what it was fetching when it stalls.
#
# Run with `sudo` and `apt-get` stubbed on PATH; `timeout` and `sleep` are
# the real ones.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

LIB="$REPO/scripts/lib/apt.sh"
SETUP="$REPO/scripts/ci-setup-linux.sh"

if ! command -v timeout >/dev/null 2>&1; then
    bad "timeout is required: install coreutils"
    finish ci-setup-apt
fi
if [ ! -f "$LIB" ]; then
    bad "scripts/lib/apt.sh exists"
    finish ci-setup-apt
fi

bin="$SANDBOX/bin"
mkdir -p "$bin"
# sudo runs its command, environment assignments first, as sudo does.
printf '#!/usr/bin/env bash\nexec env "$@"\n' > "$bin/sudo"
# apt-get logs its arguments and frontend; $SANDBOX/hang makes it stall,
# $SANDBOX/fail makes it fail.
cat > "$bin/apt-get" <<STUB
#!/usr/bin/env bash
echo "apt-get \$* frontend=\${DEBIAN_FRONTEND:-}" >> "$SANDBOX/calls"
[ -f "$SANDBOX/hang" ] && exec sleep 30
[ -f "$SANDBOX/fail" ] && exit 100
exit 0
STUB
cat > "$SANDBOX/run-apt" <<RUN
#!/usr/bin/env bash
. "$LIB"
flth_apt "\$@"
RUN
chmod +x "$bin/"* "$SANDBOX/run-apt"

run_apt() {
    : > "$SANDBOX/calls"
    out="$(PATH="$bin:$PATH" "$SANDBOX/run-apt" "$@" 2>&1)"
    rc=$?
    calls="$(cat "$SANDBOX/calls")"
}

# A call that finishes.
run_apt "QEMU" install -y -qq qemu-system-x86 qemu-utils
check_eq "$rc" 0 "a finished install succeeds"
check_contains "$calls" "-o Acquire::Retries=3" "apt retries a failed fetch"
check_contains "$calls" "-o Acquire::http::Timeout=30" "apt gives up on a silent http connection"
check_contains "$calls" "-o Acquire::https::Timeout=30" "apt gives up on a silent https connection"
check_contains "$calls" "install -y -qq qemu-system-x86 qemu-utils" "the caller's arguments reach apt-get"
check_contains "$calls" "frontend=noninteractive" "apt-get runs noninteractive"
check_contains "$out" "QEMU" "a line names the call before it starts"
check_contains "$out" "done in" "a line reports that it finished"

# A call that stalls is cut off at its bound and names what stalled.
touch "$SANDBOX/hang"
export FLTH_APT_TIMEOUT=2
start=$SECONDS
run_apt "QEMU" install -y -qq qemu-utils
elapsed=$((SECONDS - start))
unset FLTH_APT_TIMEOUT
rm -f "$SANDBOX/hang"
if [ "$rc" -ne 0 ]; then ok "a stalled apt-get fails"; else bad "a stalled apt-get fails (it exited 0)"; fi
if [ "$elapsed" -lt 20 ]; then
    ok "a stalled apt-get is cut off at its bound"
else
    bad "a stalled apt-get is cut off at its bound (it took $elapsed s against a 2 s bound)"
fi
check_contains "$out" "did not finish within 2 s" "the stall is reported with its bound"
check_contains "$out" "QEMU" "the stall names what was being fetched"

# A call that fails keeps apt-get's status.
touch "$SANDBOX/fail"
run_apt "QEMU" install -y -qq qemu-utils
rm -f "$SANDBOX/fail"
check_eq "$rc" 100 "a failed apt-get keeps its exit status"
check_contains "$out" "exit 100" "the failure names apt-get's status"

# ci-setup-linux.sh calls apt-get only through the bounded call: the
# package index and QEMU, then HashiCorp's index and Vagrant.
direct="$(grep -nE '(^|[^-_[:alnum:]])apt-get ' "$SETUP" | grep -vE '^[0-9]+: *#' || true)"
check_eq "$direct" "" "ci-setup-linux.sh runs no apt-get of its own"
check_eq "$(grep -cE '^ *flth_apt ' "$SETUP" | tr -d ' ')" 4 "ci-setup-linux.sh bounds all four of its apt-get calls"

finish ci-setup-apt
