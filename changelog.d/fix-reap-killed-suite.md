### Fixed

- **A reap of a shared guest copes with a killed suite on the list.** `vm.sh reap`
  exited 1 and kept the entry when a suite on the list had been killed outright.
  It now drops the entry and succeeds.
