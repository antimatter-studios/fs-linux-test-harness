#!/usr/bin/env bash
# Runs as root inside the VM. Installs the generic kernel from the guest
# release's backports, which is newer than the kernel the guest boots, and
# reboots nothing: the harness stops this boot and starts the next.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# shellcheck disable=SC1091  # the guest's, not in this repository
. /etc/os-release
echo "deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main" \
    >/etc/apt/sources.list.d/backports.list
apt-get update -qq
apt-get install -y -qq -t "${VERSION_CODENAME}-backports" "linux-image-$(dpkg --print-architecture)" >/dev/null
