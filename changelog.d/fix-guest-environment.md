### Fixed

- A consumer whose setup was refused for installing a kernel the shared guest does not run is refused before that same setup runs on a later boot, instead of after it, and the message says the setup was not run again (#207).

### Documentation

- The README names the 2 TiB file limit of a guest root disk without `huge_file`, found on the macOS arm64 Debian 12 guest, and the supported workaround of a tmpfs mounted in the run's own namespace; `chore smoke` checks both (#219).
