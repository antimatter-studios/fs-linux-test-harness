### Added

- `FLTH_RESOURCE_PROFILE` selects a host resource profile, `high`, `medium` or `low`, which sets the shared guest's memory and CPUs and the guest's build jobs. Unset, the host picks one: `high` on macOS, `medium` on a Raspberry Pi, and `low` on GitHub Actions and other hosts. `FLTH_SHARED_MEMORY`, `FLTH_SHARED_CPUS` and the new `FLTH_BUILD_JOBS` still override it.
- Guest commands export `FLTH_BUILD_JOBS` beside `CARGO_BUILD_JOBS`, with the same value.

### Changed

- The shared guest's default memory and CPUs, and the guest's default build jobs, come from the resource profile: `high` keeps 8G and 8 CPUs and gives 8 build jobs, `medium` gives 4G, 2 CPUs and 2 jobs, and `low` gives 2G, 2 CPUs and 1 job. The previous defaults were 8G, 8 CPUs and 1 job on every host.
- `FLTH_SHARED_SLOTS` is not part of a profile: it stays 32 by default on every host.
- A host `CARGO_BUILD_JOBS` still overrides `[vm] build_jobs`; `FLTH_BUILD_JOBS` now overrides both.

### Removed

- `FLTH_PROFILE` and `FLTH_PROFILE_DIR` are renamed `FLTH_VM_PROFILE` and `FLTH_VM_PROFILE_DIR`. Setting an old name fails with a message naming the new one.
