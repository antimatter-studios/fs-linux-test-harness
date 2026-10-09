#!/usr/bin/env bash
#
# vagrantfile.sh — vagrant/Vagrantfile evaluated under a recording stand-in
# for Vagrant's DSL, once per supported host.
#
# Nothing boots. What is pinned: each host gets its own box, accelerator,
# provider plugins and sharing mechanism; the Linux and macOS paths do not
# bleed into each other; and every FLTH_* value is validated before it
# reaches a QEMU command line or a root shell in the guest.
#
# Needs ruby. It does not skip without it: a test that quietly does not
# run reads exactly like one that passed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

if ! command -v ruby >/dev/null 2>&1; then
    bad "ruby is required to evaluate the Vagrantfile (apt-get install ruby / brew install ruby)"
    finish vagrantfile
fi

mkdir -p "$SANDBOX/share" "$SANDBOX/fw"
: > "$SANDBOX/fw/edk2-aarch64-code.fd"; : > "$SANDBOX/fw/edk2-arm-vars.fd"
: > "$SANDBOX/kvm"

cat > "$SANDBOX/eval.rb" <<'RUBY'
require "json"
require "rbconfig"

host_os, host_cpu, kvm_ok, plugins, vagrantfile = ARGV
RbConfig::CONFIG["host_os"] = host_os
RbConfig::CONFIG["host_cpu"] = host_cpu
PLUGINS = plugins.split(",")

class File
  class << self
    %i[exist? readable? writable?].each do |m|
      orig = instance_method(m) rescue method(m).unbind
      define_method(m) do |path|
        return ENV["FLTH_TEST_KVM"] == "1" if path == "/dev/kvm"
        orig.bind(self).call(path)
      end
    end
    # Every virtiofsd binary a Mac could have lying about exists here, so
    # the Vagrantfile is seen choosing between them.
    orig_exec = instance_method(:executable?)
    define_method(:executable?) do |path|
      return true if File.basename(path.to_s).start_with?("virtiofsd")
      orig_exec.bind(self).call(path)
    end
  end
end

class Recorder
  attr_reader :data
  def initialize(data, prefix) ; @data = data ; @prefix = prefix ; end
  def method_missing(name, *args, **kw, &block)
    key = @prefix + name.to_s.sub(/=\z/, "")
    if name.to_s.end_with?("=")
      @data[key] = args.first
      return args.first
    end
    if block
      sub = Recorder.new(@data, "#{key}.#{args.first}.")
      block.call(sub)
      return sub
    end
    unless args.empty? && kw.empty?
      (@data[key] ||= []) << [args, kw]
      return nil
    end
    Recorder.new(@data, key + ".")
  end
  def respond_to_missing?(*) = true
end

module Vagrant
  VERSION = "2.4.9"
  def self.has_plugin?(name) = PLUGINS.include?(name)
  def self.configure(_version)
    data = {}
    yield Recorder.new(data, "")
    $result = data
  end
end

begin
  load vagrantfile
  puts JSON.generate({ "ok" => true, "config" => $result })
rescue => e
  puts JSON.generate({ "ok" => false, "error" => e.message })
end
RUBY

# evaluate <host_os> <host_cpu> <kvm 0|1> <plugins,comma> — result JSON in $json
evaluate() {
    json="$(cd "$SANDBOX" && FLTH_TEST_KVM="$3" ruby "$SANDBOX/eval.rb" "$1" "$2" "$3" "$4" "$REPO/vagrant/Vagrantfile" 2>&1)"
}
field() { printf '%s' "$json" | ruby -rjson -e 'd = JSON.parse(STDIN.read); v = ARGV[0].split("/").reduce(d) { |a, k| a.is_a?(Hash) ? a[k] : nil }; puts(v.is_a?(String) ? v : JSON.generate(v))' "$1"; }

export FLTH_VM_NAME=rust-fs-demo FLTH_VM_MEMORY=2G FLTH_VM_CPUS=2 FLTH_VM_DISK=16G FLTH_VM_SSH_PORT=50122
export FLTH_VM_DEADLINE_MINUTES=480 FLTH_SHARE_DIR="$SANDBOX/share" FLTH_QEMU_DIR="$SANDBOX/fw"
export FLTH_REPO_DIR="$SANDBOX/repo" FLTH_VM_DISPOSABLE=1 FLTH_VM_CACHE_DISK=""
export FLTH_VM_CONSOLE_LOG="$SANDBOX/machine/console.log"

