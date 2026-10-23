### Fixed

- **`scripts/ci-setup-linux.sh`'s apt-get calls retry, time out and say what
  stalled (#77).** A stalled package mirror once held the QEMU step for 26
  minutes with nothing in the log, and cancelled the jobs that waited on it.
  Each call now:
  - passes apt `Acquire::Retries=3` and 30-second http and https timeouts;
  - is bounded by `FLTH_APT_TIMEOUT` (600 seconds by default);
  - prints a line before and after it runs;
  - fails naming what it was fetching.
