#!/usr/bin/env bash
# Runs as root inside the VM (fs-linux-test-harness [setup] script).
# A consumer declares and installs the tooling its tests need; the
# harness bakes none in.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq e2fsprogs >/dev/null
mkfs.ext4 -V 2>&1 | head -1
