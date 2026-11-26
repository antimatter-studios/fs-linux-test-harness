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

mkdir -p "$SANDBOX/mem" "$SANDBOX/fw"
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
      value = args.empty? ? kw : args.first
      @data[key] = value
      return value
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
  def respond_to_missing?(*)
    true
  end
end

module Vagrant
  VERSION = "2.4.9"
  def self.has_plugin?(name)
    PLUGINS.include?(name)
  end
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
export FLTH_VM_DEADLINE_MINUTES=480 FLTH_QEMU_DIR="$SANDBOX/fw"
export FLTH_VM_GUEST=debian-12
export FLTH_VM_DISPOSABLE=1
# Where a run's tree is attached while the guest runs (#222): tests/vagrantfile-hotplug.sh.
export FLTH_VM_QMP="$SANDBOX/qmp.sock" FLTH_VM_SLOTS=4 FLTH_VM_MEM_DIR="$SANDBOX/mem"
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
check_contains "$(field config/$P.extra_qemu_args)" "pcie-root-port" "  with ports a run's tree is attached to"
check_eq "$(field config/notify_forwarder.enable)" null "  no macOS-only settings"
check_eq "$(field config/notify_forwarder.binaries)" null "  and no guest receiver to replace"
check_lacks "$(field config/$P.extra_qemu_args)" "-vga" "  and no display device: the arm64 guests boot through UEFI"
check_eq "$(field config/vm.hostname)" rust-fs-demo "  hostname from the project name"
check_eq "$(field config/$P.memory)|$(field config/$P.smp)|$(field config/$P.disk_resize)" \
    "2G|cpus=2,sockets=1,cores=2,threads=1|16G" "  sizing from the config"
check_contains "$(field config/vm.provision)" '"run":"always"' "  provisioners re-run on every boot"
check_contains "$(field config/vm.provision)" '["480"]' "  the deadline minutes are passed as an argument"
check_eq "$(field config/vagrant.plugins)" "{}" "  the box's own plugin declaration is cleared"
check_contains "$(field config/vm.provision)" '[[["disk-tmp"],{"type":"shell","run":"always","path":"guest/disk-tmp.sh","args":["verify"]}]' \
    "  disk-backed /tmp is verified before other provisioning on a disposable boot"
check_contains "$(field config/vm.provision)" '"path":"guest/apt-ready.sh"' \
    "  the package manager is made ready on every boot"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on,discard=unmap" \
    "  a disposable boot writes to an overlay QEMU discards, never to the machine's disk"
check_contains "$(field config/vm.provision)" '"path":"guest/online-discard.sh"' \
    "  what the guest deletes goes back to the host: the drive takes its discards and the root sends them"
FLTH_VM_DISPOSABLE=0 evaluate linux-gnu aarch64 1 vagrant-qemu
check_eq "$(field config/$P.extra_drive_args)" null "  a provisioning boot writes the disk itself"
check_contains "$(field config/vm.provision)" '"path":"guest/disk-tmp.sh","args":["prepare"]' \
    "  and prepares disk-backed /tmp on the base disk"
check_lacks "$(field config/vm.provision)" "online-discard" "  and its root sends no discards to a drive that ignores them"

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
check_contains "$(field config/$P.extra_qemu_args)" "pcie-root-port" "  with ports a run's tree is attached to"
check_contains "$(field config/$P.extra_qemu_args)" '"-vga","std"' \
    "  a standard VGA after the provider's -vga none, without which Debian 13's GRUB resets the machine (#70)"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on,discard=unmap" "  a disposable boot's writes are discarded"

check_eq "$(field config/vm.box)|$(field config/vm.box_version)" "cloud-image/debian-12|20260909.2596.0" \
    "  Debian 12, pinned, unless the config names another guest"

