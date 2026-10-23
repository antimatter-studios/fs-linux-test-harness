### Fixed

- **`scripts/ci-setup-linux.sh`'s apt-get calls retry, time out and say what
  stalled (#77).** A stalled package mirror once held the QEMU step for 26
  minutes with nothing in the log, and cancelled the jobs that waited on it.
  Each call now:
  - passes apt `Acquire::Retries=3` and 30-second http and https timeouts;
  - bounds each attempt by `FLTH_APT_TIMEOUT` (240 seconds by default) and
    makes `FLTH_APT_ATTEMPTS` attempts (3), configuring dpkg before the next
    one, as a stall is one runner's and a fresh attempt usually finishes;
  - prints a line before each attempt and after it runs;
  - fails naming what it was fetching, with the tail of apt-get's output.
