#!/usr/bin/env bash
#
# ci-setup-linux.sh — make a hosted x86_64 Linux CI runner able to boot
# the VM: read-write /dev/kvm, QEMU, Vagrant from HashiCorp's apt
# repository, and the stock vagrant-qemu plugin, all pinned.
#
#   ci-setup-linux.sh                    set the runner up
#   ci-setup-linux.sh --box-cache-key    print the box cache key only; changes nothing
#
# The harness's own CI runs it (through .github/actions/install-vagrant-qemu)
# and so does every consumer's, from its sibling checkout:
#
#   - run: ../fs-linux-test-harness/scripts/ci-setup-linux.sh
#     id: vm-host
#   - uses: actions/cache@v4
#     with:
#       path: ~/.vagrant.d/boxes
#       key: ${{ steps.vm-host.outputs.box-cache-key }}
#
# One implementation, so a consumer cannot drift from the setup the
# harness proves in its own smoke job.
#
# Under GitHub Actions it writes `box-cache-key` to $GITHUB_OUTPUT: the
# box and version the Vagrantfile pins, and the guest architecture, so a
# cache is never restored for a different box.
#
# Environment (defaults are the pins the harness is tested with):
#   FLTH_VAGRANT_VERSION        2.4.9
#   FLTH_VAGRANT_QEMU_VERSION   0.6.3
#
# It uses sudo and apt-get and changes the machine: it is for disposable
# CI runners, not for a workstation (see README "Host setup").
set -euo pipefail

VAGRANT_VERSION="${FLTH_VAGRANT_VERSION:-2.4.9}"
VAGRANT_QEMU_VERSION="${FLTH_VAGRANT_QEMU_VERSION:-0.6.3}"
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# The box the Vagrantfile pins for Linux hosts, read from the Vagrantfile
# itself so a cache key cannot name a box the harness no longer boots.
box_cache_key() {
    local box box_version
    box="$(sed -n 's/^ *config\.vm\.box = "\(cloud-image[^"]*\)"$/\1/p' "$HARNESS/vagrant/Vagrantfile" | head -1)"
    box_version="$(sed -n 's/^ *config\.vm\.box_version = "\([^"]*\)"$/\1/p' "$HARNESS/vagrant/Vagrantfile" | head -1)"
    if [ -z "$box" ] || [ -z "$box_version" ]; then
        echo "ci-setup-linux: could not read the pinned Linux box from vagrant/Vagrantfile" >&2
        return 1
    fi
    echo "vagrant-box-${box//\//-}-${box_version}-amd64"
}

if [ "${1:-}" = --box-cache-key ]; then
    box_cache_key
    exit
fi

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo "ci-setup-linux: for x86_64 Linux CI runners; this is $(uname -s) $(uname -m)." >&2
    echo "                Other hosts: README 'Host setup'." >&2
    exit 1
fi

group() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::group::$1" || echo "== $1"; }
endgroup() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::endgroup::"; }

group "KVM access"
# The hosted image ships /dev/kvm as root:kvm 0660. The udev rule covers a
# later re-creation of the node; on the 2026-09 image the trigger did not
# change the existing node (and /etc/udev/rules did not exist), so the
# mode is also set directly. Checked afterwards rather than assumed.
if [ ! -e /dev/kvm ]; then
    echo "ci-setup-linux: this runner has no /dev/kvm; the VM needs KVM." >&2
    exit 1
fi
sudo mkdir -p /etc/udev/rules
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
    sudo tee /etc/udev/rules/99-kvm4all.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
sudo chmod 0666 /dev/kvm
ls -l /dev/kvm
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "ci-setup-linux: /dev/kvm is not read-write for $(id -un)" >&2
    exit 1
fi
endgroup

group "QEMU"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 qemu-utils >/dev/null
qemu-system-x86_64 --version | head -1
endgroup

group "Vagrant $VAGRANT_VERSION and vagrant-qemu $VAGRANT_QEMU_VERSION"
if ! vagrant --version 2>/dev/null | grep -qx "Vagrant $VAGRANT_VERSION"; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg |
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" |
        sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "vagrant=${VAGRANT_VERSION}-*" >/dev/null
fi
vagrant --version
if ! vagrant plugin list 2>/dev/null | grep -q "^vagrant-qemu ($VAGRANT_QEMU_VERSION"; then
    vagrant plugin install vagrant-qemu --plugin-version "$VAGRANT_QEMU_VERSION"
fi
vagrant plugin list
endgroup

key="$(box_cache_key)"
echo "box cache key: $key"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "box-cache-key=$key" >> "$GITHUB_OUTPUT"
fi
"$HARNESS/scripts/host-tools.sh"
