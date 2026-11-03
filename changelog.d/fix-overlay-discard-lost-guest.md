### Fixed

- **A disposable overlay gives back what the guest deletes.** The drive takes
  `discard=unmap` on a disposable boot and the guest's root is remounted with
  `discard`, so a suite that writes and deletes no longer holds every block it
  ever touched on the host's disk.
- **A lost connection says what stopped the guest.** `vm.sh exec`, `run` and
  `guest-test`, and a setup script, keep ssh's exit 255 and print on stderr
  whether QEMU is running, its monitor's status, what is free on the host's disk
  holding the overlay, and the tail of the console. A guest paused on a full host
  disk used to end the call with no message at all.
