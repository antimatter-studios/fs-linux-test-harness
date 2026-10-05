#!/usr/bin/env bash
#
# host-tools.sh — scripts/host-tools.sh on a macOS host, with `uname`,
# `brew` and `vagrant` stubbed so a Mac's answers can be given anywhere.
#
# What is pinned: the macOS box is published as a public GitHub release,
# and the Vagrantfile names it as the box's URL, so the first boot on a
# Mac fetches it. A Mac without it added is therefore ready (#8).
#
# And a virtiofsd older than the release that decodes an arm64 guest's
# open flags is refused, with the command that upgrades it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

BIN="$SANDBOX/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"
# `brew list --versions virtiofsd` answers from a file; every other brew
# query says the formula is installed.
cat > "$BIN/brew" <<STUB
#!/bin/sh
case "\$* " in
    "list --versions virtiofsd "*) cat "$SANDBOX/virtiofsd-versions" ;;
esac
exit 0
STUB
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
echo "virtiofsd 1.14.0" > "$SANDBOX/virtiofsd-versions"

printf '%s (qemu, 1.0.0, (arm64))\n' "$BOX" > "$SANDBOX/boxes"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 0 "a Mac with every tool and the box added is ready"
check_contains "$out" "all present (Darwin arm64)" "and says so"

printf 'cloud-image/debian-12 (qemu, 20260909.2596.0, (arm64))\n' > "$SANDBOX/boxes"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 0 "a Mac without the box added is ready: its first boot fetches it"
check_lacks "$out" "the box $BOX" "and is not told to add it by hand"

# virtiofsd before 1.14.0 read an arm64 guest's O_DIRECT as O_DIRECTORY.
printf '%s (qemu, 1.0.0, (arm64))\n' "$BOX" > "$SANDBOX/boxes"
for v in "1.13.8" "1.13.8-rc1" "1.9.0" "1.13.8 1.13.7" ""; do
    echo "virtiofsd $v" > "$SANDBOX/virtiofsd-versions"
    out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
    check_eq "$?" 1 "a Mac whose virtiofsd is '$v' is not ready"
    check_contains "$out" "missing: virtiofsd 1.14.0 or newer" "  naming the version it needs"
    check_contains "$out" "brew upgrade antimatter-studios/tap/virtiofsd" "  and the command that upgrades it"
done
for v in "1.14.0" "1.14.0.1" "1.14.0_1" "1.15.2" "2.0.0" "1.13.8 1.14.0"; do
    echo "virtiofsd $v" > "$SANDBOX/virtiofsd-versions"
    out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
    check_eq "$?" 0 "a Mac whose virtiofsd is '$v' is ready"
done

vagrantfile_box="$(sed -n 's/^ *config.vm.box = "\(christhomas\/[^"]*\)"$/\1/p' "$REPO/vagrant/Vagrantfile")"
check_eq "$vagrantfile_box" "$BOX" "the box checked for is the one the Vagrantfile boots on macOS"

finish host-tools
