#!/usr/bin/env bash
#
# vagrantfile-hotplug.sh — the shared guest boots ready for a tree to be attached
# to it while it runs (#222), on every host.
#
# No tree is shared at boot any more: each run's tree is a vhost-user-fs device
# hot-plugged into a free pcie-root-port and served by a virtiofsd of its own. QEMU
# refuses a hot-plug into pcie.0, so the ports are reserved at boot, with
# io-reserve=0 so that 32 of them do not run out of IO space. virtiofsd reaches the
# guest's memory only through a memory backend with share=on, which the macOS
# provider added only for its boot-time folders. QMP is how a device is added and
# removed. tests/vagrantfile.sh evaluates the rest of the file the same way.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
require_tool ruby "apt-get install ruby / brew install ruby" || finish vagrantfile-hotplug

mkdir -p "$SANDBOX/fw" "$SANDBOX/mem"
: > "$SANDBOX/fw/edk2-aarch64-code.fd"; : > "$SANDBOX/fw/edk2-arm-vars.fd"

cat > "$SANDBOX/eval.rb" <<'RUBY'
require "json"
require "rbconfig"
host_os, host_cpu, plugins, vagrantfile = ARGV
RbConfig::CONFIG["host_os"] = host_os
RbConfig::CONFIG["host_cpu"] = host_cpu
PLUGINS = plugins.split(",")
class File
  class << self
    %i[exist? readable? writable?].each do |m|
      orig = instance_method(m) rescue method(m).unbind
      define_method(m) do |path|
        return true if path == "/dev/kvm"
        orig.bind(self).call(path)
      end
    end
  end
end
class Recorder
  def initialize(data, prefix) ; @data = data ; @prefix = prefix ; end
  def method_missing(name, *args, **kw, &block)
    key = @prefix + name.to_s.sub(/=\z/, "")
    if name.to_s.end_with?("=")
      @data[key] = args.empty? ? kw : args.first
      return @data[key]
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
  def respond_to_missing?(*) ; true ; end
end
module Vagrant
  def self.has_plugin?(name) ; PLUGINS.include?(name) ; end
  def self.configure(_v) ; data = {} ; yield Recorder.new(data, "") ; $result = data ; end
end
begin
  load vagrantfile
  puts JSON.generate({ "ok" => true, "config" => $result })
rescue => e
  puts JSON.generate({ "ok" => false, "error" => e.message })
end
RUBY

evaluate() { json="$(cd "$SANDBOX" && ruby "$SANDBOX/eval.rb" "$1" "$2" "$3" "$REPO/vagrant/Vagrantfile" 2>&1)"; }
field() { printf '%s' "$json" | ruby -rjson -e 'd = JSON.parse(STDIN.read); v = ARGV[0].split("/").reduce(d) { |a, k| a.is_a?(Hash) ? a[k] : nil }; puts(v.is_a?(String) ? v : JSON.generate(v))' "$1"; }
# The QEMU arguments as one line, words apart.
qemu_args() { printf '%s' "$json" | ruby -rjson -e 'd = JSON.parse(STDIN.read); puts Array(d.dig("config", "vm.provider.qemu.extra_qemu_args")).join(" ")'; }

# Everything the Vagrantfile reads, and nothing about a host directory to share.
export FLTH_VM_NAME=shared-debian-12 FLTH_VM_MEMORY=2G FLTH_VM_CPUS=2 FLTH_VM_DISK=16G FLTH_VM_SSH_PORT=50200
export FLTH_VM_DEADLINE_MINUTES=480 FLTH_QEMU_DIR="$SANDBOX/fw" FLTH_VM_GUEST=debian-12
export FLTH_VM_DISPOSABLE=1 FLTH_VM_CACHE_DISK="" FLTH_VM_CONSOLE_LOG="$SANDBOX/console.log"
export FLTH_VM_QMP="$SANDBOX/qmp.sock" FLTH_VM_SLOTS=32 FLTH_VM_MEM_DIR="$SANDBOX/mem"
unset FLTH_SHARE_DIR FLTH_REPO_DIR

for host in "linux-gnu aarch64 vagrant-qemu" "linux-gnu x86_64 vagrant-qemu" \
    "darwin23 arm64 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas"; do
    # shellcheck disable=SC2086  # the three words are three arguments
    set -- $host
    label="$1 $2"
    evaluate "$1" "$2" "$3"
    check_eq "$(field ok)" true "$label evaluates with no host directory to share ($(field error))"
    args="$(qemu_args)"
    check_contains "$args" "-qmp unix:$SANDBOX/qmp.sock,server=on,wait=off" "$label: QMP on FLTH_VM_QMP"
    check_eq "$(printf '%s\n' "$args" | tr ' ' '\n' | grep -c '^pcie-root-port,' | tr -d ' ')" 32 \
        "$label: FLTH_VM_SLOTS pcie-root-ports, free for a device to be hot-plugged into"
    check_eq "$(printf '%s\n' "$args" | tr ' ' '\n' | grep '^pcie-root-port,' | grep -vc 'io-reserve=0' | tr -d ' ')" 0 \
        "$label: every one with io-reserve=0, so that they do not run out of IO space"
    check_contains "$args" "pcie-root-port,id=flth_rp1,bus=pcie.0,chassis=1,slot=1,io-reserve=0" \
        "$label: each named, on its own chassis and slot"
    check_contains "$args" "-numa node,memdev=flth_mem" "$label: guest memory comes from a backend"
    check_lacks "$args" "-virtfs" "$label: nothing is shared over 9p"
    check_lacks "$(field config/vm.synced_folder)" "virtiofs" "$label: and no folder is shared at boot"
    check_lacks "$(field config/vm.provision)" "mount-share.sh" "$label: so none is mounted at boot"
    case "$1" in
        darwin*)
            check_contains "$args" "memory-backend-file,id=flth_mem,size=2G,mem-path=$SANDBOX/mem,share=on" \
                "$label: a shared file backend in FLTH_VM_MEM_DIR, which QEMU unlinks at once" ;;
        *)
            check_contains "$args" "memory-backend-memfd,id=flth_mem,size=2G,share=on" "$label: a shared memfd backend" ;;
    esac
done

FLTH_VM_SLOTS=0 evaluate linux-gnu x86_64 vagrant-qemu
check_eq "$(field ok)" false "FLTH_VM_SLOTS of 0 is refused: no run could attach its tree"
FLTH_VM_QMP="relative.sock" evaluate linux-gnu x86_64 vagrant-qemu
check_eq "$(field ok)" false "a relative QMP socket path is refused"

finish vagrantfile-hotplug
