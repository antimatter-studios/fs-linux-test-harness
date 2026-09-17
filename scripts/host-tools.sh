#!/usr/bin/env bash
#
# host-tools.sh — check this host can run the test VM, and say exactly
# what to install when it cannot.
#
#   host-tools.sh           report every requirement, exit 1 if any is missing
#   host-tools.sh --quiet   print nothing when all is present
#
# It installs nothing. What it prints is the command that fixes each gap
# (a Homebrew formula on macOS, a Debian package on Linux), so a new
# machine learns what it needs from the harness rather than from an
# engine error.
#
# The guest architecture is the host's: arm64 guests on Apple Silicon
# and arm64 Linux, x86_64 guests on x86_64 Linux. Hardware acceleration
# is REQUIRED — a VM silently emulated in software is a test run that
# takes an hour and times out somewhere unhelpful.
set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

missing=0
report=()

need() {
    # need <what> <why> <install>
    report+=("  missing: $1")
    report+=("           $2")
    report+=("           install: $3")
    missing=$((missing + 1))
}

have() { command -v "$1" >/dev/null 2>&1; }

check_vagrant() {
    local install="$1" version
    if ! have vagrant; then
        need "vagrant (2.4 or newer)" "drives the VM" "$install"
        return
    fi
    version="$(vagrant --version 2>/dev/null | awk '{print $2}')"
    if ! printf '%s\n' "$version" | awk -F. '$1 > 2 || ($1 == 2 && $2 >= 4) { ok = 1 } END { exit !ok }'; then
        need "vagrant 2.4 or newer (found '${version:-unreadable}')" "older releases are untested with the QEMU provider" "$install"
    fi
}

check_macos() {
    if [ "$(uname -m)" != arm64 ]; then
        need "an Apple Silicon Mac" "the macOS path runs arm64 guests under HVF" "(not installable)"
        return
    fi
    if ! have brew; then
        need "homebrew" "installs the hypervisor and the sharing daemon" "see https://brew.sh"
        return
    fi
    check_vagrant "brew install --cask hashicorp/tap/hashicorp-vagrant"
    local f
    for f in qemu virtiofsd; do
        # `brew list`, not `command -v`: a stock qemu satisfies PATH while
        # lacking the patches this path depends on.
        brew list --formula "$f" >/dev/null 2>&1 ||
            need "$f (antimatter-studios tap)" "the macOS VM needs the tap's build" "brew install antimatter-studios/tap/$f"
    done
    if have vagrant; then
        local p plugins
        plugins="$(vagrant plugin list 2>/dev/null || true)"
        for p in vagrant-qemu-christhomas vagrant-notify-forwarder-christhomas; do
            printf '%s\n' "$plugins" | grep -q "^$p " ||
                need "$p" "the macOS QEMU provider and its required companion" "vagrant plugin install $p"
        done
    fi
}

check_linux() {
    local arch qemu pkg kvm="/dev/kvm"
    arch="$(uname -m)"
    case "$arch" in
        aarch64 | arm64) qemu="qemu-system-aarch64"; pkg="qemu-system-arm" ;;
        x86_64) qemu="qemu-system-x86_64"; pkg="qemu-system-x86" ;;
        *) need "a supported CPU (aarch64 or x86_64, found $arch)" "guests run at the host's architecture" "(not installable)"; return ;;
    esac
    check_vagrant "HashiCorp's apt repository (x86_64), or Vagrant 2.4.x from source on arm64 — see README 'Host setup'"
    have "$qemu" || need "$qemu" "the hypervisor" "apt-get install $pkg"
    have qemu-img || need "qemu-img" "creates the VM's disk overlay" "apt-get install qemu-utils"
    if [ ! -e "$kvm" ]; then
        need "$kvm" "hardware acceleration; software emulation is refused" "enable KVM for this host (kvm module / nested virtualisation)"
    elif [ ! -r "$kvm" ] || [ ! -w "$kvm" ]; then
        need "read-write access to $kvm" "hardware acceleration; software emulation is refused" "add $(id -un) to the kvm group, then log in again"
    fi
    if [ "$qemu" = qemu-system-aarch64 ]; then
        local f
        for f in "${FLTH_FIRMWARE_CODE:-/usr/share/AAVMF/AAVMF_CODE.fd}" "${FLTH_FIRMWARE_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}"; do
            [ -r "$f" ] || need "$f" "UEFI firmware for the arm64 guest (FLTH_FIRMWARE_CODE / FLTH_FIRMWARE_VARS override the paths)" "apt-get install qemu-efi-aarch64"
        done
    fi
    # The stock vagrant-qemu plugin is checked by the Vagrantfile itself,
    # which can see a plugin loaded through a bundler Gemfile as well as
    # one from `vagrant plugin install`; `vagrant plugin list` cannot.
}

case "$(uname -s)" in
    Darwin) check_macos ;;
    Linux) check_linux ;;
    *) need "macOS or Linux (found $(uname -s))" "the only hosts this harness drives" "(not installable)" ;;
esac

if [ "$missing" -eq 0 ]; then
    [ "$QUIET" = 1 ] || echo "host tools: all present ($(uname -s) $(uname -m))"
    exit 0
fi
echo "host tools: $missing requirement(s) missing on $(uname -s) $(uname -m):" >&2
printf '%s\n' "${report[@]}" >&2
exit 1
