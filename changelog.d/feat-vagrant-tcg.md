### Added

- `FLTH_ACCELERATOR=tcg` boots the shared Vagrant guest with software emulation on x86_64 Linux and Apple Silicon.
- `FLTH_VM_MEM` and `FLTH_GUEST_MEM` configure the TCG translation cache cap and guest RAM for low-memory runs.
- `FLTH_BUILD_PREBUILT=1` makes `guest-test` test an existing build instead of running the [build] step, so a pipeline can build in one job and test in another.
- `FLTH_GUEST_ARCH=aarch64` with `FLTH_ACCELERATOR=tcg` boots an emulated ARM64 guest on x86_64 Linux.
- `FLTH_HOST_MEMORY_RESERVE_MIB` sets how much memory a guest boot leaves for the host (2048 MiB by default), and on Linux the free memory measured is capped by the cgroup's memory limit, so a CI runner pod is judged by its own limit.
