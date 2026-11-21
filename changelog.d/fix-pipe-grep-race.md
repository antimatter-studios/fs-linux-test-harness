### Fixed

- **A check that greps a command's output no longer fails because the line was
  there.** Under `pipefail`, `grep -q` stops reading at its first match, and a
  writer that writes again after that dies of SIGPIPE, so the pipeline failed
  only when it had matched. `host-tools.sh`, `ci-setup-linux.sh` and the
  Vagrant engine's device and status checks now let `grep` read all of its
  input (#286).
