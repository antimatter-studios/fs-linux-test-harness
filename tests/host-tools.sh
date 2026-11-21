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
#
# And the virtiofsd the engine would start must be a port release with the
# hard-link fix (christhomas/virtiofsd#9, released in 1.14.0.1). Its --version
# prints upstream's 1.14.0 whether or not it has the fix, so the release is
# read from --port-version; a build without that flag predates it and is
# refused (#276).
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
    "plugin list")
        if [ -e "$SANDBOX/plugin-list-fails" ]; then
            cat "$SANDBOX/plugin-list-fails" >&2
            exit 3
        fi
        printf 'vagrant-qemu-christhomas (0.3.12, global)\n'; cat "$SANDBOX/forwarder-plugin" ;;
    "box list") cat "$SANDBOX/boxes" ;;
esac
exit 0
STUB
# virtiofsd prints upstream's version, and its port release from a file; with
# no file it is a build from before --port-version, and answers as clap does.
cat > "$BIN/virtiofsd" <<STUB
#!/bin/sh
case "\$1" in
    --version) echo "virtiofsd 1.14.0" ;;
    --port-version)
        if [ -e "$SANDBOX/virtiofsd-port-version" ]; then
            cat "$SANDBOX/virtiofsd-port-version"
        else
            echo "error: unexpected argument '--port-version' found" >&2
            exit 2
        fi ;;
esac
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
unset FLTH_VIRTIOFSD
echo 1.14.0.2 > "$SANDBOX/virtiofsd-port-version"
BOX=christhomas/vagrant-rpi-bookworm-arm64
echo "virtiofsd 1.14.0" > "$SANDBOX/virtiofsd-versions"
echo 'vagrant-notify-forwarder-christhomas (0.7.7, global)' > "$SANDBOX/forwarder-plugin"

printf '%s (qemu, 1.0.0, (arm64))\n' "$BOX" > "$SANDBOX/boxes"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 0 "a Mac with every tool and the box added is ready"
check_contains "$out" "all present (Darwin arm64)" "and says so"

printf 'cloud-image/debian-12 (qemu, 20260909.2596.0, (arm64))\n' > "$SANDBOX/boxes"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 0 "a Mac without the box added is ready: its first boot fetches it"
check_lacks "$out" "the box $BOX" "and is not told to add it by hand"

# The forwarder plugin before 0.7.7 leaves its watchers running after a halt, and
# they never end by themselves: 60 of them had piled up on one host (#164).
for v in 0.6.0 0.7.5 0.7.6; do
    echo "vagrant-notify-forwarder-christhomas ($v, global)" > "$SANDBOX/forwarder-plugin"
    out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
    check_eq "$?" 1 "a Mac whose forwarder plugin is $v is not ready"
    check_contains "$out" "missing: vagrant-notify-forwarder-christhomas 0.7.7 or newer (found '$v')" "  naming the version it needs"
    check_contains "$out" "vagrant plugin update vagrant-notify-forwarder-christhomas" "  and the command that upgrades it"
done
echo 'vagrant-notify-forwarder-christhomas (garbled)' > "$SANDBOX/forwarder-plugin"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a forwarder plugin whose version cannot be read is not ready"
check_contains "$out" "(found 'unreadable')" "  and it says so"
: > "$SANDBOX/forwarder-plugin"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a Mac with no forwarder plugin is not ready"
check_contains "$out" "vagrant plugin install vagrant-notify-forwarder-christhomas" "  and it is told to install it"
for v in 0.7.7 0.7.8 0.8.0 1.0.0; do
    echo "vagrant-notify-forwarder-christhomas ($v, global)" > "$SANDBOX/forwarder-plugin"
    bash "$REPO/scripts/host-tools.sh" >/dev/null 2>&1
    check_eq "$?" 0 "a Mac whose forwarder plugin is $v is ready"
done
echo 'vagrant-notify-forwarder-christhomas (0.7.7, global)' > "$SANDBOX/forwarder-plugin"

