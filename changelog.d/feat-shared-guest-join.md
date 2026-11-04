### Added

- **Consumers join one shared guest, each with its own tree and setup.** With
  `FLTH_SHARED_ROOT` set to a host directory holding every tree that shares the
  guest, one boot serves them all. `/repo` and `/share` are still the paths a
  suite uses, and in each run they are that consumer's own tree and share. Each
  consumer's `[setup]` script runs when it first joins a boot, one at a time, and
  tools install alongside each other. A consumer's tests need no change. A tree
  outside that directory is refused.
