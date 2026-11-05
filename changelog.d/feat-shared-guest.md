### Added

- **`FLTH_SHARED_ROOT` puts a consumer's suites on one guest with other
  consumers'.** The machine is `machines/shared-<guest>/`, and its memory, CPUs
  and disk are `FLTH_SHARED_MEMORY` (8G), `FLTH_SHARED_CPUS` (8) and
  `FLTH_SHARED_DISK` (64G) rather than a consumer's `[vm]` section. A suite
  registers when its session begins and deregisters when it ends. The end of a
  session and a reap leave the guest running, a `down` stops it only when no
  suite is registered, and a suite killed outright is dropped from the list. A
  consumer that does not set it is unchanged.
