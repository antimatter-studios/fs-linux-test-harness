### Added

- **A `[build]` section: a container on the host compiles, the guest tests what it
  compiled.** `chore vm:build` builds the consumer's Dockerfile for the guest's
  architecture, once per recipe, and runs `[build] command` in it with the
  repository and the named siblings mounted read-only. What the command writes to
  `/output` is `/share/build` in the guest. `chore vm:guest-test` runs the build
  first and boots no guest for a build that failed; the guest command finds the
  output as `FLTH_BUILD_DIR`. The guest needs no compiler, and a run on a
  workstation goes through the same two steps as a pipeline. Needs Docker on the
  host; there is no fallback to compiling in the guest.