P=vm.provider.qemu

# --- Linux aarch64 --------------------------------------------------------
evaluate linux-gnu aarch64 1 vagrant-qemu
check_eq "$(field ok)" true "Linux aarch64 evaluates"
check_eq "$(field config/vm.box)" "cloud-image/debian-12" "  box cloud-image/debian-12"
check_eq "$(field config/vm.box_architecture)" arm64 "  arm64"
check_eq "$(field config/$P.machine)" "virt,accel=kvm,highmem=on" "  KVM, virt machine"
check_eq "$(field config/$P.cpu)" host "  host CPU"
check_eq "$(field config/$P.qemu_dir)" "$SANDBOX/fw" "  firmware from FLTH_QEMU_DIR"
check_contains "$(field config/$P.extra_qemu_args)" "security_model=mapped-xattr" "  shares over 9p"
check_contains "$(field config/vm.provision)" "guest/mount-share.sh" "  and mounts it in the guest on every boot"
check_contains "$(field config/$P.extra_qemu_args)" "mount_tag=flth_repo,security_model=none" \
    "  and shares the consumer repository with the host's real ownership and xattrs"
check_contains "$(field config/vm.provision)" '"repo"' "  mounting it too, on every boot"
check_eq "$(field config/notify_forwarder.enable)" null "  no macOS-only settings"
check_eq "$(field config/vm.hostname)" rust-fs-demo "  hostname from the project name"
check_eq "$(field config/$P.memory)|$(field config/$P.smp)|$(field config/$P.disk_resize)" \
    "2G|cpus=2,sockets=1,cores=2,threads=1|16G" "  sizing from the config"
check_contains "$(field config/vm.provision)" '"run":"always"' "  provisioners re-run on every boot"
check_contains "$(field config/vm.provision)" '["480"]' "  the deadline minutes are passed as an argument"
check_eq "$(field config/vagrant.plugins)" "{}" "  the box's own plugin declaration is cleared"
check_contains "$(field config/vm.provision)" '[[["apt-ready"],{"type":"shell","run":"always","path":"guest/apt-ready.sh"}]' \
    "  the package manager is made ready on every boot, before anything else is provisioned"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on" \
    "  a disposable boot writes to an overlay QEMU discards, never to the machine's disk"
FLTH_VM_DISPOSABLE=0 evaluate linux-gnu aarch64 1 vagrant-qemu
check_eq "$(field config/$P.extra_drive_args)" null "  a provisioning boot writes the disk itself"

evaluate linux-gnu aarch64 0 vagrant-qemu
check_contains "$(field error)" "KVM is required" "Linux without usable /dev/kvm is refused, not emulated"
evaluate linux-gnu aarch64 1 ""
check_contains "$(field error)" "vagrant plugin install vagrant-qemu" "Linux without the stock plugin says how to install it"
rm "$SANDBOX/fw/edk2-arm-vars.fd"
evaluate linux-gnu aarch64 1 vagrant-qemu
check_contains "$(field error)" "edk2-arm-vars.fd is not readable" "Linux aarch64 without firmware is refused"
: > "$SANDBOX/fw/edk2-arm-vars.fd"

# --- Linux x86_64 ---------------------------------------------------------
evaluate linux-gnu x86_64 1 vagrant-qemu
check_eq "$(field ok)" true "Linux x86_64 evaluates"
check_eq "$(field config/vm.box_architecture)" amd64 "  amd64 box"
check_eq "$(field config/$P.machine)" "q35,accel=kvm" "  KVM, q35 machine"
check_eq "$(field config/$P.net_device)" "virtio-net-pci" "  PCI network device"
check_eq "$(field config/$P.qemu_dir)" null "  no UEFI firmware directory"
check_contains "$(field config/$P.extra_qemu_args)" "mount_tag=flth_share" "  shares over 9p"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on" "  a disposable boot's writes are discarded"

