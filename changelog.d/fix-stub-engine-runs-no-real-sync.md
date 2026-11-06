### Fixed

- **The stub engine runs no real `sync`, whatever `PATH` its caller set.** A
  consumer's script guards that copy `tests/stubs/engine.sh` set up their own
  `PATH`, so the stand-in 0.6.1 added for the harness's own tests never reached
  them, and every provisioning boot they drove flushed the host's disks. The
  engine now puts a `sync` that only logs first on the `PATH` of every guest
  script it runs, and records it in `calls` (#202).
