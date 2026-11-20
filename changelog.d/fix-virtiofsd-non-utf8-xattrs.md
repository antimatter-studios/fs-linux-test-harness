### Added

- **`.github/actions/install-virtiofsd` installs upstream virtiofsd for Linux CI.**
  It downloads upstream's static x86_64 build of 1.14.0, checks the zip and the
  binary against SHA-256 hashes committed in the action, keeps the verified zip
  in `actions/cache`, and exports the binary as `FLTH_VIRTIOFSD` (#274).

### Changed

- **Linux needs upstream virtiofsd 1.14.0 or newer.** `chore vm:host:check`
  refuses an older one, naming the one it found and where to get a newer one.
  `scripts/ci-setup-linux.sh` no longer installs the distribution's virtiofsd,
  and its host check fails without one. A consumer's Linux CI must run
  `antimatter-studios/fs-linux-test-harness/.github/actions/install-virtiofsd@<tag>`
  before `ci-setup-linux.sh` (#274).

### Fixed

- **A non-UTF-8 extended attribute name on `/repo` no longer hangs a Linux run.**
  Every upstream virtiofsd before 1.14.0, including Ubuntu 24.04's 1.10.0, panics in
  `setxattr` on such a name, so the guest's call never returns. With 1.14.0 the
  name sets and reads back by its bytes. On macOS, APFS refuses it with `EINVAL` at
  once (#274).
