#!/usr/bin/env bash
#
# generic.sh — the contract, checked: the harness contains nothing
# filesystem-specific, and the pieces that must agree do.
#
# Filesystem knowledge belongs to the consumer. The only places in this
# repository allowed to name a filesystem or its tools are the consumer
# fixtures (tests/smoke-consumer, examples/), the tests, and the prose.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATHS="scripts vagrant vm.chores.yml chores.yml"
FS_WORDS='xfs|btrfs|ext[234]|e2fs|mkfs|mke2fs|fsck|ntfs|erofs|squashfs|zfs|f2fs|exfat|vfat|debugfs|dumpe2fs|fsstress|fstests'
# shellcheck disable=SC2086  # the path list splits into words
hits="$(cd "$REPO" && grep -rniE "(^|[^a-z0-9])($FS_WORDS)([^a-z0-9]|$)" $PATHS 2>/dev/null)"
check_eq "$hits" "" "scripts/, vagrant/ and the chore files name no filesystem or its tooling"

# A LANGUAGE IS AS SPECIFIC AS A FILESYSTEM. `guest-test` runs a
# consumer's suite inside the guest, and the temptation is to teach the
# harness how that consumer builds — a toolchain to install, a build
# directory to set, a package manager to call. It knows none of it: the
# consumer's [setup] script prepares the guest and [test] guest_command
# says what to run.
#
# Ruby's own words are not on the list: Vagrant is written in it, and
# host-tools.sh has to talk about the bundler a Vagrant-from-source
# install uses. That is the ENGINE's language, not a consumer's.
TOOLCHAIN_WORDS='cargo|rustup|rustc|crates\.io|npm|yarn|pnpm|node_modules|pip|pipenv|poetry|virtualenv|gradle|maven|dotnet|golang|go\.mod|composer|meson|cmake'
# shellcheck disable=SC2086
hits="$(cd "$REPO" && grep -rniE "(^|[^a-z0-9])($TOOLCHAIN_WORDS)([^a-z0-9]|$)" $PATHS 2>/dev/null)"
check_eq "$hits" "" "and no language, toolchain or package manager either"

hits="$(cd "$REPO" && grep -rnE 'apt-get|apt |dnf |yum |apk ' vagrant 2>/dev/null)"
check_eq "$hits" "" "the VM definition installs no packages in the guest"

marker_common="$(sed -n 's/^FLTH_GUEST_HOLD_MARKER="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
marker_guest="$(sed -n 's/^HOLD=\(.*\)$/\1/p' "$REPO/vagrant/guest/deadline.sh")"
check_eq "$marker_guest" "$marker_common" "vm.sh hold and the guest deadline agree on the hold marker"
check_eq "$(grep -c "$marker_common" "$REPO/tests/stubs/engine.sh" | tr -d ' ')" 1 "and the stub engine redirects that same marker"

stamp="$(grep -o '/var/lib/fs-linux-test-harness' "$REPO/scripts/vm.sh" | head -1)"
check_eq "$(grep -c "$stamp" "$REPO/tests/stubs/engine.sh" | tr -d ' ')" 1 "the stub engine redirects the guest setup stamp vm.sh writes"

share_guest="$(sed -n 's/^FLTH_SHARE_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
check_eq "$(grep -c "share_guest = \"$share_guest\"" "$REPO/vagrant/Vagrantfile" | tr -d ' ')" 1 "the Vagrantfile mounts the share where vm.sh says it is"

repo_guest="$(sed -n 's/^FLTH_REPO_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
check_eq "$(grep -c "repo_guest = \"$repo_guest\"" "$REPO/vagrant/Vagrantfile" | tr -d ' ')" 1 "and mounts the consumer repository where guest-test says it is"
check_eq "$(grep -c "s|$repo_guest|" "$REPO/tests/stubs/engine.sh" | tr -d ' ')" 1 "and the stub engine redirects that mount too"

# Every public vm.sh command has a chore task, and every task's script exists.
commands="$(sed -n 's/^#   vm\.sh \([a-z-]*\).*/\1/p' "$REPO/scripts/vm.sh")"
for c in $commands; do
    if grep -q "scripts/vm.sh\" $c\b" "$REPO/vm.chores.yml"; then
        ok "vm.sh $c is exposed as a chore task"
    else
        bad "vm.sh $c has no task in vm.chores.yml"
    fi
done
grep -ho 'scripts/[a-z-]*\.sh\|tests/[a-z-]*\.sh' "$REPO/vm.chores.yml" "$REPO/chores.yml" | sort -u |
    while IFS= read -r s; do
        if [ -x "$REPO/$s" ]; then
            echo "ok    $s, named by a chore task, exists and is executable"
        else
            echo "FAIL  $s is named by a chore task but missing or not executable"
        fi
    done > "$(dirname "$0")/.generic-scripts.out"
while IFS= read -r line; do
    case "$line" in ok*) ok "${line#ok    }" ;; *) bad "${line#FAIL  }" ;; esac
done < "$(dirname "$0")/.generic-scripts.out"
rm -f "$(dirname "$0")/.generic-scripts.out"

# The CI box cache key is derived from the Vagrantfile's pin, so a box
# bump re-keys the cache rather than restoring the old box under a new pin.
box_version="$(sed -n 's/^ *config\.vm\.box_version = "\([^"]*\)"$/\1/p' "$REPO/vagrant/Vagrantfile")"
check_eq "$("$REPO/scripts/ci-setup-linux.sh" --box-cache-key)" \
    "vagrant-box-cloud-image-debian-12-$box_version-amd64" \
    "ci-setup-linux.sh keys the box cache on the box and version the Vagrantfile pins"
check_eq "$(grep -c 'scripts/ci-setup-linux.sh' "$REPO/.github/workflows/ci.yml" | tr -d ' ')" 1 \
    "the harness's own smoke job sets its runner up with the script consumers use"

finish generic
