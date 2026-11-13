#!/usr/bin/env bash
# Profiles are resolved before engine state is touched; only a stopped, verified
# preparation is cached, and runtime boots keep the existing disposable contract.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
PARSER="$REPO/scripts/run-profile.rb"
SRC="$SANDBOX/consumer"
make_consumer "$SRC" profile-one '[vm]' 'profile = "pinned"'
export FLTH_CONFIG="$SRC/fs-linux-test-harness.toml"
export FLTH_PROFILE_DIR="$SANDBOX/profiles"
mkdir -p "$FLTH_PROFILE_DIR"
RELEASE=6.12.1-profile-test
cat > "$FLTH_PROFILE_DIR/prepare.sh" <<'SETUP'
set -euo pipefail
[ "$FLTH_GUEST" = 1 ]
[ "$FLTH_KERNEL_RELEASE" = 6.12.1-profile-test ]
printf prepared > "$FLTH_TEST_STUB/guest-lib/profile-setup"
SETUP
checksum="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$FLTH_PROFILE_DIR/prepare.sh")"
manifest() {
    cat <<EOF
[profile]
guest = "debian-12"
release = "$RELEASE"
modules = "loop"
setup = "prepare.sh"
setup_sha256 = "$checksum"
EOF
}
manifest > "$FLTH_PROFILE_DIR/pinned.toml"
cp "$FLTH_PROFILE_DIR/pinned.toml" "$FLTH_PROFILE_DIR/alias.toml"
config="$("$VM" config 2>&1)"; rc=$?
check_eq "$rc" 0 "a consumer selects a run profile"
[ "$rc" = 0 ] || finish run-profiles
check_contains "$config" "vm.profile=pinned" "config names the selected profile"
check_contains "$config" "kernel.release=$RELEASE" "config names its exact kernel release"
machine="$(printf '%s\n' "$config" | sed -n 's/^machine=//p')"
other="$(FLTH_PROFILE="alias" "$VM" config | sed -n 's/^machine=//p')"
check_eq "$other" "$machine" "identical profile aliases share one machine"
make_consumer "$SANDBOX/second" profile-two '[vm]' 'profile = "pinned"'
second_config="$SANDBOX/second/fs-linux-test-harness.toml"
other="$(FLTH_CONFIG="$second_config" "$VM" config | sed -n 's/^machine=//p')"
check_eq "$other" "$machine" "unrelated consumer repositories share an identical profile"
check_eq "$(grep -c '^up' "$FLTH_TEST_STUB/calls" | tr -d ' ')" 0 "resolving profiles boots nothing"
before="$(cat "$FLTH_TEST_STUB/calls")"
out="$("$VM" up-boot boot "$$" another-profile-machine 2>&1)"
check_eq "$?" 1 "a boot child cannot switch away from the profile whose lock its parent took"
check_contains "$out" 'changed while taking the boot lock' "a concurrently changed profile asks for a retry"
check_eq "$(cat "$FLTH_TEST_STUB/calls")" "$before" "a profile changed between parent and child touches no engine state"

# Architecture selection and canonical identity do not depend on catalog paths.
cat > "$FLTH_PROFILE_DIR/arches.toml" <<'PROFILE'
[profile]
guest = "debian-13"
modules = "loop fuse loop"
[x86_64]
release = "6.12.1-amd64"
[aarch64]
release = "6.12.1-arm64"
PROFILE
out="$(ruby "$PARSER" resolve "$FLTH_PROFILE_DIR/arches.toml" x86_64)"
check_contains "$out" '6.12.1-amd64' "an x86_64 suite resolves its architecture's release"
check_contains "$out" 'fuse loop' "module ordering and duplicates are canonicalized"
arm="$(ruby "$PARSER" resolve "$FLTH_PROFILE_DIR/arches.toml" aarch64)"
check_contains "$arm" '6.12.1-arm64' "an aarch64 suite resolves its architecture's release"
check_eq "$([ "$arm" != "$out" ] && echo distinct)" distinct "different architectures have different identities"
other="$(FLTH_PROFILE=arches "$VM" config)"
check_contains "$other" 'vm.guest=debian-13' "the profile selects its pinned base guest"
check_lacks "$other" "machine=$machine" "a different profile gets a different machine"