evaluate linux-gnu x86_64 0 vagrant-qemu
check_contains "$(field error)" "KVM is required" "the default x86_64 guest requires KVM"
FLTH_ACCELERATOR=tcg FLTH_VM_TB_MIB=512 FLTH_VM_MEMORY=256M evaluate linux-gnu x86_64 0 vagrant-qemu
check_eq "$(field ok)" true "x86_64 TCG evaluates without KVM"
check_eq "$(field config/vm.box)|$(field config/vm.box_version)|$(field config/vm.box_architecture)" \
    "cloud-image/debian-12|20260909.2596.0|amd64" "  TCG uses the same pinned amd64 box"
check_eq "$(field config/$P.machine)|$(field config/$P.cpu)" "q35|max" "  TCG keeps q35 and uses an emulated CPU"
check_contains "$(field config/$P.extra_qemu_args)" '"-accel","tcg,thread=multi,tb-size=512"' "  the configured translation cache reaches QEMU"
check_eq "$(field config/$P.memory)" 256M "  Vagrant receives the resolved guest memory"
check_contains "$(field config/$P.extra_qemu_args)" 'size=256M,share=on' "  the virtiofs memory backend uses the same guest memory"
check_contains "$(field config/$P.extra_qemu_args)" "pcie-root-port" "  TCG reserves the same hot-plug ports"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on,discard=unmap" "  TCG uses a disposable overlay"
# --- TCG: FLTH_GUEST_ARCH picks the guest, and the host does not -----------------
# The same Debian cloud box on every host, and only the emulated CPU differs. The
# provider plugins stay the host's.
tcg_pins() {
    # tcg_pins <label> <host_os> <host_cpu> <plugins>
    local label="$1"
    shift
    FLTH_ACCELERATOR=tcg FLTH_GUEST_ARCH=x86_64 evaluate "$1" "$2" 0 "$3"
    check_eq "$(field ok)" true "$label: an x86_64 guest under TCG evaluates without KVM"
    check_eq "$(field config/vm.box)|$(field config/vm.box_version)|$(field config/vm.box_architecture)" \
        "cloud-image/debian-12|20260909.2596.0|amd64" "  the pinned amd64 Debian box"
    check_eq "$(field config/$P.arch)|$(field config/$P.machine)|$(field config/$P.cpu)|$(field config/$P.net_device)" \
        "x86_64|q35|max|virtio-net-pci" "  q35 with an emulated CPU"
    check_eq "$(field config/$P.qemu_dir)" null "  SeaBIOS, no UEFI firmware"
    check_contains "$(field config/$P.extra_qemu_args)" '"-vga","std"' "  and the standard VGA Debian's GRUB needs"
    check_contains "$(field config/$P.extra_qemu_args)" '"-accel","tcg,thread=multi"' "  booted by TCG"
    check_contains "$(field config/$P.extra_qemu_args)" "pcie-root-port" "  with the same hot-plug ports"
    check_lacks "$(field config/$P.extra_qemu_args)" "-kernel" "  through its own bootloader"
    FLTH_ACCELERATOR=tcg FLTH_GUEST_ARCH=aarch64 evaluate "$1" "$2" 0 "$3"
    check_eq "$(field ok)" true "$label: an aarch64 guest under TCG evaluates without KVM"
    check_eq "$(field config/vm.box)|$(field config/vm.box_version)|$(field config/vm.box_architecture)" \
        "cloud-image/debian-12|20260909.2596.0|arm64" "  the pinned arm64 Debian box"
    check_eq "$(field config/$P.arch)|$(field config/$P.machine)|$(field config/$P.cpu)|$(field config/$P.net_device)" \
        "aarch64|virt,highmem=on|max,pauth-impdef=on|virtio-net-device" "  virt with an emulated CPU and cheap pointer authentication"
    check_lacks "$(field config/$P.extra_qemu_args)" "-vga" "  no display device: it boots through UEFI"
    check_contains "$(field config/$P.extra_qemu_args)" '"-accel","tcg,thread=multi"' "  booted by TCG"
    check_contains "$(field config/$P.extra_qemu_args)" "pcie-root-port" "  with the same hot-plug ports"
    check_lacks "$(field config/$P.extra_qemu_args)" "-kernel" "  through its own bootloader"
}
tcg_pins "Linux x86_64" linux-gnu x86_64 vagrant-qemu
check_eq "$(field config/$P.qemu_dir)" "$SANDBOX/fw" "  firmware from FLTH_QEMU_DIR"
tcg_pins "Linux aarch64" linux-gnu aarch64 vagrant-qemu
tcg_pins "Apple Silicon" darwin23 arm64 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field config/$P.qemu_dir)" "$SANDBOX/fw" "  firmware from FLTH_QEMU_DIR when it is set"
FLTH_QEMU_DIR="" FLTH_ACCELERATOR=tcg FLTH_GUEST_ARCH=aarch64 \
    evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
