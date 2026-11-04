### Fixed

- An interrupted bare `vm.sh up` stops its boot and any unfinished guest before
  releasing the machine's boot lock. TERM, INT, and HUP sent to `up` alone are
  forwarded to its boot, so neither an orphaned boot nor a guest without its
  poweroff deadline is left behind.
