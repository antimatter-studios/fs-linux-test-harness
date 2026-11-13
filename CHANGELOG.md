# Changelog

All notable changes to fs-linux-test-harness land here. The format
loosely follows Keep a Changelog; versions follow semver, with breaking
changes allowed in minor versions until 1.0.

Changes not yet released are fragments in [`changelog.d/`](changelog.d/), one per
pull request; a release gathers them into a section here.

## [Unreleased]

## v0.7.0 — 2026-11-13

### Added

- Suites select a named run profile with `[vm] profile` or `FLTH_PROFILE`, sharing one hotplug-capable guest per resolved environment and using separate guests for different preparation requirements.
- Profiles pin the base guest and preparation script checksum, with optional exact kernel releases and required modules, architecture-specific overrides and a shared catalog through `FLTH_PROFILE_DIR`.
- Preparation-only run profiles keep the pinned box's kernel while isolating tools or system settings in separate VMs; manifests live in `run-profiles/` by default.
- Profile preparation persists the installed kernel and modules, exports exact boot artifacts, verifies their integrity and checks the running release and required modules before consumer admission; test boots remain disposable.

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

### Fixed

- Parallel VM boots retain the SSH port chosen by the harness's bind probe instead of falling back to an occupied port when Vagrant's connection-based collision probes report false positives.

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

