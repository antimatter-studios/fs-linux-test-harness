### Fixed

- Per-call VM liveness checks inspect QEMU process arguments instead of copying the entire process table when candidate discovery is available.
- The exec smoke check compares its timing against measured calls with SSH reuse disabled, rather than inferring reuse from a fixed limit alone.