reject() {
    printf '%s\n' "$1" > "$FLTH_PROFILE_DIR/bad.toml"
    local out rc
    out="$(FLTH_PROFILE=bad "$VM" config 2>&1)"; rc=$?
    check_eq "$rc" 1 "$3 fails before boot"
    check_contains "$out" "$2" "and diagnoses $3"
}
reject '[profile]
release = "6.12"
relese = "typo"' 'unknown key' 'an unknown profile key'
reject '[profile]
release = "6.12"
release = "6.13"' 'duplicate key' 'a duplicate profile key'
reject '[profile]
release = "6.12"
[profile]' 'duplicate section' 'a duplicate section'
reject '[profile]
release = "6.12;false"' 'exact kernel release' 'a shell expression in a release'
reject '[profile]
release = "6.12"
modules = "../module"' 'invalid module' 'a module path'
reject '[profile]
release = "6.12"
setup = "../prepare.sh"' 'relative path inside' 'a preparation path leaving its catalog'
reject '[profile]
release = "6.12"
setup = "prepare.sh"
setup_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' 'setup_sha256 mismatch' 'a changed preparation script'
reject '[profile]
release = "6.12"
setup = "prepare.sh"' 'setup_sha256 must' 'an unpinned preparation script'
case "$(uname -m)" in arm64 | aarch64) other_arch=x86_64 ;; *) other_arch=aarch64 ;; esac
reject "[profile]
[$other_arch]
release = \"6.12\"" 'exact kernel release' 'a missing architecture release'
reject '[profile]
release = ""' 'exact kernel release' 'an explicitly empty kernel release'
reject '[profile]
release = 612' 'quoted string' 'a wrongly typed value'
out="$(FLTH_PROFILE=../pinned "$VM" config 2>&1)"
check_eq "$?" 1 "a profile name cannot escape the catalog"
check_eq "$(grep -c '^up' "$FLTH_TEST_STUB/calls" | tr -d ' ')" 0 "invalid profiles never boot or provision a guest"
printf '# changed preparation\n' >> "$FLTH_PROFILE_DIR/prepare.sh"
changed_checksum="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$FLTH_PROFILE_DIR/prepare.sh")"
manifest | sed "s/$checksum/$changed_checksum/" > "$FLTH_PROFILE_DIR/changed.toml"
other="$(FLTH_PROFILE=changed "$VM" config | sed -n 's/^machine=//p')"
check_eq "$([ "$other" != "$machine" ] && echo separate)" separate "changed preparation bytes allocate a different machine"
# Restore the original fixture; the already resolved identity remains the same.
sed '$d' "$FLTH_PROFILE_DIR/prepare.sh" > "$SANDBOX/prepare-original"
cp "$SANDBOX/prepare-original" "$FLTH_PROFILE_DIR/prepare.sh"