- **A session or an `up` on a macOS host no longer prints "child setpgid ...
  Operation not permitted".** The session's command, `up`'s boot and the
  escalation that follows a signal now make their process groups from the child
  alone, through Perl, instead of through Bash job control, whose two concurrent
  setpgid calls race on macOS (#209). Each still runs in a group of its own, and
  a signal still reaches it.

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

## v0.6.2 — 2026-11-06

### Fixed

- **A stalled Ubuntu mirror no longer fails `ci-setup-linux.sh`.** After an
  apt-get attempt stalls, the next one points the runner's Ubuntu mirror at
  another (`archive.ubuntu.com`, then `mirrors.edge.kernel.org`, or
  `FLTH_APT_MIRRORS`), fetches its package index and tries again there;
  security updates keep their own host. A stall on every attempt names each
  mirror it tried, in order (#200).

- **The stub engine runs no real `sync`, whatever `PATH` its caller set.** A
  consumer's script guards that copy `tests/stubs/engine.sh` set up their own
  `PATH`, so the stand-in 0.6.1 added for the harness's own tests never reached
  them, and every provisioning boot they drove flushed the host's disks. The
  engine now puts a `sync` that only logs first on the `PATH` of every guest
  script it runs, and records it in `calls` (#202).

## v0.6.1 — 2026-11-05

### Fixed

- **A consumer whose setup installs a kernel cannot join a shared guest and be told it succeeded.** A shared guest does not restart for one consumer's setup, so that consumer's kernel tests would have run on the kernel the guest booted. Its join now fails, naming the kernel it installed and the one running, and so do its later calls on that boot. Other consumers are not affected.

## v0.6.0 — 2026-11-05

### Added

- **A watchdog on the host ends a stuck guest and says why.** One runs for each guest, started and ended with it. It warns of low memory, low disk, a process making no progress in uninterruptible sleep, and an oops, soft lockup, hung task, RCU stall or panic on the guest's console, and shows the last of it in `vm.sh status`. A guest that stops answering, or a process stuck past its limit, ends the guest and frees the slot, and every suite on it ends with status 75 and a message naming the reason. `FLTH_WATCHDOG=off` starts none, and the limits are settings.

- **Consumers join one shared guest, each with its own tree and setup.** With
  `FLTH_SHARED_ROOT` set to a host directory holding every tree that shares the
  guest, one boot serves them all. `/repo` and `/share` are still the paths a
  suite uses, and in each run they are that consumer's own tree and share. Each
  consumer's `[setup]` script runs when it first joins a boot, one at a time, and
  tools install alongside each other. A consumer's tests need no change. A tree
  outside that directory is refused.

- **A consumer's build state lasts between runs on a shared guest.** `/var/cache` is
  the consumer's, on the guest's own disk, for as long as the guest runs, so a second
  run does not build from nothing. A second run of one consumer at the same time has
  its own empty one. What a killed suite held is free for the next run to register.

- **Each run on a shared guest has its own random root and mounts.** A session is
  a run. Its calls into the guest run in a private mount namespace, with
  directories under `/var/lib/fs-linux-test-harness/runs/<id>/` mounted at `/tmp`,
  `/var/tmp`, `/var/cache` and `/mnt`, and `FLTH_RUN_ROOT` naming the root.
  `guest-test` also copies the tree there and mounts it at `/repo`. The end of a
  run stops its commands, detaches the loop devices backed by its root and deletes
  it, and leaves every other run alone. A suite killed outright gets the same when
  it is dropped from the list.

- **`FLTH_SHARED_ROOT` puts a consumer's suites on one guest with other
  consumers'.** The machine is `machines/shared-<guest>/`, and its memory, CPUs
  and disk are `FLTH_SHARED_MEMORY` (8G), `FLTH_SHARED_CPUS` (8) and
  `FLTH_SHARED_DISK` (64G) rather than a consumer's `[vm]` section. A suite
  registers when its session begins and deregisters when it ends. The end of a
  session and a reap leave the guest running, a `down` stops it only when no
  suite is registered, and a suite killed outright is dropped from the list. A
  consumer that does not set it is unchanged.

### Changed

- **`chore host:check` and a boot on macOS refuse `vagrant-notify-forwarder-christhomas` older than 0.7.7.** Before that release a watcher outlives its VM with nothing left to end it, and they pile up on a host that boots VMs all day. Run `vagrant plugin update vagrant-notify-forwarder-christhomas`.

### Fixed

- A `[vm] deadline_minutes` of five or less no longer refuses the harness's first login after a boot, and a longer one no longer refuses a new connection in its last five minutes. The guest's sshd stops consulting `pam_nologin`, and the guest still powers off on schedule.
- The setup call re-arms the guest's poweroff as it starts and as it ends, as `run` and `exec` do.

- **A short `[vm] deadline_minutes` is not cut off by its own re-arm limit.** Re-arming is limited to once in a sixth of the deadline, and at most once a minute. A window of a whole minute at `deadline_minutes = 1` let a call find the stamp fresh with a second of the guest left.

- **A reap of a shared guest copes with a killed suite on the list.** `vm.sh reap`
  exited 1 and kept the entry when a suite on the list had been killed outright.
  It now drops the entry and succeeds.

- **A boot keeps its slot for as long as it is booting.** A lease is renewed
  while a boot attempt runs and again when one fails, so a waiter finds neither
  a long attempt with no VM yet nor the moment between two attempts abandoned,
  and the next attempt is not refused with `no memory reservation owns this boot`.

- **A join that disagrees with a shared guest's boot is refused.** A guest sees one
  `FLTH_SHARED_ROOT` and carries one version of its run tool, both fixed at boot. A
  consumer joining with another directory or harness version got a failed mount or
  a misread command. `up` now refuses it, saying which differs, and the guest stays up.

- **A call outside any session keeps a shared guest up.** A `vm.sh run` or `vm.sh exec`
  by hand was not on the list a shutdown request reads, so a `vm.sh down` stopped the
  guest under it. It is now listed for as long as it lasts.

- **A run on a shared guest frees what it held before deleting its root.** Deleting a
  large root took minutes, and a suite restarted during that got an empty `/var/cache`
  instead of the consumer's.

- **A run's copy of its tree on a shared guest keeps holes.** A copy filled every hole
  in a suite's images, taking one consumer's 3.5 GiB of fixtures to 38 GiB of the
  guest's disk.

## v0.5.9 — 2026-11-05

### Changed

- **A command run through `vm.sh run` or `vm.sh exec` is run by `bash -c`.** Its
  whole text is parsed before any of it runs, so a syntax error on a later line now
  stops the lines before it from running. Its stdin is `/dev/null`.

- **The macOS setup installs `vagrant-notify-forwarder-christhomas` 0.7.7.** The
  harness still works with 0.7.5, and it declares no minimum: nothing here needs a
  newer plugin. A macOS guest still runs no forwarder receiver: notify-forwarder
  v1.2.1 no longer writes data to the files an event names, and the reasons the
  stand-in stays are recorded in `vagrant/Vagrantfile`.

### Fixed

- **A box catalog outage is waited for and not blamed on the guest.** A box
  catalog or box download answering a 5xx, a 408, 425 or 429, or not answering
  at all, took the three boot attempts five seconds apart and ended saying the
  VM would not boot. `up` now waits for it over minutes, 30, 60 and then 120
  seconds between tries, for 15 minutes at most, and its failure names the
  catalog and what it answered. Any other boot failure keeps its retries.

- **A signal to a session stops the guest command it started.** When the VM stayed
  up (`FLTH_KEEP_VM=1`, a held VM, another live session), a command started through
  `vm.sh run` or `vm.sh exec` kept running in the guest after the host side had
  ended. It now gets TERM, then KILL after about five seconds, along with its
  descendants. Other calls in that guest are not touched.

- **`vm.sh down` and `vm.sh destroy` read the record plugin 0.7.7 writes.** A line
  with a pid and an identity was skipped and the record then removed, so the plugin
  had nothing left to stop.
- **A session ending on a guest that powered itself off stops its forwarders.** They
  ran until a later `down` or `destroy` of that machine with plugin 0.7.5, and for
  about 15 seconds with 0.7.7.

- A session signalled during a boot no longer leaves a guest running without `/share` and `/repo`. `FLTH_KEEP_VM=1`, a hold, another live session and another worktree still keep a VM whose boot finished. If such a guest is left by a boot with no session, `vm.sh up` and `vm.sh run` replace it, `vm.sh exec` refuses it, `vm.sh status` says so and `vm.sh reap` stops it.

- An interrupted bare `vm.sh up` stops its boot and any unfinished guest before
  releasing the machine's boot lock. TERM, INT, and HUP sent to `up` alone are
  forwarded to its boot, so neither an orphaned boot nor a guest without its
  poweroff deadline is left behind.

- A mounted-worktree record is trusted only for the VM boot that wrote it, so a boot by an older harness cannot leave a stale record that refuses legitimate commands or names the wrong mounted worktree.

## v0.5.8 — 2026-11-04

### Added

- **`vm.sh reload` (`chore vm:reload`) restarts a running VM in place and keeps
  its slot.** `vm-slot.sh renew` does the same for a consumer that runs its own
  `vagrant reload`, as `vm-slot.sh renew && vagrant reload`.

### Changed

- **A dead holder is reclaimed later.** A waiter now takes the slot of a holder
  past its boot grace only once its VM has been seen absent, with no gap, for
  `FLTH_SLOT_ABSENT_GRACE`, which defaults to the boot grace of 180 seconds.
  Until then the holder's memory is waited for.

### Fixed

- A memory-admission refusal stops `vm.sh up` before setup or any later guest work, whether the refused boot provisions the disk or runs it disposably, and releases the stopped machine’s slot and up lock.
- Failed preparation, provisioning, setup and guest-command construction steps propagate their status instead of continuing while the up wrapper captures failures.

- **A restart in place no longer loses a VM its slot.** An in-place reload of a
  VM past its boot grace looked like an abandoned holder, so a rival took the
  slot and the host ran more VMs than `FLTH_SLOT_COUNT`. A restart the harness
  is told about now keeps its slot. One it is not told about keeps it for the
  absence window only, and a VM down for longer can still return past the limit.
- **A provisioning boot keeps its slot between its stop and the next boot**,
  however long its setup script ran.

- **A signal to a session no longer stops the daemons of a VM that stays up.**
  `vagrant up` runs in a process group of its own, so `virtiofsd` and
  `notify-forwarder` survive a signal to the command that booted the VM, and
  `/share` and `/repo` keep working in the guest. The regression came with
  v0.5.7. A signal or KILL during a boot still stops the boot and what it started.
- **`vm.sh down` and `vm.sh destroy` stop the forwarder's host watchers on macOS.**
  The provider's halt never ran the plugin's stop hook, so each boot left them
  running.

## v0.5.7 — 2026-11-04

### Fixed

- **A dead holder no longer reserves pending memory.** Once its boot grace
  has expired and no VM is running for it, a holder's recorded reservation
  no longer blocks admission into a free lower slot. An unreadable process
  table still keeps the reservation counted.

- **An acquire waits beside a holder with no memory file.** A holder from a
  harness before v0.5.5 writes no reservation, and memory admission refused to
  start beside one during its boot grace. Admission and the check before each
  boot now wait until that holder settles or goes, and a holder past its grace
  with no VM reserves nothing. A reservation that is present but malformed is
  still refused.

- **A command from another worktree no longer joins a guest that has the first
  one mounted.** Every worktree of a project shares a machine, and its guest
  mounts the worktree that booted it. `up`, `run`, `exec`, `put`, `hold`,
  `provision` and what runs through them now fail naming both worktrees, a
  session or reap from another worktree leaves that VM running, and `status`
  names the worktree the guest has mounted.

- A signal to a command session, whether delivered to its process or its process group, reaches the command's process group before VM teardown. Processes remaining in that group receive SIGKILL after a five-second grace period, even if the command itself has already exited.
- Cancellation recorded before a session launches its command prevents that command from starting.

## v0.5.6 — 2026-11-03

### Fixed

- Unused QEMU shared-memory files and virtiofs socket pidfiles are reclaimed before and after VM start, halt, and destroy, including leftovers from an abrupt exit. Files in use or whose safety cannot be established are retained.

- **A disposable overlay gives back what the guest deletes.** The drive takes
  `discard=unmap` on a disposable boot and the guest's root is remounted with
  `discard`, so a suite that writes and deletes no longer holds every block it
  ever touched on the host's disk.
- **A lost connection says what stopped the guest.** `vm.sh exec`, `run` and
  `guest-test`, and a setup script, keep ssh's exit 255 and print on stderr
  whether QEMU is running, its monitor's status, what is free on the host's disk
  holding the overlay, and the tail of the console. A guest paused on a full host
  disk used to end the call with no message at all.

## v0.5.5 — 2026-11-03

### Added

- `FLTH_SLOT_COUNT` configures the machine-wide concurrent VM limit, defaulting to one, with named host-memory admission before every boot and reservations for other booting guests.

### Changed

- The default guest allocation is 2 GiB, selected from real consumer `guest-test` measurements at 2, 3 and 4 GiB.

### Fixed

- Lifecycle reapers stop only a VM booted by their own invocation, leaving another run's idle VM alone.
- A reboot renews its slot's boot grace and generation so a stale waiter cannot free the reservation inspected before the reboot.

- Per-call VM liveness checks inspect QEMU process arguments instead of copying the entire process table when candidate discovery is available.
- The exec smoke check compares its timing against measured calls with SSH reuse disabled, rather than inferring reuse from a fixed limit alone.

## v0.5.4 — 2026-11-03

### Changed

- The required VM-free CI tier runs on macOS arm64 as well as Linux.

### Fixed

- Session commands retain interrupt handling under macOS Bash 3.2, and sourced sessions report SIGINT as status 130 while still running teardown.
- VM-free checks support macOS system Bash and Ruby, use short socket scratch roots, and select a capable guest-script Bash explicitly without changing the host interpreter.

## v0.5.3 — 2026-11-03

### Changed

- The README and agent guide record the Apple Silicon smoke results from November 3, 2026, the tested tool versions, both successful direct-I/O checks, and the remaining intermittent exec cost failure.

### Fixed

- **On macOS, nothing in the guest writes to the shares (#84).** The forwarder
  plugin's guest receiver answered each host file event by opening the file
  read-write, writing its first byte back, and truncating a file it read as
  empty, so a file the host had just written could end up empty on the host. The
  plugin now gets a receiver that exits, on `/share` and `/repo` alike. `inotify`
  in a macOS guest no longer sees the host's changes to a share.

## v0.5.2 — 2026-11-03

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

- **On macOS, the next boot runs the kernel a setup script installed (#80).**
  The macOS box starts QEMU on a kernel beside the box, with no bootloader, so
  the guest stayed on 6.1 and a module only the installed kernel provides could
  not load. A provisioning boot now copies the disk's newest kernel and initrd
  to `machines/<project>/boot/`, leaving out the box's Raspberry Pi kernels, and
  later boots run those. A setup that installs no kernel stays on the box's. A
  machine provisioned before this takes one extra boot, once. Linux hosts are
  unchanged.
- **On macOS, a process capturing the output of `vm.sh up` gets it back (#80).**
  The forwarder processes a boot starts kept Vagrant's stdout and stderr open,
  so a capture never saw end-of-file and hung with the guest up and idle.
  Vagrant now writes to `machines/<project>/vagrant-up.log`, shown on stderr as
  it grows.

## v0.5.1 — 2026-10-13

### Fixed

- **The Debian 13 guest boots (#70).** On a Linux x86_64 host the QEMU
  provider passes `-vga none`, and the Debian 13 box's GRUB then resets the
  machine before its kernel prints anything, over and over, until every
  boot attempt times out. The VM now gets a standard VGA (`-vga std`) it
  never displays; its console is still the serial port. The smoke job
  boots every pinned guest, Debian 12 and Debian 13, so a guest that
  cannot boot fails there before a release names it.

## v0.5.0 — 2026-10-13

### Added

- **A consumer chooses its guest: `[vm] guest = "debian-12"` or
  `"debian-13"`.** Debian 12 stays every consumer's default, so nothing
  changes for one that does not name it. Debian 13 boots kernel 6.12 with
  xfsprogs 6.13, for what 6.1 cannot do: mounting a volume with parent
  pointers or exchange-range. The harness pins both boxes and their
  versions in the Vagrantfile, and `ci-setup-linux.sh` keys its box cache
  on the consumer's guest (or `FLTH_VM_GUEST`), so a runner never restores
  one guest's box for another. A Mac has no Debian 13 box, and says so.

## v0.4.1 — 2026-10-09

### Changed

- **The agents-core check runs in place from rust-fs-core.** The copy in
  `scripts/agents-core-check.sh` is gone; `tests/agents-core.sh` runs
  `../rust-fs-core/scripts/agents-core-check.sh`, which `chore siblings`
  checks out at `FS_CORE_REF` (rust-fs-core 0.3.3, #212).

### Fixed

- **A guest that fails to boot shows its console** (#61). The QEMU
  provider sends the guest's serial console to a Unix socket nothing
  reads, so a boot that never answered SSH ended, ten minutes later, with
  Vagrant's "Timed out while waiting for the machine to boot" and no way
  to tell a kernel panic from a hung boot from a dead network. The
  Vagrantfile now has QEMU log that console (`-set
  chardev.ser0.logfile=`, which keeps the provider's socket) to
  `console.log` in the machine directory, afresh on every boot and on
  every host, and `up` prints its last 60 lines, each labelled
  `[console]`, to stderr after every failed boot attempt. The engine
  interface gains `engine_console_log`, which names the file.
- **A transient HTTP 5xx from the chore release download no longer fails a CI
  job.** The install-chore action retries both downloads up to five times on
  any error; the checksum check still guards what was fetched.

## v0.4.0 — 2026-10-05

### Fixed

- **A boot takes the configured SSH port only when it is free** (#49).
  The forward always used `[vm] ssh_port` (default 50122), which sits
  inside Linux's ephemeral port range, so any outgoing connection on the
  host could be holding it; QEMU then refused the forward, and every retry
  failed on the same port. Each boot attempt now binds the configured port
  first and, when another socket holds it, forwards a free port the kernel
  hands out instead, and says which. Perl does the binding, and
  `host-tools.sh` now requires it.
- **A VM whose graceful halt does not stop it is forced down** (#51).
  `vm down` gave up as soon as a graceful halt left the guest running,
  which failed a whole green test tier on a long run's slow shutdown. It
  now forces the VM down once and judges the state after that. A VM still
  running after the forced halt, or a state that cannot be read, still
  fails down and keeps the slot.
- **Concurrent ups of one machine wait for the boot under way** (#53).
  A consumer that runs its oracle tests in parallel calls `up` from
  several threads at once. While the first boot was under way, every later
  caller saw a VM that was not running and booted it too. Each boot then
  failed on the same forwarded port. `up` now takes a per-machine lock
  around the decision to boot and reads the state afresh once it holds
  the lock. The lock is released as soon as `up` finishes, so parallel
  runs on a running VM do not queue.

### Added

- **A consumer can declare a cache that outlives every boot** (#39).
  Since v0.3.0 every boot that runs anything is disposable, which also
  threw away the in-guest build directories and toolchain homes consumers
  keep on the guest's own disk, so every local in-guest run rebuilt from
  nothing. A `[cache] size = "16G"` section now gives the guest a disk of
  its own at `/cache`, kept across `vm:down` and every disposable boot.
  It is a sparse raw image in the machine directory, attached through
  `extra_qemu_args` rather than as a provider disk, because the provider
  applies `snapshot=on` to every disk it attaches. The guest finds it by
  serial and gives it its root's filesystem on first boot, through
  `systemd-makefs`, which leaves a disk that already has one alone. A
  changed size replaces it with an empty one, and `vm:destroy` deletes
  it. Nothing outside `/cache` survives a run, and a consumer with no
  `[cache]` section has no `/cache`. `tests/smoke.sh` proves both on a
  real VM.

## v0.3.0 — 2026-10-03

### Added

- **A `macos-host` workflow runs the macOS host setup on a real Apple
  Silicon runner** (#8). On `macos-15` it installs Vagrant, the tap's QEMU
  and virtiofsd and the two forked plugins as the README says, checks QEMU
  has `vhost-user-fs`, checks `host:check` names the unpublished box and
  nothing else, and runs `vagrant validate` on the Vagrantfile under the
  real forked provider. It cannot boot: hosted macOS runners have no nested
  virtualisation, so no HVF. It records whether the runner can start an HVF
  guest. It runs when the Vagrantfile, `host-tools.sh` or the Vagrant
  engine changes, and is not part of `ci-ok`.

- **`vm.sh session <command...>` runs a command inside a session** (#37).
  A consumer's test process boots the VM itself from its first guest call,
  and the README told consumers to leave stopping it to chore's `after_all`
  reaper. The reaper runs only inside a chore invocation of that consumer,
  but the slot is one for the whole machine, so a tier run any other way
  (the consumer's `scripts/test.sh`, `cargo test` by hand) exited with the
  VM idle and the slot held, and every other repository's VM work queued
  behind it until the guest's idle deadline. Run through `vm.sh session`
  (or `chore vm:session -- <command>`), the VM comes down and the slot is
  released when the command ends, passed, failed or killed. A TERM, INT or HUP sent to the runner is passed on to the
  command, and the VM is brought down only once the command has finished
  with it. In the guest (`FLTH_GUEST=1`) and on a host that fails
  `host-tools.sh --quiet`, the command runs as it is and the engine is asked
  nothing. `vm-session.sh` is where it lives; `vm.sh session` is the public
  spelling because a harness older than this answers it with "unknown
  command" rather than running nothing. Each consumer's runner becomes a
  one-line change, and the copy rust-fs-btrfs carried can go.

### Changed

- **The test runner owns the VM its tests boot** (#37). README rule 2 of
  "Talking to the guest from a test process", and the quickstart's and
  `examples/minimal`'s `test` task, now run the suite through
  `vm.sh session <command...>`; the reaper is the net, not the plan.

- **The macOS path needs virtiofsd 1.14.0 or newer, and `vm:host:check`
  says so** (#26). Older builds of the macOS port read an arm64 guest's
  open flags with x86_64's values, so the guest's `O_DIRECT` became
  `O_DIRECTORY` and every direct-I/O open of a file on a share failed with
  `ENOTDIR`. christhomas/virtiofsd v1.14.0 decodes them with the guest's
  own values. `scripts/host-tools.sh` reads the installed formula's
  version and, below 1.14.0, names the floor, the reason and
  `brew upgrade antimatter-studios/tap/virtiofsd`. A Mac with an older
  build must upgrade before it boots the guest.

- **A run's writes are gone when its boot stops** (#32). The machine's
  disk was long-lived and took every write, so a mount, a loop device or a
  half-finished install one run left behind surfaced as the next run's
  failure (#31 is one instance). Every boot that runs anything is now
  disposable: QEMU opens the disk read-only (`snapshot=on`) and writes to
  an overlay it discards when the VM stops, however it stops. Only a
  provisioning boot writes the disk — `up` applies a setup script the disk
  does not carry yet on a boot whose writes are kept, stops it, confirms
  the stop, and then boots the disposable machine that runs things.
  `chore vm:provision` does the same on demand, and refuses while another
  invocation is using the VM. **Consumers who keep a build directory or a
  package cache on the guest's own disk lose it at every boot**: what
  every run needs belongs in the setup script, and what should outlive a
  run on the share or in the repository mount. A changed setup script
  costs one extra boot. An existing machine takes one provisioning boot
  the first time this version boots it.

### Fixed

- **The macOS share's two unexplained virtiofsd settings are explained or
  gone** (#32). The Vagrantfile preferred `/opt/homebrew/bin/virtiofsd-1.13.8-rc1`
  when it existed, with no reason recorded. The macOS port of virtiofsd publishes
  no rc1, and v1.13.8 was released on 2026-06-22, so that path
  named a binary found on one Mac and ignored everywhere else. The
  preference is removed, and every Mac uses the tap's released
  `virtiofsd`. `--thread-pool-size=1` stays, and now says why: the port
  switches to the guest's credentials with `seteuid`/`setegid`, which are
  process-wide on macOS, so with two threads one request can run under
  the credentials another has just set.

- **A session's end leaves a held VM running** (#36). `vm.sh session-end`,
  run when every session ends, brought the VM down whenever no other
  session was using it, and cleared the hold on the way: a person who ran
  `chore vm:up` to keep the VM up across runs lost it as soon as any
  session on the machine ended, though the reaper had left it alone. A held
  VM now stays up when a session ends, with its slot, saying so as `reap`
  does; `vm:down` and `vm:destroy` still stop it.

- **A session whose work never booted the VM ends on a process check.**
  `vm.sh session-end` ran a full `down` whenever no other session was
  using the machine, so a test tier that needed no VM paid a `vagrant
  halt` and `vagrant status` on a machine that was not running. With no VM
  process running it now releases the slot if this machine holds it and
  asks the engine nothing else; an unreadable process table still takes
  the full `down`.

- **A setup interrupted mid-install no longer breaks every later boot**
  (#31). The VM outlives `vm.sh down`, so a setup script stopped part way
  through an install left dpkg mid-transaction, and every later install in
  the guest refused with "dpkg was interrupted" until someone fixed it by
  hand; one consumer carried its own recovery and the others had none.
  `vagrant/guest/apt-ready.sh` now runs `dpkg --configure -a`,
  noninteractive, once the package manager's locks are free and before the
  setup script. A transaction dpkg cannot finish fails the boot, naming the
  command and showing dpkg's output. Consumers can drop their own copies.

- **The smoke consumer no longer points its image tools at the share**
  (#26). It built, read and checked its image in `/share/results`, and
  it is the fixture a consumer copies. On the macOS engine an `O_DIRECT`
  open of a file on either virtiofs share fails with `ENOTDIR` — the host's
  virtiofsd decodes an arm64 guest's open flags with x86_64 values
  (christhomas/virtiofsd#3) — so a consumer modelled on it passed CI and
  failed on a Mac, with a failure that read as a verdict on the image. It
  now works in a guest-local `/var/tmp` scratch directory and copies only
  the finished artefacts back; `tests/guest-scratch.sh` fails the build if
  any of its guest-side scripts points an image tool at a shared path. The
  README's new "Where a tool works on an image" states the rule, and
  `chore smoke` opens a file on each share with `O_DIRECT`, so it fails on
  a Mac until the tap ships a fixed virtiofsd. **The `O_DIRECT` failure itself
  is not fixed here**; it is in the host's virtiofsd.

- **`host:check` no longer prints a box URL that answers 404** (#8). It
  told a Mac without the box to `vagrant box add` it from its GitHub
  release, but that release is in a private repository and the URL answers
  404 to Vagrant. It now says the box is not published and prints the
  command that adds a copy by hand, with `--architecture arm64`.

- **The README names the release it describes** (#27). Its badge said
  "status: unreleased" through v0.1.0 and v0.2.0, and named no version, so
  the release step that fixes the README's old version had nothing to find.
  The badge now reads `release: v0.2.0`, and `tests/readme-version.sh` fails
  unless the badge and every harness version the README names match the
  newest `## vX.Y.Z` heading here.

## v0.2.0 — 2026-09-30

### Fixed

- **The guest deadline measures idleness, not lifetime** (#7). It was armed
  once, at boot, so `deadline_minutes` capped the whole boot and a suite
  longer than it lost its VM mid-run; consumers raised it to a guess at
  their longest run, which left a leaked VM alive for hours. Every `vm.sh
  run` and `vm.sh exec` now re-arms the guest's poweroff as the call starts
  and as it ends, at most once a minute, and never while the guest is held.
  A single call longer than the deadline is still cut off: that is the hang
  it exists to catch.

- **A deep `TMPDIR` no longer stops the macOS VM booting** (#14). The
  macOS QEMU provider creates each virtiofs socket under `TMPDIR`, which was
  inherited from the caller — a consumer's scratch directory inside its
  checkout — and a socket path over the ~104-byte limit left the VM unable
  to boot. `vagrant up` now runs with `TMPDIR=$FLTH_STATE_DIR/tmp` (mode
  0700, beside the slot and the ssh control socket), and on macOS a boot is
  refused, naming the path and its length, if even that is too long.

- **A setup script can install packages on the macOS box** (#15). The box
  `christhomas/vagrant-rpi-bookworm-arm64` runs Raspberry Pi OS's first-boot
  dialog, `userconfig.service`, which waits for a keyboard and holds the dpkg
  lock, so a consumer's `apt-get` failed. A new provisioner,
  `vagrant/guest/apt-ready.sh`, runs first on every boot on every host: it
  disables, stops and masks that service where it exists, then waits up to
  300 s for the package manager's locks and fails the boot, naming the lock
  and the process holding it (read from `/proc/locks` and confirmed by the
  open file), if they are still held.

- **The reaper no longer stops a VM a running session is using** (#10).
  `vm-session.sh` kept the VM up without a hold, so a forty-minute fixture
  build's VM looked like a leak, and any other chore invocation's
  `lifecycle: after_all` reap stopped it mid-build. A session now leaves a
  marker (pid and process start time) under the machine directory; `reap`
  leaves the VM running while any marker's process is alive and says which,
  and removes markers whose process is gone. A session that ends while
  another is using the same machine leaves the VM to it.

- **A Mac without the box is told so before booting** (#8). The macOS box
  `christhomas/vagrant-rpi-bookworm-arm64` is not in the public Vagrant
  registry. `host-tools.sh` (and so `chore vm:host:check` and every boot) now
  reports it missing, with the `vagrant box add` command for its GitHub
  release, instead of Vagrant failing on a 404. The README says plainly that
  the macOS path has never been booted.

### Removed

- **`scripts/output-budget.sh` and `tests/output-budget.sh`.** The wrapper
  was written here, and the whole filesystem-driver family copied it: three
  divergent copies reached four different ways, each repository internally
  consistent and nothing comparing them
  (antimatter-studios/rust-fs-core#153). There is one copy now, in
  `antimatter-studios/rust-fs-core`, and consumers resolve it at run time
  rather than committing one of their own.

  This harness never used the wrapper for any task of its own — `chore
  check` runs `tests/run.sh` directly — so the copy here was purely a
  service to consumers, and every consumer has moved. The fix made to it in
  #12, where a failing tier prints the verdict and the log path instead of
  forty lines of tail, went into core as
  antimatter-studios/rust-fs-core#164 and shipped in `am-fs-core` v0.2.13,
  so nothing is lost by moving off this copy.

  The README still carries the policy, because the policy is the harness's
  business: a task prints a verdict, keeps the log, and a budget nobody can
  breach measures nothing. What it no longer carries is the script.

  The variables in the canonical wrapper are `OUTPUT_BUDGET_VERBOSE` and
  `OUTPUT_BUDGET_FAIL_TAIL`, not `FLTH_VERBOSE` and `FLTH_FAIL_TAIL`. That
  rename fails silently — the old name is simply not read and the run stays
  quiet — so core reports a superseded `FLTH_*` name on stderr rather than
  ignoring it.

## v0.1.0 — 2026-09-18

First release. rust-fs-ext4 is the first consumer and pins this tag; the
other filesystem repositories follow the same contract.

### Added

- **`vm.sh exec` (`chore vm:exec`)**: run a command in a guest that is
  ALREADY up, and never boot one. The per-call path for a test process:
  a process-table check and nothing else, so a suite can ask the guest
  hundreds of questions without a boot appearing in the middle of a test.
  When the VM is down it fails naming `chore vm:up`.
- **One SSH connection, reused.** The engine opens a master deliberately
  (`-M -N -f`, its own streams, socket under `FLTH_STATE_DIR`, closed
  before a boot and after a stop) and every later command rides it: about
  0.03 s per command against 0.7 s for a fresh handshake, measured on an
  arm64 KVM host. `FLTH_SSH_PERSIST` sets how long it stays open when
  idle.
- **The consumer repository is mounted in the guest at `/repo`**,
  read-write, on every boot (9p on Linux, virtiofs on macOS). A file a
  test wrote under the checkout is already visible in the guest, so
  nothing has to be copied to be read there. The repository mount uses
  `security_model=none` where the share uses `mapped-xattr`: the guest
  must see the host's real extended attributes, because a tool walking
  the tree is otherwise told an attribute exists and then that there is
  no data for it (POSIX ACLs on the checkout did exactly that to a
  filesystem builder copying a directory into an image).
- **`vm.sh guest-test` (`chore vm:guest-test`) and `[test] guest_command`**:
  run the consumer's suite INSIDE the guest, from `/repo`, streaming its
  output and propagating its exit status, then tear down under the same
  session rules as `vm:test`. That is how a host which cannot run a Linux
  suite (a Mac) runs one. The harness knows nothing about what the command
  is: the `[setup]` script installs whatever the guest needs — a compiler,
  an interpreter, anything — and `tests/generic.sh` now guards against a
  language or toolchain name leaking into harness code, as it already did
  for filesystems.
- **A guest that goes away fails the call instead of holding it.** The
  SSH client keeps the connection alive (`ServerAliveInterval=15`,
  `ServerAliveCountMax=8`): a VM halted by its own poweroff deadline, by
  a `destroy` or by a host running out of memory used to leave every
  command it was serving waiting for ever. Found the hard way — a suite
  sat for forty-eight minutes on two calls whose VM had powered off half
  an hour earlier.
- **`FLTH_GUEST=1`** in every command the harness runs in the guest, so a
  program can tell it is already inside the test VM rather than asking the
  harness to put it there.
- **README**: the "Consumer test contract" rewritten around where things
  run — the oracle tools in the guest ALWAYS (one version, one platform,
  no e2fsprogs on anybody's laptop), the kernel oracles in the guest, and
  the suite itself in the guest on a host that is not Linux — plus how a
  test process should talk to the guest (`exec`, one boot, no copying,
  batch the questions).

- **`scripts/ci-setup-linux.sh`**: sets a hosted x86_64 Linux runner up to
  boot the VM (KVM access, QEMU, Vagrant, vagrant-qemu, pinned), for the
  harness's CI and every consumer's; `--box-cache-key` (and the
  `box-cache-key` step output) keys the Vagrant box cache on the pinned box.
  Replaces `.github/actions/install-vagrant-qemu`.
- **README "Consumer test contract"**: the task names (`siblings`, `tools`,
  `fixtures`, `test:unit`, `test:oracle`, `test`, `vm:*`), never-skip, the
  host/VM split, and the CI shape with its `ci-ok` gate, as rust-fs-ext4
  runs them.
- **The harness.** `scripts/vm.sh` (up, run, put, share, provision, test,
  down, status, hold, reap, destroy, config), `scripts/vm-slot.sh` (the
  machine-wide slot lock), `scripts/vm-session.sh` (teardown on exit),
  `scripts/host-tools.sh` (host check with exact install commands).
  Extracted and reconciled from the copies in rust-fs-ext4, rust-fs-xfs
  and rust-fs-btrfs, with everything filesystem-specific removed.
- **Consumer config** `fs-linux-test-harness.toml`: `[project] name`,
  `[setup] script`, `[test] command`, `[share] dir`, `[vm] memory / cpus /
  disk / ssh_port / deadline_minutes`. Strict: unknown keys, duplicates,
  wrong types and paths leaving the repository are errors.
- **Consumer setup hook**: the consumer's script runs as root inside the
  VM, re-applied only when it changes.
- **Engine interface** (`scripts/lib/engine.sh`) with a Vagrant + QEMU
  implementation. Hosts: macOS arm64 (HVF, the owner's forked plugins,
  virtiofs), Linux aarch64 and Linux x86_64 (KVM, stock `vagrant-qemu`
  0.6.3, 9p). No software-emulation fallback.
- **Chore tasks**: `vm.chores.yml` for consumers (included as `vm`);
  `chores.yml` with `check`, `smoke`, `smoke:destroy`, `host:check`.
- **Self-tests**: VM-free unit tests (`chore check`) and a real-VM
  end-to-end test (`chore smoke`) driving `tests/smoke-consumer`, including
  a suite that must fail.
- **CI**: `unit`, `smoke-x86_64` (real VM under KVM on a hosted runner),
  and the aggregate required check `ci-ok`.

### Changed, relative to the per-repository copies

- The slot lock never breaks a live holder on age alone (the xfs and
  btrfs copies still did), validates holder records (four fields, numeric
  epoch), deletes only the generation it inspected, and keeps a displaced
  record as an orphan.
- The slot is released only on a confirmed stop: an unreadable VM state
  keeps it (every copy released on an unreadable `vagrant status`).
- Liveness matches the QEMU process by name and the machine path followed
  by `/`, so a shell mentioning the path, or a sibling path with the same
  prefix, is not taken for a running VM. An unreadable process table is
  not a dead holder.
- `run` uses plain `ssh` with Vagrant's cached settings, and a running VM
  is recognised from the process table, instead of a `vagrant` call each.
- New names throughout (`FLTH_*` environment, state under
  `~/.local/state/fs-linux-test-harness`, guest hold marker
  `/run/fs-linux-test-harness-held`). No aliases for the old ones.
