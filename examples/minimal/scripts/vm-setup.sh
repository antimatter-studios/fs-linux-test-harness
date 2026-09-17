#!/usr/bin/env bash
# Runs as root inside the test VM. Declare and install exactly the tooling
# this repository's tests need; the harness bakes none in.
#
# Tests never skip because a tool is missing: if a test needs it, it is
# installed here, and the VM is how the host gets it.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq myfs-progs   # replace with your filesystem's tools
modprobe myfs                       # and load its kernel module, if the tests mount
