#!/usr/bin/env bash
# The smoke test discovers the release installed by its backports fixture, then
# pins that exact package for this separate profile's preparation boot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# shellcheck disable=SC1091
. /etc/os-release
printf 'deb http://deb.debian.org/debian %s-backports main\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/backports.list
apt-get update -qq
apt-get install -y -qq -t "${VERSION_CODENAME}-backports" "linux-image-$FLTH_KERNEL_RELEASE" >/dev/null