if [ -r /opt/homebrew/share/qemu/edk2-aarch64-code.fd ]; then
    check_eq "$(field config/$P.qemu_dir)" /opt/homebrew/share/qemu "  and from Homebrew's QEMU when it is not"
else
    check_contains "$(field error)" "/opt/homebrew/share/qemu/edk2-aarch64-code.fd is not readable" \
        "  and from Homebrew's QEMU when it is not, refused by name when that has none"
fi
FLTH_ACCELERATOR=tcg evaluate linux-gnu aarch64 0 vagrant-qemu
check_eq "$(field config/vm.box_architecture)|$(field config/$P.cpu)" "arm64|max,pauth-impdef=on" \
    "TCG with no FLTH_GUEST_ARCH emulates the host's architecture"
FLTH_ACCELERATOR=tcg evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field config/vm.box)|$(field config/vm.box_architecture)" "cloud-image/debian-12|arm64" "  on a Mac too, with the Debian box"
check_eq "$(field config/notify_forwarder.enable)" true "  and the macOS plugins' settings"
binaries="$(field config/notify_forwarder.binaries)"
check_contains "$binaries" "x86_64" "  whose stand-in receiver is given for an x86_64 guest too"
FLTH_ACCELERATOR=tcg FLTH_VM_GUEST=debian-13 FLTH_GUEST_ARCH=x86_64 \
    evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field config/vm.box)" "cloud-image/debian-13" "a debian-13 guest boots on a Mac under TCG"
FLTH_GUEST_ARCH=x86_64 evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_contains "$(field error)" "needs FLTH_ACCELERATOR=tcg" "another architecture without TCG is refused"
FLTH_GUEST_ARCH=aarch64 evaluate linux-gnu x86_64 1 vagrant-qemu
check_contains "$(field error)" "needs FLTH_ACCELERATOR=tcg" "  on Linux too"
FLTH_ACCELERATOR=tcg FLTH_GUEST_ARCH=riscv64 evaluate linux-gnu x86_64 0 vagrant-qemu
check_contains "$(field error)" "must be x86_64 or aarch64" "an architecture the harness has no box for is refused"
FLTH_ACCELERATOR=kvm evaluate linux-gnu x86_64 1 vagrant-qemu
check_contains "$(field error)" "FLTH_ACCELERATOR=tcg" "an accelerator other than tcg is refused"

# --- [vm] guest ---------------------------------------------------------------
FLTH_VM_GUEST=debian-13 evaluate linux-gnu x86_64 1 vagrant-qemu
check_eq "$(field config/vm.box)|$(field config/vm.box_version)" "cloud-image/debian-13|20260914.2601.0" \
    "a debian-13 guest boots the pinned Debian 13 box"
FLTH_VM_GUEST=debian-13 evaluate linux-gnu aarch64 1 vagrant-qemu
check_eq "$(field config/vm.box)|$(field config/vm.box_architecture)" "cloud-image/debian-13|arm64" \
    "  on an aarch64 host too"
FLTH_VM_GUEST=debian-13 evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_contains "$(field error)" "has no macOS box" "a debian-13 guest on a Mac is refused, saying there is no box for it"

