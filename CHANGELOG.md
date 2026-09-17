# Changelog

All notable changes to fs-linux-test-harness land here. The format
loosely follows Keep a Changelog; versions follow semver, with breaking
changes allowed in minor versions until 1.0.

## [Unreleased]

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
  nothing has to be copied to be read there.
- **`vm.sh guest-test` (`chore vm:guest-test`) and `[test] guest_command`**:
  run the consumer's suite INSIDE the guest, from `/repo`, streaming its
  output and propagating its exit status, then tear down under the same
  session rules as `vm:test`. That is how a host which cannot run a Linux
  suite (a Mac) runs one. The harness knows nothing about what the command
  is: the `[setup]` script installs whatever the guest needs — a compiler,
  an interpreter, anything — and `tests/generic.sh` now guards against a
  language or toolchain name leaking into harness code, as it already did
  for filesystems.
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
