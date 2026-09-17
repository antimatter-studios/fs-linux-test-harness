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
export FLTH_REPO_DIR="$SANDBOX/repo"

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
check_contains "$(field config/$P.extra_qemu_args)" "mount_tag=flth_repo" "  and shares the consumer repository the same way"
check_contains "$(field config/vm.provision)" '"repo"' "  mounting it too, on every boot"
check_eq "$(field config/notify_forwarder.enable)" null "  no macOS-only settings"
check_eq "$(field config/vm.hostname)" rust-fs-demo "  hostname from the project name"
check_eq "$(field config/$P.memory)|$(field config/$P.smp)|$(field config/$P.disk_resize)" \
    "2G|cpus=2,sockets=1,cores=2,threads=1|16G" "  sizing from the config"
check_contains "$(field config/vm.provision)" '"run":"always"' "  provisioners re-run on every boot"
check_contains "$(field config/vm.provision)" '["480"]' "  the deadline minutes are passed as an argument"
check_eq "$(field config/vagrant.plugins)" "{}" "  the box's own plugin declaration is cleared"

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

# --- macOS arm64 ------------------------------------------------------------
evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field ok)" true "macOS arm64 evaluates"
check_eq "$(field config/vm.box)" "christhomas/vagrant-rpi-bookworm-arm64" "  the owner's box"
check_eq "$(field config/$P.machine)" "virt,accel=hvf,highmem=on" "  HVF"
check_eq "$(field config/notify_forwarder.enable)" true "  notify forwarder enabled (disabling it breaks boot)"
check_contains "$(field config/vm.synced_folder)" '"type":"virtiofs"' "  shares over virtiofs"
check_contains "$(field config/vm.synced_folder)" '"/repo"' "  the consumer repository among them"
check_eq "$(field config/$P.extra_qemu_args)" null "  no 9p"
check_eq "$(field config/$P.virtiofs_guest_uid)" 1001 "  virtiofs uid matches the box's vagrant user"
evaluate darwin23 arm64 0 vagrant-qemu
check_contains "$(field error)" "vagrant-qemu-christhomas is missing" "macOS with only the stock plugin is refused"

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

unset FLTH_VM_NAME
evaluate linux-gnu x86_64 1 vagrant-qemu
check_contains "$(field error)" "not by running vagrant directly" "vagrant run by hand stops at the first missing value, and says why"

finish vagrantfile