# --- macOS arm64 ------------------------------------------------------------
evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field ok)" true "macOS arm64 evaluates"
check_eq "$(field config/vm.box)" "christhomas/vagrant-rpi-bookworm-arm64" "  the owner's box"
check_eq "$(field config/vm.box_url)" \
    "https://github.com/christhomas/vagrant-rpi-bookworm-arm64/releases/download/v1.0.0/rpi-arm64.box" \
    "  fetched from its public release on first boot (#8)"
check_eq "$(field config/$P.machine)" "virt,accel=hvf,highmem=on" "  HVF"
check_eq "$(field config/notify_forwarder.enable)" true "  notify forwarder enabled (disabling it breaks boot)"
check_contains "$(field config/vm.synced_folder)" '"type":"virtiofs"' "  shares over virtiofs"
check_contains "$(field config/vm.synced_folder)" '"/repo"' "  the consumer repository among them"
check_lacks "$(field config/$P.extra_qemu_args)" "-virtfs" "  no 9p"
check_eq "$(field config/$P.virtiofs_guest_uid)" 1001 "  virtiofs uid matches the box's vagrant user"
check_eq "$(field config/$P.virtiofsd_bin)" null \
    "  virtiofsd is the provider's default, the tap's released build, never a hand-placed pre-release binary"
check_contains "$(field config/$P.extra_virtiofsd_args)" '"--thread-pool-size=1"' \
    "  one virtiofsd thread: the macOS port switches credentials process-wide"
check_contains "$(field config/$P.extra_virtiofsd_args)" '"--xattr"' "  extended attributes survive the share"
check_contains "$(field config/vm.provision)" '"guest/apt-ready.sh"' "  the box's first-boot dialog is disabled and the package manager made ready"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on" "  a disposable boot's writes are discarded"
evaluate darwin23 arm64 0 vagrant-qemu
check_contains "$(field error)" "vagrant-qemu-christhomas is missing" "macOS with only the stock plugin is refused"

# --- the serial console (#61) -----------------------------------------------
# The provider sends the guest's serial console, where its kernel writes,
# to a Unix socket nobody reads, so a boot that never answers SSH said
# nothing about why. QEMU's own log of that chardev (`ser0`, in every
# provider build) keeps it in the machine directory on every host.
for h in "linux-gnu x86_64 1 vagrant-qemu" "linux-gnu aarch64 1 vagrant-qemu" \
    "darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas"; do
    # shellcheck disable=SC2086  # four words, on purpose
    set -- $h
    evaluate "$@"
    args="$(field config/$P.extra_qemu_args)"
    check_contains "$args" '"-set","chardev.ser0.logfile='"$FLTH_VM_CONSOLE_LOG"'"' \
        "$1 $2: the console is logged to FLTH_VM_CONSOLE_LOG"
    check_contains "$args" '"-set","chardev.ser0.logappend=off"' "  afresh on every boot"
done

# --- the declared cache (#39) -----------------------------------------------
# A disk of its own, attached through extra_qemu_args and NOT through the
# provider's drive list: extra_drive_args (snapshot=on on a disposable
# boot) is applied to every drive the provider attaches, and a cache it
# reached would be discarded with the run it exists to outlive.
cache_disk="$SANDBOX/machine/cache.img"
FLTH_VM_CACHE_DISK="$cache_disk" evaluate linux-gnu x86_64 1 vagrant-qemu
check_eq "$(field ok)" true "a declared cache evaluates on Linux"
args="$(field config/$P.extra_qemu_args)"
check_contains "$args" "if=none,id=flth_cache,file=$cache_disk,format=raw" "  the cache is a drive of its own"
check_contains "$args" "virtio-blk-pci,drive=flth_cache,serial=flth-cache" \
    "  with a serial the guest finds it by"
# QEMU creates every -device before the device an -drive if=virtio
# implies, so an unplaced cache took the PCI slot ahead of the machine's
# own disk: the BIOS booted the empty cache, and the guest never came up.
check_contains "$args" "serial=flth-cache,addr=0x10" \
    "  on a PCI slot after the machine's own disk, which the BIOS boots"
check_lacks "$args" "id=flth_cache,file=$cache_disk,format=raw,snapshot" "  and its writes are never sent to the overlay"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on" "  while the machine's own disk stays disposable"
check_contains "$args" "mount_tag=flth_share" "  and the shares are still there"
check_contains "$(field config/vm.provision)" '"path":"guest/mount-cache.sh","args":["flth-cache","/cache"]' \
    "  it is mounted at /cache on every boot"
