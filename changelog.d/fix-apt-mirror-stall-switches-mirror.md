### Fixed

- **A stalled Ubuntu mirror no longer fails `ci-setup-linux.sh`.** After an
  apt-get attempt stalls, the next one points the runner's Ubuntu mirror at
  another (`archive.ubuntu.com`, then `mirrors.edge.kernel.org`, or
  `FLTH_APT_MIRRORS`), fetches its package index and tries again there;
  security updates keep their own host. A stall on every attempt names each
  mirror it tried, in order (#200).