# --- macOS arm64 ------------------------------------------------------------
evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field ok)" true "macOS arm64 evaluates"
check_eq "$(field config/vm.box)" "christhomas/vagrant-rpi-bookworm-arm64" "  the owner's box"
check_eq "$(field config/vm.box_url)" \
    "https://github.com/christhomas/vagrant-rpi-bookworm-arm64/releases/download/v1.0.0/rpi-arm64.box" \
    "  fetched from its public release on first boot (#8)"
check_eq "$(field config/$P.machine)" "virt,accel=hvf,highmem=on" "  HVF"
check_eq "$(field config/notify_forwarder.enable)" true "  notify forwarder enabled (disabling it breaks boot)"
# The plugin's own guest receiver writes into the files an event names, and
# truncates one it reads as empty, so the host's payload could end up empty (#84).
# The stand-in the Vagrantfile gives the plugin must be what it is offered for an
# arm64 guest, under its real checksum, and must do nothing.
receiver_off="$REPO/vagrant/guest/notify-receiver-off.sh"
receiver_sum="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$receiver_off" 2>/dev/null)"
binaries="$(field config/notify_forwarder.binaries)"
check_contains "$binaries" "linux" "  the plugin is given a guest receiver for Linux"
check_contains "$binaries" "arm64" "  on arm64"
check_contains "$binaries" "file://$receiver_off" "  the harness's own stand-in"
check_contains "$binaries" "${receiver_sum:-no checksum: the stand-in is missing}" "  under its real checksum"
receiver_out="$(cd "$SANDBOX" && bash "$receiver_off" receive -p 29324 2>&1)"
check_eq "$?|$receiver_out" "0|" "  which exits at once, saying nothing, as the plugin starts it"
check_lacks "$(grep -v '^[[:space:]]*#' "$receiver_off" 2>/dev/null)" ">" "  and writes to nothing"
check_lacks "$(field config/vm.synced_folder)" '"type":"virtiofs"' "  no folder of the provider's: a run's tree is attached by the harness"
# The forwarder plugin, 0.7.5 and 0.7.7 alike, starts a host watcher for each synced
# folder that is not disabled, and up to 0.7.5 a destroy left them running (#164).
# With every folder disabled it starts none.
enabled="$(field config/vm.synced_folder | ruby -rjson -e 'puts JSON.parse(STDIN.read).count { |_, kw| kw["disabled"] != true }' 2>/dev/null)"
check_eq "$enabled" 0 "  every synced folder is disabled, so the forwarder starts no watcher (#164)"
check_eq "$(field config/$P.virtiofsd_bin)" null "  and the provider is given no virtiofsd"
check_contains "$(field config/$P.extra_qemu_args)" "memory-backend-file,id=flth_mem" "  guest memory a virtiofsd can reach"
check_contains "$(field config/vm.provision)" '"guest/apt-ready.sh"' "  the box's first-boot dialog is disabled and the package manager made ready"
check_eq "$(field config/$P.extra_drive_args)" "snapshot=on,discard=unmap" "  a disposable boot's writes are discarded"
evaluate darwin23 arm64 0 vagrant-qemu
check_contains "$(field error)" "vagrant-qemu-christhomas is missing" "macOS with only the stock plugin is refused"
evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_lacks "$(field config/$P.extra_qemu_args)" "-accel" "HVF takes no -accel"
FLTH_ACCELERATOR=tcg evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_contains "$(field config/$P.extra_qemu_args)" '"-accel","tcg,thread=multi"' "Apple Silicon TCG: with no cap, QEMU sizes the translation cache"

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
    check_contains "$(field config/vm.network)" '"id":"ssh","disabled":true' \
        "$1 $2: the duplicate high-level SSH forward bypasses connection-based collision probing"
    check_contains "$(field config/vm.network)" '"host":50122' \
        "  the provider retains the port selected by the harness's bind probe"
done