# Everything run by the stub engine stays inside its sandbox, including modules.
mkdir -p "$FLTH_TEST_STUB/guest-boot" "$FLTH_TEST_STUB/guest-proc" "$FLTH_TEST_STUB/guest-modules/$RELEASE"
printf kernel > "$FLTH_TEST_STUB/guest-boot/vmlinuz-$RELEASE"
printf initrd > "$FLTH_TEST_STUB/guest-boot/initrd.img-$RELEASE"
printf 'BOOT_IMAGE=/boot/old root=UUID=profile-root ro console=ttyS0 initrd=old\n' > "$FLTH_TEST_STUB/guest-proc/cmdline"
printf '%s\n' "$RELEASE" > "$FLTH_TEST_STUB/runtime-release"
cat > "$FLTH_TEST_STUB/bin/uname" <<'STUB'
#!/bin/sh
[ "${1:-}" != -r ] || { cat "$FLTH_TEST_STUB/runtime-release"; exit; }
exec /usr/bin/uname "$@"
STUB
cat > "$FLTH_TEST_STUB/bin/modprobe" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FLTH_TEST_STUB/module-calls"
[ ! -f "$FLTH_TEST_STUB/module-fails" ]
STUB
chmod +x "$FLTH_TEST_STUB/bin/uname" "$FLTH_TEST_STUB/bin/modprobe"
cat > "$FLTH_TEST_STUB/bin/cat" <<'STUB'
#!/bin/sh
/bin/cat "$@" || exit
case "${1:-}" in
    */guest-boot/vmlinuz-*) [ ! -f "$FLTH_TEST_STUB/corrupt-transfer" ] || printf corrupt ;;
esac
exit 0
STUB
chmod +x "$FLTH_TEST_STUB/bin/cat"
cat >> "$SRC/setup.sh" <<'SETUP'
printf disposable > "$FLTH_TEST_STUB/guest-lib/consumer-write"
SETUP
out="$("$VM" up 2>&1)"
rc=$?
check_eq "$rc" 0 "the profile prepares and boots before its consumer joins"
[ "$rc" = 0 ] || printf '%s\n' "$out" >&2
check_eq "$(grep -c '^up --persist$' "$FLTH_TEST_STUB/calls" | tr -d ' ')" 1 "profile preparation has one persistent boot"
check_eq "$(grep -c '^up$' "$FLTH_TEST_STUB/calls" | tr -d ' ')" 1 "consumer execution has one disposable boot"
check_eq "$(cat "$FLTH_TEST_STUB/disk/profile-setup" 2>/dev/null)" prepared "the prepared environment is kept on disk"
check_eq "$([ -f "$FLTH_TEST_STUB/disk/consumer-write" ] && echo leaked)" '' "the consumer cannot provision the profile disk"
check_contains "$(cat "$FLTH_TEST_STUB/module-calls")" "--set-version $RELEASE --show-depends loop" "preparation resolves modules for the selected release"
check_contains "$(cat "$FLTH_TEST_STUB/module-calls")" $'\nloop' "the running guest loads the required module"
check_eq "$(cat "$machine/boot/release" 2>/dev/null)" "$RELEASE" "the exact kernel is exported for the next boot"
check_eq "$(cat "$machine/boot/cmdline" 2>/dev/null)" 'root=UUID=profile-root ro console=ttyS0' "direct boot keeps the root and console, dropping bootloader paths"
check_eq "$([ -s "$machine/profile-ready" ] && echo ready)" ready "only a stopped preparation produces a ready record"
FLTH_PROFILE="alias" "$VM" up >/dev/null 2>&1
check_eq "$?" 0 "another suite naming the same profile joins the running guest"
FLTH_CONFIG="$second_config" "$VM" up >/dev/null 2>&1
check_eq "$?" 0 "another consumer joins that same prepared guest"
check_eq "$(grep -c '^up$' "$FLTH_TEST_STUB/calls" | tr -d ' ')" 1 "sharing does not boot another guest"
"$VM" down >/dev/null 2>&1
"$VM" up >/dev/null 2>&1
check_eq "$?" 0 "a prepared profile boots again"
check_eq "$(grep -c '^up --persist$' "$FLTH_TEST_STUB/calls" | tr -d ' ')" 1 "a later boot reuses the verified preparation"
check_eq "$([ -f "$FLTH_TEST_STUB/disk/consumer-write" ] && echo leaked)" '' "runtime writes still never enter the prepared disk"
"$VM" down >/dev/null 2>&1