FLTH_VM_CACHE_DISK="$cache_disk" evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field ok)" true "a declared cache evaluates on macOS"
check_contains "$(field config/$P.extra_qemu_args)" "if=none,id=flth_cache,file=$cache_disk,format=raw" "  the same drive"
check_contains "$(field config/vm.provision)" '"guest/mount-cache.sh"' "  mounted the same way"
FLTH_VM_CACHE_DISK="" evaluate linux-gnu x86_64 1 vagrant-qemu
check_lacks "$(field config/$P.extra_qemu_args)" "flth_cache" "no cache declared: no cache drive"
check_lacks "$(field config/vm.provision)" "mount-cache" "  and nothing mounted at /cache"
FLTH_VM_CACHE_DISK="" evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_lacks "$(field config/$P.extra_qemu_args)" "flth_cache" "  on macOS either"

evaluate darwin23 x86_64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_contains "$(field error)" "supports macOS arm64, Linux aarch64 and Linux x86_64" "an Intel Mac is refused by name"

# --- validation -------------------------------------------------------------
refuse_env() {
    # refuse_env <var> <value>
    local saved="${!1}"
    export "$1=$2"
    evaluate linux-gnu x86_64 1 vagrant-qemu
    check_contains "$(field error)" "$1" "$1=$(printf '%q' "$2") is refused"
    export "$1=$saved"
}
refuse_env FLTH_VM_NAME "Bad_Name"
refuse_env FLTH_VM_MEMORY "4G
-drive file=/etc/shadow"
refuse_env FLTH_VM_CPUS "2,maxcpus=64"
refuse_env FLTH_VM_DISK "32G;reboot"
refuse_env FLTH_VM_SSH_PORT "22 -netdev x"
refuse_env FLTH_VM_DEADLINE_MINUTES "480
rm -rf /"
refuse_env FLTH_VM_DEADLINE_MINUTES "0"
refuse_env FLTH_SHARE_DIR "relative/share"
refuse_env FLTH_SHARE_DIR "/tmp/x,readonly=off"
refuse_env FLTH_REPO_DIR "relative/repo"
refuse_env FLTH_VM_DISPOSABLE "yes"
refuse_env FLTH_VM_DISPOSABLE "1,file=/etc/shadow"
refuse_env FLTH_VM_CACHE_DISK "relative/cache.img"
refuse_env FLTH_VM_CACHE_DISK "/tmp/cache.img,snapshot=on"
refuse_env FLTH_VM_CONSOLE_LOG "relative/console.log"
refuse_env FLTH_VM_CONSOLE_LOG "/tmp/console.log
-drive file=/etc/shadow"

unset FLTH_VM_NAME
evaluate linux-gnu x86_64 1 vagrant-qemu
check_contains "$(field error)" "not by running vagrant directly" "vagrant run by hand stops at the first missing value, and says why"

# --- the macOS workflow's `vagrant validate` --------------------------------
# That step runs real Vagrant on the Vagrantfile, which refuses to load
# without every value it requires. A value added here and not there fails
# only on the macOS runner, after a Homebrew install; this finds it first.
# FLTH_QEMU_DIR is required only on a Mac without Homebrew's QEMU firmware.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validate_step="$(awk '/validates under real Vagrant/,/vagrant validate$/' \
    "$here/.github/workflows/macos-host.yml")"
if [ -z "$validate_step" ]; then
    bad "macos-host.yml has a step that runs vagrant validate"
else
    while read -r var; do
        if grep -qE "(^|[[:space:]])(export )?${var}[:=]" <<<"$validate_step"; then
            ok "macos-host.yml's vagrant validate step sets $var"
        else
            bad "macos-host.yml's vagrant validate step sets $var, which the Vagrantfile requires"
        fi
    done < <(grep -oE 'flth_env\("FLTH_[A-Z_]+"' "$here/vagrant/Vagrantfile" \
        | grep -oE 'FLTH_[A-Z_]+' | grep -vx FLTH_QEMU_DIR | sort -u)
fi

finish vagrantfile
