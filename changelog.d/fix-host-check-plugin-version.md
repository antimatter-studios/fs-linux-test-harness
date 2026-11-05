### Changed

- **`chore host:check` and a boot on macOS refuse `vagrant-notify-forwarder-christhomas` older than 0.7.7.** Before that release a watcher outlives its VM with nothing left to end it, and they pile up on a host that boots VMs all day. Run `vagrant plugin update vagrant-notify-forwarder-christhomas`.
