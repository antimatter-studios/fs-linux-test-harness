### Added

- Limit guest test parallelism per consumer with `test_jobs` or `FLTH_TEST_JOBS`, using resource-profile defaults.
- Give guest runs a private disk-backed `TMPDIR` that is removed with the run.
- Prepare the guest disk with `tmp.mount` masked so `/tmp` is disk-backed on test boots.

### Changed

- Report shared guest kernel out-of-memory messages when a guest command fails.
