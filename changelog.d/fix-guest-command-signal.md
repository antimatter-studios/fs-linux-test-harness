### Fixed

- **A signal to a session stops the guest command it started.** When the VM stayed
  up (`FLTH_KEEP_VM=1`, a held VM, another live session), a command started through
  `vm.sh run` or `vm.sh exec` kept running in the guest after the host side had
  ended. It now gets TERM, then KILL after about five seconds, along with its
  descendants. Other calls in that guest are not touched.

### Changed

- **A command run through `vm.sh run` or `vm.sh exec` is run by `bash -c`.** Its
  whole text is parsed before any of it runs, so a syntax error on a later line now
  stops the lines before it from running. Its stdin is `/dev/null`.