# --- the kernel a provisioning boot left on the disk (#80) -------------------
# The box's own Vagrantfile passes -kernel and -initrd, which the provider
# puts first when it merges the two; QEMU takes the last of each. That part
# is proven on a real guest by tests/smoke.sh, and this pins what is passed.
boot_kernel="$SANDBOX/machine/boot/vmlinuz"
boot_initrd="$SANDBOX/machine/boot/initrd.img"
FLTH_VM_BOOT_KERNEL="$boot_kernel" FLTH_VM_BOOT_INITRD="$boot_initrd" evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_eq "$(field ok)" true "a kept kernel evaluates on macOS"
check_contains "$(field config/$P.extra_qemu_args)" "\"-kernel\",\"$boot_kernel\",\"-initrd\",\"$boot_initrd\"" \
    "  QEMU is told to run it and its initrd"
evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas
check_lacks "$(field config/$P.extra_qemu_args)" "-kernel" "no kept kernel: the box's own arguments stand"
for flth_host in "linux-gnu x86_64 1 vagrant-qemu" "linux-gnu aarch64 1 vagrant-qemu"; do
    # shellcheck disable=SC2086  # four words, one for each argument
    FLTH_VM_BOOT_KERNEL="$boot_kernel" FLTH_VM_BOOT_INITRD="$boot_initrd" evaluate $flth_host
    check_lacks "$(field config/$P.extra_qemu_args)" "-kernel" "${flth_host% 1 *}: a Linux guest chooses its own kernel, whatever is exported"
    # A profile supplies the root command line captured from its preparation boot.
    # shellcheck disable=SC2086
    FLTH_VM_BOOT_KERNEL="$boot_kernel" FLTH_VM_BOOT_INITRD="$boot_initrd" \
        FLTH_VM_BOOT_CMDLINE='root=UUID=profile-root ro console=ttyS0' evaluate $flth_host
    check_contains "$(field config/$P.extra_qemu_args)" "\"-kernel\",\"$boot_kernel\",\"-initrd\",\"$boot_initrd\"" \
        "${flth_host% 1 *}: a profile boots its exact exported kernel and initrd"
    check_contains "$(field config/$P.extra_qemu_args)" '"-append","root=UUID=profile-root ro console=ttyS0 systemd.mask=tmp.mount"' \
        "${flth_host% 1 *}: with the prepared disk's root and console"
done
FLTH_VM_BOOT_CMDLINE='root=/dev/vda1' evaluate linux-gnu x86_64 1 vagrant-qemu
check_contains "$(field error)" 'needs a kernel and initrd' "a command line alone cannot redirect a stock boot"
FLTH_VM_BOOT_KERNEL="$boot_kernel" FLTH_VM_BOOT_INITRD="$boot_initrd" \
    FLTH_VM_BOOT_CMDLINE=$'root=UUID=x\n-drive bad' evaluate linux-gnu x86_64 1 vagrant-qemu
check_contains "$(field error)" 'one printable line' "a multiline profile command line is refused"
refuse_boot_file() {
    # refuse_boot_file <var> <value>
    json=""
    eval "$1=\"\$2\" evaluate darwin23 arm64 0 vagrant-qemu-christhomas,vagrant-notify-forwarder-christhomas"
    check_contains "$(field error)" "$1" "$1=$(printf '%q' "$2") is refused"
}
refuse_boot_file FLTH_VM_BOOT_KERNEL "relative/vmlinuz"
refuse_boot_file FLTH_VM_BOOT_KERNEL "/tmp/vmlinuz
-drive file=/etc/shadow"
refuse_boot_file FLTH_VM_BOOT_INITRD "relative/initrd.img"
refuse_boot_file FLTH_VM_BOOT_INITRD "/tmp/initrd.img
-drive file=/etc/shadow"

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
refuse_env FLTH_VM_GUEST "ubuntu-24.04"
refuse_env FLTH_VM_GUEST "debian-12
config.vm.box = x"
refuse_env FLTH_VM_QMP "relative/qmp.sock"
refuse_env FLTH_VM_QMP "/tmp/qmp.sock,server=off"
refuse_env FLTH_VM_SLOTS "0"
refuse_env FLTH_VM_SLOTS "65"
refuse_env FLTH_VM_DISPOSABLE "yes"
refuse_env FLTH_VM_DISPOSABLE "1,file=/etc/shadow"
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
