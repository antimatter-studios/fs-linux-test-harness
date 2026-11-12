#!/usr/bin/env bash
#
# A shared guest does not restart for one consumer's setup (#157). A setup that
# installs a kernel the guest is not running would leave that consumer's kernel
# tests on the wrong kernel while its join reported success. So the join fails,
# naming both kernels, and keeps failing on the next join, while other consumers'
# joins are not affected.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
export SETUP_LOG="$SANDBOX/setup.log"
BOOT="$FLTH_TEST_STUB/guest-boot"
mkdir -p "$BOOT" "$FLTH_TEST_STUB/guest-proc"
# The kernel the guest runs, as the guest says it.
cat > "$FLTH_TEST_STUB/bin/uname" <<'STUB'
#!/bin/sh
[ "${1:-}" = -r ] && { echo 6.1.0-42-cloud-arm64; exit 0; }
exec /usr/bin/uname "$@"
STUB
chmod +x "$FLTH_TEST_STUB/bin/uname"
: > "$BOOT/vmlinuz-6.1.0-42-cloud-arm64"

SRC="$(cd "$SANDBOX" && pwd -P)/src"
make_consumer "$SRC/kernel" kernel-one
make_consumer "$SRC/plain" plain-one
make_consumer "$SRC/same" same-one
cat >> "$SRC/kernel/setup.sh" <<'SETUP'
: > "$FLTH_TEST_STUB/guest-boot/vmlinuz-6.12.57+deb13-arm64"
SETUP
cat >> "$SRC/same/setup.sh" <<'SETUP'
: > "$FLTH_TEST_STUB/guest-boot/vmlinuz-6.1.0-42-cloud-arm64"
SETUP
in_tree() { local tree="$1"; shift; (cd "$SRC/$tree" && "$VM" "$@"); }

out="$(in_tree plain up 2>&1)"
check_eq "$?" 0 "a consumer whose setup installs no kernel joins"

out="$(in_tree kernel up 2>&1)"
check_eq "$?" 1 "a consumer whose setup installs a kernel the guest is not on fails its join"
check_contains "$out" "6.12.57+deb13-arm64" "naming the kernel its setup installed"
check_contains "$out" "6.1.0-42-cloud-arm64" "and the one the guest runs"
check_contains "$out" "a setup that installs a kernel cannot be run on it" "and saying why there is nowhere else to run it"
check_lacks "$out" "the setup script (setup.sh) failed" "and not calling it a failed setup"

out="$(in_tree kernel up 2>&1)"
check_eq "$?" 1 "a second join of that consumer fails the same way"
check_contains "$out" "6.12.57+deb13-arm64" "and names the kernel again"
out="$(in_tree kernel exec true 2>&1)"
check_eq "$?" 1 "a call of that consumer into the guest is refused too"

out="$(in_tree plain up 2>&1)"
check_eq "$?" 0 "another consumer still joins"
out="$(in_tree same up 2>&1)"
check_eq "$?" 0 "and so does one whose setup reinstalls the running kernel"

in_tree plain down >/dev/null 2>&1
finish shared-guest-kernel
