### Fixed

- **A signal to a session no longer stops the daemons of a VM that stays up.**
  `vagrant up` runs in a process group of its own, so `virtiofsd` and
  `notify-forwarder` survive a signal to the command that booted the VM, and
  `/share` and `/repo` keep working in the guest. The regression came with
  v0.5.7. A signal or KILL during a boot still stops the boot and what it started.
- **`vm.sh down` and `vm.sh destroy` stop the forwarder's host watchers on macOS.**
  The provider's halt never ran the plugin's stop hook, so each boot left them
  running.
