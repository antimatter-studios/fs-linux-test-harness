# shellcheck shell=bash
# shellcheck disable=SC2034  # profile_active is read by smoke.sh's cleanup trap
# Sourced by smoke.sh. The guest's uname, module loader and boot id are the
# oracles; profile_release came from the earlier kernel-installation refusal.
step "run profiles: prepare the exact kernel before admitting suites"
if [ -z "$profile_release" ]; then
    bad "the kernel installation fixture must provide a release for the profile smoke test"
    return 1
fi
profile_catalog="$CONTENDER/run-profiles"
mkdir -p "$profile_catalog"
cp "$REPO/tests/smoke-profiles/prepare.sh" "$profile_catalog/prepare.sh"
profile_checksum="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$profile_catalog/prepare.sh")"
cat > "$profile_catalog/smoke.toml" <<EOF
[profile]
guest = "debian-12"
release = "$profile_release"
modules = "loop"
setup = "prepare.sh"
setup_sha256 = "$profile_checksum"
EOF
for profile_consumer in one two; do
    mkdir -p "$CONTENDER/profile-$profile_consumer"
    printf '[project]\nname = "profile-%s"\n[setup]\nscript = "setup.sh"\n[vm]\nprofile = "smoke"\n' "$profile_consumer" \
        > "$CONTENDER/profile-$profile_consumer/fs-linux-test-harness.toml"
    printf 'true\n' > "$CONTENDER/profile-$profile_consumer/setup.sh"
    printf '%s\n' "$profile_consumer" > "$CONTENDER/profile-$profile_consumer/name"
done
profile_active=1
if profile_vm one up; then
    ok "a profile prepares its persistent environment and boots disposable"
else
    bad "the run profile failed to prepare or boot"
    verdict
    exit 1
fi
check_eq "$(profile_vm one exec 'uname -r' 2>/dev/null)" "$profile_release" "the running kernel is the exact requested release"
profile_vm one exec 'modprobe loop && test -d /sys/module/loop'
check_eq "$?" 0 "the selected kernel loads its matching required module"
profile_boot="$(profile_vm one exec 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"
profile_vm two up
check_eq "$?" 0 "another suite joins the prepared profile"
check_eq "$(profile_vm two exec 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" "$profile_boot" "both suites use the same kernel VM"
check_eq "$(profile_vm one exec 'cat /repo/name' 2>/dev/null)" one "the first suite keeps its own hotplug tree"
check_eq "$(profile_vm two exec 'cat /repo/name' 2>/dev/null)" two "the second suite keeps its own hotplug tree"
profile_vm one exec 'echo disposable > /var/lib/profile-runtime-only'
profile_vm one down
check_eq "$?" 0 "the profile stops after its suites finish"
profile_vm one up
check_eq "$?" 0 "the prepared environment boots again without installing another kernel"
check_eq "$(profile_vm one exec 'uname -r' 2>/dev/null)" "$profile_release" "the next boot still runs the requested kernel"
profile_vm one exec 'test ! -e /var/lib/profile-runtime-only'
check_eq "$?" 0 "runtime writes never reach the prepared profile disk"
profile_vm one destroy
check_eq "$?" 0 "destroy removes the selected profile"
profile_active=0
