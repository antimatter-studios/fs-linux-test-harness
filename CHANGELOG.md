# Changelog

All notable changes to fs-linux-test-harness land here. The format
loosely follows Keep a Changelog; versions follow semver, with breaking
changes allowed in minor versions until 1.0.

## [Unreleased]

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
