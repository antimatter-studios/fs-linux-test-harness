### Added

- `FLTH_ACCELERATOR=tcg` boots the shared Vagrant guest with software emulation on every supported host, and the guest is then the same Debian cloud box everywhere.
- `FLTH_VM_MEM` and `FLTH_GUEST_MEM` configure the TCG translation cache cap and guest RAM for low-memory runs.
- `FLTH_BUILD_PREBUILT=1` makes `guest-test` test an existing build instead of running the [build] step, so a pipeline can build in one job and test in another.
- `FLTH_HOST_MEMORY_RESERVE_MIB` sets how much memory a guest boot leaves for the host (2048 MiB by default), and on Linux the free memory measured is capped by the cgroup's memory limit, so a CI runner pod is judged by its own limit.
- `FLTH_HOST_MEMORY_WAIT_SECONDS` lets a guest boot wait for memory to become free instead of being refused at once.
- `FLTH_GUEST_ARCH` (`x86_64` or `aarch64`) with `FLTH_ACCELERATOR=tcg` picks the emulated guest's architecture on any host, Apple Silicon included.
