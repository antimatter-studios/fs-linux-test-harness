### Added

- Limit guest test parallelism per consumer with `test_jobs` or `FLTH_TEST_JOBS`, using resource-profile defaults.
- Give guest runs a private disk-backed `TMPDIR` that is removed with the run.

### Changed

- Report shared guest kernel out-of-memory messages when a guest command fails.