# A `vagrant plugin list` that fails says nothing about which plugins are there
# (#261): it is reported as itself, and nobody is told to install what they have.
echo 'vagrant: cannot allocate memory' > "$SANDBOX/plugin-list-fails"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a Mac whose 'vagrant plugin list' fails is not ready"
check_contains "$out" "'vagrant plugin list'" "  and the report names the command that failed"
check_contains "$out" "exit 3" "  with its status"
check_contains "$out" "vagrant: cannot allocate memory" "  and what it said"
check_lacks "$out" "missing: vagrant-qemu-christhomas" "  and does not call the provider plugin missing"
check_lacks "$out" "missing: vagrant-notify-forwarder-christhomas" "  or the forwarder plugin"
check_lacks "$out" "vagrant plugin install" "  or say to install either"
: > "$SANDBOX/plugin-list-fails"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a 'vagrant plugin list' that fails silently is not ready either"
check_contains "$out" "exit 3" "  and its status is still reported"
check_contains "$out" "printed nothing" "  and that it gave no reason"
rm -f "$SANDBOX/plugin-list-fails"

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

# The port release with the hard-link fix is 1.14.0.1, and --version cannot
# tell it from 1.14.0 (#276). A build that does not know --port-version is
# from before it, 1.14.0.1 included, and is refused.
echo "virtiofsd 1.14.0.1" > "$SANDBOX/virtiofsd-versions"
rm -f "$SANDBOX/virtiofsd-port-version"
out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a Mac whose virtiofsd has no --port-version is not ready"
check_contains "$out" "missing: virtiofsd port release 1.14.0.1 or newer" "  naming the release it needs"
check_contains "$out" "no --port-version" "  and that the build cannot name its release"
check_contains "$out" "at $BIN/virtiofsd" "  naming the virtiofsd it checked"
check_contains "$out" "brew upgrade antimatter-studios/tap/virtiofsd" "  and the command that upgrades it"
for v in "1.14.0" "1.13.8" "1.14" "garbled" ""; do
    echo "$v" > "$SANDBOX/virtiofsd-port-version"
    out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
    check_eq "$?" 1 "a Mac whose virtiofsd is port release '$v' is not ready"
    check_contains "$out" "missing: virtiofsd port release 1.14.0.1 or newer" "  naming the release it needs"
    check_contains "$out" "brew upgrade antimatter-studios/tap/virtiofsd" "  and the command that upgrades it"
done
for v in "1.14.0.1" "1.14.0.2" "1.14.1" "1.15.0.1" "2.0.0"; do
    echo "$v" > "$SANDBOX/virtiofsd-port-version"
    out="$(bash "$REPO/scripts/host-tools.sh" 2>&1)"
    check_eq "$?" 0 "a Mac whose virtiofsd is port release '$v' is ready"
done

# FLTH_VIRTIOFSD names the virtiofsd the engine starts, so it is the one checked.
mkdir -p "$SANDBOX/other"
printf '#!/bin/sh\n[ "$1" = --port-version ] && echo 1.14.0\nexit 0\n' > "$SANDBOX/other/virtiofsd"
chmod +x "$SANDBOX/other/virtiofsd"
echo 1.14.0.2 > "$SANDBOX/virtiofsd-port-version"
out="$(FLTH_VIRTIOFSD="$SANDBOX/other/virtiofsd" bash "$REPO/scripts/host-tools.sh" 2>&1)"
check_eq "$?" 1 "a Mac whose FLTH_VIRTIOFSD is an older port release is not ready"
check_contains "$out" "(found '1.14.0' at $SANDBOX/other/virtiofsd)" "  naming it, not the one on PATH"

vagrantfile_box="$(sed -n 's/^ *config.vm.box = "\(christhomas\/[^"]*\)"$/\1/p' "$REPO/vagrant/Vagrantfile")"
check_eq "$vagrantfile_box" "$BOX" "the box checked for is the one the Vagrantfile boots on macOS"

finish host-tools
