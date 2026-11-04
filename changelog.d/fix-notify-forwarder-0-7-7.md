### Changed

- **The macOS setup installs `vagrant-notify-forwarder-christhomas` 0.7.7.** The
  harness still works with 0.7.5, and it declares no minimum: nothing here needs a
  newer plugin. A macOS guest still runs no forwarder receiver: notify-forwarder
  v1.2.1 no longer writes data to the files an event names, and the reasons the
  stand-in stays are recorded in `vagrant/Vagrantfile`.

### Fixed

- **`vm.sh down` and `vm.sh destroy` read the record plugin 0.7.7 writes.** A line
  with a pid and an identity was skipped and the record then removed, so the plugin
  had nothing left to stop.
- **A session ending on a guest that powered itself off stops its forwarders.** They
  ran until a later `down` or `destroy` of that machine with plugin 0.7.5, and for
  about 15 seconds with 0.7.7.
