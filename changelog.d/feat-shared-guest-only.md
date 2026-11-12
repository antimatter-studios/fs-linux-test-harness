### Added

- **Each run attaches its own tree to the running shared guest, and detaches it
  when it ends (#222).** A run's tree is a `vhost-user-fs` device served by a
  virtiofsd of its own, hot-plugged through QMP into one of `FLTH_SHARED_SLOTS`
  (32) free PCIe root ports the guest boots with, and mounted at `/repo` in the
  run's namespace; `/share` is the `[share] dir` in it. A tree anywhere on the host
  can be tested, a worktree on another volume or under `/tmp` included. A session's
  run is attached at its first call and detached when it ends; a call outside any
  session keeps its worktree's run attached while the guest runs; `vm.sh reap`
  detaches the device of a run whose session died. The device is always removed
  before its daemon is stopped, after the run's processes, loop devices and
  namespace are gone, because a daemon that goes while the guest can use its mount
  wedges hot-plug for the whole guest. A daemon that has gone anyway is found by the
  watchdog and by the run's next call: its device is removed first, and the run's
  suites end with status 75. `vm.sh config` reports `qmp=`, `run.standing=` and
  `slots=`.

### Changed

- **Breaking: every consumer uses the shared guest, and nothing has to be set for
  it (#220).** The guest that `FLTH_SHARED_ROOT` used to opt into is now the only
  one: one machine per guest release, `machines/shared-<guest>/`, shared by every
  consumer and every worktree on the host. A shell without the variable no longer
  gets a VM of its own with one worktree mounted, which refused every other
  worktree of the same consumer and waited on the slot.
- **Breaking: the guest shares no host directory at boot (#222).** Linux hosts
  move from 9p to virtiofs, on q35 on x86_64, and need the distribution's
  `virtiofsd` (`apt-get install virtiofsd`; `FLTH_VIRTIOFSD` names another), which
  `chore vm:host:check` and `scripts/ci-setup-linux.sh` now cover. The Vagrantfile
  boots every host with the root ports, a shared memory backend and a QMP socket.
- **A session's end, `vm:test` and `vm:guest-test` leave the guest up** for the
  next run; they end their own run. `chore vm:down` stops the guest when nobody is
  using it, and its idle deadline (`FLTH_SHARED_DEADLINE`, 480 minutes by default)
  stops it when nobody asks. `vm.sh reap` stops only a boot that did not finish.
- **A consumer's `[vm] memory`, `cpus`, `disk`, `ssh_port` and `deadline_minutes`
  are read and not used.** The shared guest's are the host's:
  `FLTH_SHARED_MEMORY`, `FLTH_SHARED_CPUS`, `FLTH_SHARED_DISK` and the new
  `FLTH_SHARED_DEADLINE`.
- **The host's memory is checked before every boot attempt**, as the slot did:
  the guest's memory plus 2048 MiB for the host must be available, or the boot is
  refused naming the numbers.
- **A setup that installs a kernel cannot be run anywhere now.** The shared guest
  refuses that consumer's join, naming both kernels, and there is no guest of its
  own to send it to (#157, #207).
- **The stub engine (`tests/stubs/engine.sh`) runs no real mount tool, and records
  a run's tree as attached.** Every boot now prepares the shared guest, and the
  engine puts logging stand-ins for `mount`, `umount`, `mountpoint`, `unshare`,
  `nsenter`, `losetup`, `flock`, `systemctl` and `tar` first on the `PATH` of every
  guest script it runs, as it does for `sync`, unless the test put its own in the
  stub's `bin`. It logs `attach <run> <tree>` and `detach <run>`.

### Fixed

- **`ci-setup-linux.sh` no longer installs from an index that did not all download
  (#218).** `apt-get update` exits 0 having ignored index files it could not fetch,
  and every install from those lists then found no QEMU. An update that says so is
  now treated like a stall and moves to the next mirror, and an install first asks
  `apt-cache policy` for a candidate for each package, fetching the next mirror's
  index when one has none.
- **A guest that powers itself off is reported as powered off (#205).** A QEMU that
  exited between `pgrep` finding it and `ps` reading it was read as "the process table
  could not be read", so the console that said why was never consulted.
- **A run process that no signal ends no longer holds up the end of its run (#187).**
  It is named, with its state and where in the kernel it waits, the run's
  `/var/cache` is freed and its root deleted without it, and each step of the end that
  could wait on it is bounded.
- **A suite is told when the shared guest's kernel has oopsed (#196)**: as it joins
  (`vm.sh up`) and as its session ends, naming the first oops and the process it hit,
  from this boot's console.
- **A suite joining a guest with little memory left is told so (#185)**, with the
  guest's available and total memory and the suites using it, below
  `FLTH_SHARED_MIN_AVAILABLE` (2048 MiB). The README sizes the guest from the
  measured numbers in #185.

### Removed

- **Breaking: the private per-consumer VM and the machine-wide slot.**
  `scripts/vm-slot.sh`, the `vm:slot:status` and `vm:slot:release-force` tasks,
  `FLTH_SLOT_WAIT`, `FLTH_SLOT_COUNT`, `FLTH_SLOT_BOOT_GRACE`,
  `FLTH_SLOT_ABSENT_GRACE` and `FLTH_SLOT_RENEW_SECS` are gone, and so are the
  provisioning boot, the per-worktree record (`mounted-worktree`) and the
  `disk.setup=` and `slot=` lines of `vm.sh config`.
- **Breaking: `FLTH_SHARED_ROOT`.** It is not read: each run attaches its own tree,
  so there is no host directory for the guest to see, and no tree is refused for
  where it is.
- **`FLTH_KEEP_VM`.** The guest stays up after every run, so there is nothing for
  it to keep.
- `vagrant/guest/mount-share.sh`, which mounted the boot-time 9p shares.

### Migrating

- Remove any `vm:slot:*` task, `vm-slot.sh` call (`vm-slot.sh renew` before a
  `vagrant reload` included: use `chore vm:reload`) and `FLTH_SLOT_*`,
  `FLTH_KEEP_VM` or `FLTH_SHARED_ROOT` setting. Nothing replaces them.
- Install `virtiofsd` on a Linux host and CI runner; a consumer whose CI runs
  `../fs-linux-test-harness/scripts/ci-setup-linux.sh` gets it from there.
- A consumer's `[vm]` sizes and deadline may be dropped from its config; set
  `FLTH_SHARED_MEMORY`, `FLTH_SHARED_CPUS`, `FLTH_SHARED_DISK`,
  `FLTH_SHARED_DEADLINE` or `FLTH_SHARED_SLOTS` on a host that needs other values.
- A script guard that drives `tests/stubs/engine.sh` now sees every boot prepare
  the shared guest through the engine's own mount stand-ins, and every run attach
  its tree; a declared `[cache]` is a directory of the guest's that goes with the
  boot (#186).
