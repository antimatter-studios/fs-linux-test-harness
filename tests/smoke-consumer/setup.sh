#!/usr/bin/env bash
# Runs as root inside the VM (fs-linux-test-harness [setup] script).
# A consumer declares and installs the tooling its tests need; the
# harness bakes none in.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq e2fsprogs >/dev/null
# sed, not head: head exits after one line, mke2fs is killed by SIGPIPE
# writing its second, and pipefail fails the setup. It did, in the first
# real consumer's CI (rust-fs-ext4), with this exact line.
mkfs.ext4 -V 2>&1 | sed -n 1p
