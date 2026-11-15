#!/usr/bin/env bash
#
# A shared guest does not restart for one consumer's setup (#157). A setup that
# installs a kernel the guest is not running would leave that consumer's kernel
# tests on the wrong kernel while its join reported success. So the join fails,
# naming both kernels, and keeps failing on the next join, while other consumers'
# joins are not affected. On a later boot the same setup is refused before it runs
# (#207).
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

# Every boot runs each consumer's setup again, so on a new boot the same setup would
# spend its whole time installing the same kernel only to be refused after it (#207).
# The refusal is remembered for that setup's bytes: the next boot's join fails before
# the setup runs, naming the kernel and saying the setup was not run.
in_tree plain down >/dev/null 2>&1
rm -f "$BOOT/vmlinuz-6.12.57+deb13-arm64"
: > "$SETUP_LOG"
out="$(in_tree kernel up 2>&1)"
check_eq "$?" 1 "on the next boot, the same setup's join fails again"
check_contains "$out" "6.12.57+deb13-arm64" "naming the kernel that setup installed before"
check_contains "$out" "not run again" "and saying its setup was not run again"
check_lacks "$(cat "$SETUP_LOG")" "setup ran for kernel-one" "before that setup spends its time"
check_lacks "$out" "the setup script (setup.sh) failed" "and not calling it a failed setup"

# A changed setup may no longer install a kernel, so on a new boot it runs and its join
# is judged afresh.
in_tree plain down >/dev/null 2>&1
: > "$SETUP_LOG"
printf '#!/usr/bin/env bash\necho "setup ran for $FLTH_PROJECT" >> "${SETUP_LOG:-/dev/null}"\n' > "$SRC/kernel/setup.sh"
out="$(in_tree kernel up 2>&1)"
check_eq "$?" 0 "a changed setup that installs no kernel joins"
check_contains "$(cat "$SETUP_LOG")" "setup ran for kernel-one" "after its setup runs"

in_tree plain down >/dev/null 2>&1
finish shared-guest-kernel
