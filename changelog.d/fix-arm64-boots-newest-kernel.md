### Fixed

- **On macOS, the next boot runs the kernel a setup script installed (#80).**
  The macOS box starts QEMU on a kernel beside the box, with no bootloader, so
  the guest stayed on 6.1 and a module only the installed kernel provides could
  not load. A provisioning boot now copies the disk's newest kernel and initrd
  to `machines/<project>/boot/`, leaving out the box's Raspberry Pi kernels, and
  later boots run those. A setup that installs no kernel stays on the box's. A
  machine provisioned before this takes one extra boot, once. Linux hosts are
  unchanged.
- **On macOS, a process capturing the output of `vm.sh up` gets it back (#80).**
  The forwarder processes a boot starts kept Vagrant's stdout and stderr open,
  so a capture never saw end-of-file and hung with the guest up and idle.
  Vagrant now writes to `machines/<project>/vagrant-up.log`, shown on stderr as
  it grows.
