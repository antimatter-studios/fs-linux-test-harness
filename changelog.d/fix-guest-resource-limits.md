### Fixed
- VM destruction waits out transient Vagrant machine locks with bounded retries and preserves disk metadata when destruction fails.
- Every guest boot disables, stops and persistently masks automatic update services and timers, while preserving the package-manager lock wait and interrupted-transaction recovery.
- Guest setup, profile preparation, run, exec and guest-test commands default to one Cargo build job, reducing concurrent compiler memory pressure in small guests.
- Linux host memory admission honours FLTH_TEST_MEMINFO so consumer stub tests can supply deterministic memory without intercepting awk or depending on the runner's real free RAM.

### Added
- Consumers can set [vm] build_jobs or override it with host CARGO_BUILD_JOBS; the environment takes precedence and the effective value is exported per guest call.
