#!/usr/bin/env bash
#
# host-tools.sh — scripts/host-tools.sh on a macOS host, with `uname`,
# `brew` and `vagrant` stubbed so a Mac's answers can be given anywhere.
#
# What is pinned: the macOS box is not in the public registry, so a Mac
# that lacks it locally must be told so, with the command that adds it,
# before a boot that would otherwise fail inside Vagrant.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

BIN="$SANDBOX/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"
printf '#!/bin/sh\nexit 0\n' > "$BIN/brew"
cat > "$BIN/vagrant" <<STUB
#!/bin/sh
case "\$1 \$2" in
    "--version "*) echo "Vagrant 2.4.9" ;;
    "plugin list") printf 'vagrant-qemu-christhomas (0.3.12, global)\nvagrant-notify-forwarder-christhomas (0.6.0, global)\n' ;;
    "box list") cat "$SANDBOX/boxes" ;;
esac
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
BOX=christhomas/vagrant-rpi-bookworm-arm64

printf '%s (qemu, 1.0.0, (arm64))\n' "$BOX" > "$SANDBOX/boxes"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 0 "a Mac with every tool and the box added is ready"
check_contains "$out" "all present (Darwin arm64)" "and says so"

printf 'cloud-image/debian-12 (qemu, 20260909.2596.0, (arm64))\n' > "$SANDBOX/boxes"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a Mac without the box is not ready"
check_contains "$out" "missing: the box $BOX" "naming the box"
check_contains "$out" "not in the public Vagrant registry" "saying why it has to be added by hand"
check_contains "$out" "vagrant box add $BOX https://github.com/christhomas/vagrant-rpi-bookworm-arm64/releases/download/" \
    "and the command that adds it"

printf '%s-old (qemu, 0.9.0, (arm64))\n' "$BOX" > "$SANDBOX/boxes"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a box whose name merely starts with the one needed is not it"

vagrantfile_box="$(sed -n 's/^ *config.vm.box = "\(christhomas\/[^"]*\)"$/\1/p' "$REPO/vagrant/Vagrantfile")"
check_eq "$vagrantfile_box" "$BOX" "the box checked for is the one the Vagrantfile boots on macOS"

finish host-tools
