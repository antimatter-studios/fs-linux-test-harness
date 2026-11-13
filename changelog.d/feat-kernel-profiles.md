### Added

- Suites select a named run profile with `[vm] profile` or `FLTH_PROFILE`, sharing one hotplug-capable guest per resolved environment and using separate guests for different preparation requirements.
- Profiles pin the base guest and preparation script checksum, with optional exact kernel releases and required modules, architecture-specific overrides and a shared catalog through `FLTH_PROFILE_DIR`.
- Preparation-only run profiles keep the pinned box's kernel while isolating tools or system settings in separate VMs; manifests live in `run-profiles/` by default.
- Profile preparation persists the installed kernel and modules, exports exact boot artifacts, verifies their integrity and checks the running release and required modules before consumer admission; test boots remain disposable.

### Fixed

- Parallel VM boots retain the SSH port chosen by the harness's bind probe instead of falling back to an occupied port when Vagrant's connection-based collision probes report false positives.