printf tampered >> "$machine/boot/vmlinuz"
out="$("$VM" up 2>&1)"
check_eq "$?" 1 "corrupted cached kernel bytes are refused"
check_contains "$out" 'profile boot artifacts changed' "the refusal tells how to rebuild the profile"
"$VM" destroy >/dev/null 2>&1
check_eq "$([ -f "$machine/profile-ready" ] && echo stale)" '' "destroy invalidates the preparation record"

printf wrong-kernel > "$FLTH_TEST_STUB/runtime-release"
out="$("$VM" up 2>&1)"
check_eq "$?" 1 "a running kernel that differs from the profile refuses its consumer"
check_contains "$out" 'guest runs wrong-kernel' "the refusal names the kernel actually running"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "a wrong kernel is stopped before any consumer can join"
printf '%s\n' "$RELEASE" > "$FLTH_TEST_STUB/runtime-release"
: > "$FLTH_TEST_STUB/module-fails"
out="$("$VM" up 2>&1)"
check_eq "$?" 1 "an unloadable required module refuses consumer admission"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "the failed module boot is stopped"
rm -f "$FLTH_TEST_STUB/module-fails"
"$VM" destroy >/dev/null 2>&1
rm -f "$FLTH_TEST_STUB/guest-boot/initrd.img-$RELEASE"
out="$("$VM" up 2>&1)"
check_eq "$?" 1 "an incomplete installed kernel fails preparation"
check_contains "$out" 'missing kernel, initrd or matching modules' "the missing artifact is diagnosed"
check_eq "$([ -f "$machine/profile-ready" ] && echo false-ready)" '' "failed preparation is never cached"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "failed preparation leaves no running bootstrap guest"
printf initrd > "$FLTH_TEST_STUB/guest-boot/initrd.img-$RELEASE"
"$VM" up >/dev/null 2>&1
check_eq "$?" 0 "an interrupted or failed preparation is rebuilt on retry"
"$VM" destroy >/dev/null 2>&1
: > "$FLTH_TEST_STUB/module-fails"
out="$("$VM" up 2>&1)"
check_eq "$?" 1 "missing dependencies fail profile preparation"
check_contains "$out" 'cannot resolve module loop' "preparation names the required module it cannot resolve"
check_eq "$([ -f "$machine/profile-ready" ] && echo false-ready)" '' "failed dependency resolution is never cached"
rm -f "$FLTH_TEST_STUB/module-fails"
printf running > "$FLTH_TEST_STUB/after_down"
printf stopped > "$FLTH_TEST_STUB/after_force_down"
out="$("$VM" up 2>&1)"
check_eq "$?" 1 "a preparation that needs a forced shutdown is not certified"
check_eq "$([ -f "$machine/profile-ready" ] && echo false-ready)" '' "an unconfirmed graceful shutdown never caches a profile"
check_eq "$(cat "$FLTH_TEST_STUB/state")" stopped "the failed preparation's guest is forced down"
rm -f "$FLTH_TEST_STUB/after_down" "$FLTH_TEST_STUB/after_force_down"
"$VM" destroy >/dev/null 2>&1
: > "$FLTH_TEST_STUB/corrupt-transfer"
out="$("$VM" up 2>&1)"
check_eq "$?" 1 "corrupted bytes received over SSH fail preparation"
check_contains "$out" 'transfer checksum mismatch for vmlinuz' "the guest's independent digest detects transfer corruption"
check_eq "$([ -f "$machine/profile-ready" ] && echo false-ready)" '' "corrupted transferred boot files are never certified"
rm -f "$FLTH_TEST_STUB/corrupt-transfer"
"$VM" destroy >/dev/null 2>&1
# A profile may isolate preparation alone and retain the pinned box's kernel.
cat > "$FLTH_PROFILE_DIR/tools.sh" <<'SETUP'
set -eu
[ -z "$FLTH_KERNEL_RELEASE" ]
printf one > "$FLTH_TEST_STUB/guest-lib/run-flavor"
SETUP
tools_checksum="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$FLTH_PROFILE_DIR/tools.sh")"
printf '[profile]\nsetup = "tools.sh"\nsetup_sha256 = "%s"\n' "$tools_checksum" > "$FLTH_PROFILE_DIR/tools.toml"
config="$(FLTH_PROFILE=tools "$VM" config)"
check_eq "$?" 0 "a run profile can omit every kernel override"
check_contains "$config" 'kernel.release=box-default' "an omitted release keeps the box kernel"
tools_machine="$(printf '%s\n' "$config" | sed -n 's/^machine=//p')"
mkdir -p "$SRC/run-profiles"
cp "$FLTH_PROFILE_DIR/tools.toml" "$FLTH_PROFILE_DIR/tools.sh" "$SRC/run-profiles/"
default_config="$(unset FLTH_PROFILE_DIR; FLTH_PROFILE=tools "$VM" config)"
check_eq "$?" 0 "run-profiles is the consumer's default catalog directory"
check_contains "$default_config" "machine=$tools_machine" "moving the catalog preserves its resolved identity"
printf 'printf two > "$FLTH_TEST_STUB/guest-lib/run-flavor"\n' > "$FLTH_PROFILE_DIR/other-tools.sh"
other_checksum="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$FLTH_PROFILE_DIR/other-tools.sh")"
printf '[profile]\nsetup = "other-tools.sh"\nsetup_sha256 = "%s"\n' "$other_checksum" > "$FLTH_PROFILE_DIR/other-tools.toml"
other_machine="$(FLTH_PROFILE=other-tools "$VM" config | sed -n 's/^machine=//p')"
check_eq "$([ "$tools_machine" != "$other_machine" ] && echo separate)" separate "different preparation gets separate VMs with the same box kernel"
out="$(FLTH_PROFILE=tools "$VM" up 2>&1)"
check_eq "$?" 0 "a preparation-only profile boots without exported kernel files"
check_eq "$(cat "$FLTH_TEST_STUB/disk/run-flavor" 2>/dev/null)" one "the profile's environment persists on its own prepared disk"
check_eq "$(cat "$tools_machine/boot/guest-release" 2>/dev/null)" "$RELEASE" "the box kernel's running release is recorded for admission"
check_eq "$([ -s "$tools_machine/boot/release" ] && echo override)" '' "the engine receives no kernel override for a preparation-only profile"
check_eq "$([ -e "$tools_machine/boot/vmlinuz" ] && echo exported)" '' "the box profile needs no kernel artifact on its guest disk"
FLTH_PROFILE=tools "$VM" down >/dev/null 2>&1
printf wrong-box-kernel > "$FLTH_TEST_STUB/runtime-release"
out="$(FLTH_PROFILE=tools "$VM" up 2>&1)"
check_eq "$?" 1 "a preparation-only profile still checks its recorded kernel at runtime"
check_contains "$out" 'guest runs wrong-box-kernel' "a changed box kernel is diagnosed before admission"
printf '%s\n' "$RELEASE" > "$FLTH_TEST_STUB/runtime-release"
FLTH_PROFILE=tools "$VM" up >/dev/null 2>&1
check_eq "$?" 0 "a prepared environment boots again with its original box kernel"
check_eq "$(cat "$FLTH_TEST_STUB/guest-lib/run-flavor" 2>/dev/null)" one "the preparation survives its disposable runtime reboot"
FLTH_PROFILE=tools "$VM" down >/dev/null 2>&1
printf changed > "$tools_machine/boot/guest-release"
out="$(FLTH_PROFILE=tools "$VM" up 2>&1)"
check_eq "$?" 1 "the default kernel's admission record is integrity checked"
check_contains "$out" 'profile boot artifacts changed' "a damaged default-kernel record asks for a rebuild"
FLTH_PROFILE=tools "$VM" destroy >/dev/null 2>&1
finish run-profiles
