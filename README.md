# fs-linux-test-harness

> Reusable Linux-VM test harness for filesystem driver projects. Provides the environment (VM lifecycle, cross-repo slot lock, shared directory, command execution); each driver repo supplies its own tests and installs its own tooling.

[![CI](https://github.com/antimatter-studios/fs-linux-test-harness/actions/workflows/ci.yml/badge.svg)](https://github.com/antimatter-studios/fs-linux-test-harness/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Status: unreleased](https://img.shields.io/badge/status-unreleased-yellow.svg)](./CHANGELOG.md)

## What is this

A filesystem driver is only as trustworthy as the thing it is checked
against. For a Linux filesystem that is the real kernel and the real
tools (`mkfs`, `fsck`, the in-kernel driver), which a Mac cannot run and
a Linux laptop should not run as root against test images. This harness
gives a driver repository a disposable Debian VM to run them in, and
takes care of everything around it:

- booting the VM (Vagrant + QEMU, hardware-accelerated on every host),
- running the repository's own setup script inside it to install its tooling,
- running commands as root in the guest and handing back their output and exit status,
- a directory shared between host and guest for images and results,
- **one VM at a time across every repository on the machine**,
- making sure a VM that nobody is using does not stay up.

It knows nothing about any filesystem. Everything filesystem-specific
lives in the consumer's config and scripts.

## The contract

| | The filesystem driver repo (consumer) | The harness |
| --- | --- | --- |
| **Owns** | Its tests: fixture recipes, checks, what "correct" means. | The generic environment only: VM lifecycle (up / run / put / share / down / status / reap / hold / destroy), the machine-wide slot lock, the shared directory, running commands and collecting results. |
| **Tooling** | Declares **and installs** the tools it needs (e.g. `xfsprogs`, `e2fsprogs`, `btrfs-progs`) in its setup script, run inside the VM. | Installs nothing filesystem-specific. `tests/generic.sh` fails the build if a filesystem or its tooling is named in `scripts/`, `vagrant/` or the chore files. |
| **Interface** | `fs-linux-test-harness.toml` plus its own scripts. | One command shape for every filesystem: `chore vm:<task>` (or `scripts/vm.sh <command>`). |

**Tests never skip because a tool is missing.** A tool a test needs is
installed by the consumer's setup script, and the VM is how the host gets
what it cannot run itself. A skipped check reads exactly like a passing
one, which is how an oracle goes unnoticed running against nothing.

## At a glance

| Path | What lives there |
| --- | --- |
| `vm.chores.yml` | The consumer-facing chore tasks. Consumers include it; see [Quickstart](#quickstart). |
| `chores.yml` | The harness's own tasks: `check`, `smoke`, `host:check`. |
| `scripts/vm.sh` | The single entry point: every lifecycle command. |
| `scripts/vm-slot.sh` | The machine-wide slot lock (`acquire` / `release` / `status`). |
| `scripts/vm-session.sh` | Sourced by a consumer script: tear the VM down when it exits. |
| `scripts/host-tools.sh` | Checks the host and prints exactly what to install. |
| `scripts/ci-setup-linux.sh` | Sets a hosted x86_64 Linux CI runner up to boot the VM (KVM access, QEMU, Vagrant, vagrant-qemu), for the harness's CI and every consumer's; `--box-cache-key` prints the box cache key. |
| `scripts/lib/` | `config.sh` (the TOML reader), `engine.sh` (the engine interface), `engine-vagrant.sh` (its Vagrant implementation), `common.sh` (paths). |
| `vagrant/` | The Vagrantfile (chooses box, accelerator, plugins and sharing by host) and the guest-side `deadline.sh` and `mount-share.sh`. |
| `examples/minimal/` | The smallest consumer: config, setup script, `chores.yml`. |
| `tests/` | VM-free unit tests, `smoke.sh` (the real-VM end-to-end test), and `smoke-consumer/`, a realistic consumer CI boots on every pull request. |

## Quickstart

In a filesystem driver repository:

**1. Check the harness out as a sibling, pinned by tag.** Like every
other sibling in the family (see `fs-windows-test-harness`), it is not a
submodule: one copy on the machine, moved to the pinned ref by the
consumer's `siblings` task.

```yaml
# chores.yml
vars:
  LINUX_HARNESS_REF: v0.1.0
# ... and add to the siblings task's list:
#   fs-linux-test-harness https://github.com/antimatter-studios/fs-linux-test-harness.git '{{.LINUX_HARNESS_REF}}'
```

**2. Include the VM tasks, install the reaper, and tear down after tests.**

```yaml
includes:
  vm:
    taskfile: ../fs-linux-test-harness/vm.chores.yml   # no `dir:` — see vm.chores.yml

lifecycle:
  after_all:
    - ../fs-linux-test-harness/scripts/vm.sh reap

tasks:
  test:
    cmds:
      - defer: ../fs-linux-test-harness/scripts/vm.sh down
      - cargo test
```

**3. Write `fs-linux-test-harness.toml` and a setup script.**

```toml
[project]
name = "rust-fs-myfs"

[setup]
script = "scripts/vm-setup.sh"   # runs as root INSIDE the VM
```

```bash
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq xfsprogs      # whatever this repository's tests need
```

**4. Use it.**

```sh
chore vm:host:check                 # what this machine is missing, if anything
chore vm:run -- uname -a            # boots on first use, applies setup, runs as root
chore vm:put test.img               # prints /share/test.img
chore vm:run -- 'xfs_repair -n /share/test.img'
chore vm:down
```

A test binary calls the harness directly:
`../fs-linux-test-harness/scripts/vm.sh run "xfs_repair -n /share/test.img"`.
A shell wrapper that boots the VM sources
`../fs-linux-test-harness/scripts/vm-session.sh` near its top and the VM
comes down when it exits.

Copy-ready versions of all of this are in [`examples/minimal/`](./examples/minimal/);
a consumer that really runs is in [`tests/smoke-consumer/`](./tests/smoke-consumer/).

## Consumer test contract

The harness is the environment; this is the shape of the TESTS a
filesystem driver repository builds on it. It is what
[rust-fs-ext4](https://github.com/christhomas/rust-fs-ext4), the first
consumer, runs locally and in CI, written down so the other filesystem
repositories copy one template rather than inventing four.

### Where tests run

**Everything Linux runs in the guest.** Not "when the host lacks it" —
always. The oracle tools (the filesystem's own `mkfs`, `fsck`, debugger
and dump tools) on a workstation are whatever that machine happens to
have: a keg-only Homebrew formula on a Mac, a distribution build on
Linux, a different version per developer — and on a Mac they are not the
platform the images are for at all. An oracle whose answer depends on
which laptop asked is not an oracle. So the consumer's `[setup]` script
installs them IN THE GUEST, one version for everyone, and the tests reach
them through one helper that runs them there.

That gives three kinds of work, all in the same VM:

| Work | Why it is in the guest |
| --- | --- |
| **Tool oracles** — `fsck -n`, the debugger, the dump tools on an image | One version, one platform, the same answers on every machine. A developer's laptop installs none of them. |
| **Kernel oracles** — the real in-kernel driver reading back what the driver under test wrote, and images only the kernel can make | A loop mount needs root and a kernel that has the filesystem. It happens here and never on the host. |
| **The suite itself, when the host is not Linux** | We run the Linux tests on Linux. On a Linux host that is the host; on a Mac the harness mounts the repository in the guest and the suite is built and run there (`vm.sh guest-test`). |

**On a Linux host the test binaries still run natively** — the host IS
Linux — and only the tool and kernel oracles cross into the guest.

### Talking to the guest from a test process

A suite asks the guest a lot of small questions. Three rules keep that
cheap and safe:

1. **`vm.sh exec`, not `vm.sh run`, for a per-call path.** `run` boots the
   VM when it is down, which is right for a script and wrong inside a test
   binary. `exec` never boots: it checks the process table, runs the
   command, and fails naming `chore vm:up` when there is no VM.
2. **One boot per run.** Bring the VM up once (the first call of the
   suite, or the task) and leave it; the harness keeps ONE multiplexed SSH
   connection alive, so a command costs about 0.03 s instead of the 0.7 s
   a fresh handshake costs. Let `lifecycle: after_all`'s reaper stop it at
   the end of the invocation rather than holding it.
3. **Nothing is copied.** The consumer repository is mounted in the guest
   (`/repo`), so a file the test wrote under the checkout is already
   there; the shared directory (`/share`) is for what a run hands across.
   A test that keeps its scratch files inside the repository can pass the
   guest the same absolute path it used on the host — rust-fs-ext4
   symlinks the host's own path to `/repo` in the guest and passes
   arguments through unchanged.

Batch where it matters: one guest call that mounts an image, walks it,
hashes every file and prints a report beats a hundred round trips asking
one question each.

Every command the harness runs in the guest has **`FLTH_GUEST=1`** in its
environment. A test helper that would otherwise ask the harness to run a
tool for it can see that it is already inside, and run the tool directly
— the same rule (the tool runs in the guest), one less hop.

### Never skip

A test that needs a tool or a fixture **fails** when it is missing, and the
failure names the task that provides it. A test that printed "skip" and
returned reads exactly like one that passed, so an oracle suite on a
machine without its oracle reports green having checked nothing. Put the
lookups in one place (rust-fs-ext4: `fs_ext4_test_support::fixture` and
`oracle_tool`) so there is exactly one way to reach a fixture or a tool,
and nowhere to put an early return. The rule covers shell tests too: a
check written as `matches="$(rg ... || true)"` reports PASS when `rg` is not
installed, and rust-fs-ext4's did exactly that on every CI run while two
violations sat in the tree. Require the tool first, and have `chore tools`
install it.

### The tasks

Same names in every consumer:

| Task | What it does |
| --- | --- |
| `chore siblings` | Check the sibling repositories out at their pinned refs, the harness included (`../fs-linux-test-harness`). Refuses to move a dirty sibling. |
| `chore tools` | Install and verify what the HOST needs — which is NOT the oracle tools: they live in the guest, installed by the `[setup]` script. Typically the VM's own requirements (`vm:host:check`) plus anything a non-oracle host test needs. `--check` mode for the other tasks to fail early. |
| `chore fixtures` | Build every fixture image. Kernel work goes through the harness (`vm.sh run`, from a script that sources `vm-session.sh` so the VM comes down however the build ends); plain `mkfs`/debugger work happens on the host. Declares `sources`/`generates` so an unchanged recipe does not reboot a VM. Pins what makes a build vary (UUIDs, hash seeds) and says what still does. |
| `chore test:unit` | The tests that need no tool and no fixture. CI runs it on a runner with no fixtures, which is what proves the split. |
| `chore test:oracle` | The driver writes, independent tools read back IN THE GUEST: `fsck -n` for consistency **and** the filesystem's debugger for content and metadata (dump and compare, stat, extent maps, block ownership, the journal) — including a negative case that corrupts a data byte and shows the consistency checker passing while the content check fails, because that is the gap the second tool closes. |
| `chore test:kernel` | The driver writes, THE REAL KERNEL reads back: the image loop-mounted in the guest, and names, sizes, modes, xattrs, ACLs and content hashes compared against what was written — plus one reverse case (the kernel writes, the driver reads) and one deliberate corruption that must fail. |
| `chore test:vm` | The whole suite built and run INSIDE the guest (`vm.sh guest-test`), which is how a host that is not Linux runs a Linux suite at all. CI runs it on a KVM runner so the path cannot rot. |
| `chore test` | Everything, exactly as CI runs it: unit, a check that what the host provides is present (so a missing one fails once, not in every test), the oracles with their output shown (`--show-output`, so the log carries what was checked, not just a count), the kernel oracles, the whole suite, the script tests. On a host that is not Linux it runs `test:vm` instead — the same suite, one Linux away. |
| `chore vm:*` | This harness's tasks, included from the sibling (see [Quickstart](#quickstart)). |

Include `vm.chores.yml` with `optional: true`: the harness is a sibling
that `chore siblings` itself checks out, so the file must load without it.
Guard the reaper the same way:

```yaml
includes:
  vm:
    taskfile: ../fs-linux-test-harness/vm.chores.yml
    optional: true
lifecycle:
  after_all:
    - '[ ! -x ../fs-linux-test-harness/scripts/vm.sh ] || ../fs-linux-test-harness/scripts/vm.sh reap'
```

### CI

Every job runs the tasks above, so a green local `chore test` and a green
pipeline are the same evidence:

| Job | Runs on | Steps |
| --- | --- | --- |
| `unit` | `ubuntu-24.04` | `chore siblings`, `chore test:unit`, with no fixtures present. |
| `fixtures` | `ubuntu-24.04` (x86_64, KVM) | `chore siblings`, `../fs-linux-test-harness/scripts/ci-setup-linux.sh` (KVM access, QEMU, Vagrant; its `box-cache-key` output keys an `actions/cache` of `~/.vagrant.d/boxes`), `chore fixtures`, upload the images as an artifact. |
| `test` | `ubuntu-24.04` (x86_64, KVM) | `chore siblings`, `ci-setup-linux.sh`, download the fixtures, `chore lint`, `chore test`. Every oracle tool call and every kernel mount happens in the VM this job boots — and a step checks the tools are NOT installed on the runner, so a green run is evidence of that. |
| `test` (other architectures) | e.g. `ubuntu-24.04-arm` | GitHub's arm64 runners have no KVM, so no VM can run there: this job runs the tiers that need none (lint, the unit tier, the fixture-reading tests). The oracles read the same images on every architecture and are covered by the x86_64 job. |
| `suite-in-vm` | `ubuntu-24.04` (x86_64, KVM) | `chore test:vm`: the suite compiled and run inside the guest. It is the macOS path, exercised on every pull request so it cannot rot. |
| `ci-ok` | `ubuntu-latest`, `if: always()` | Needs every other job; fails if any failed, was cancelled **or was skipped**. |

`.github-guard` declares `required = ci-ok` and nothing else, so jobs can be
added, renamed or split without a branch-protection change. Until the
harness has a release, a consumer pins it to a full commit SHA (fetched by
SHA: `git init`, `git fetch --depth 1 origin <sha>`, `git checkout
FETCH_HEAD`); once it is tagged, pin the tag like every other sibling.

## Configuration: `fs-linux-test-harness.toml`

At the consumer repository's root. Found from the working directory or
any parent, or named by `FLTH_CONFIG`. It is a strict subset of TOML:
sections, `key = "string"` (no escapes), `key = 'literal'`, non-negative
integers and comments. **Anything else is an error, with the file and
line**: unknown sections and keys, duplicates and wrong types are refused
rather than ignored, because a typo silently ignored is a default nobody
chose.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `[project] name` | string | **required** | Lowercase letters, digits and inner hyphens, at most 63. The VM's hostname, the name of its machine directory, and the name the slot shows other repositories. Two checkouts of one project share a machine; keep names unique across projects. |
| `[setup] script` | string | **required** | Path relative to the repository. Run as root inside the VM after a boot, **only when it has changed** since it was last applied (a SHA-256 stamp in the guest), with stdin from `/dev/null` and `FLTH_PROJECT` and `FLTH_SHARE` set. A failure fails `up` and leaves the VM running for inspection. `chore vm:provision` re-runs it regardless. |
| `[test] command` | string | none | Run by `chore vm:test` on the **host**, from the repository root, with the VM up; extra arguments are appended. It reaches the guest through `FLTH_VM` (the path of `vm.sh`) and finds the share at `FLTH_SHARE_HOST`. The VM is torn down afterwards. |
| `[test] guest_command` | string | none | Run by `chore vm:guest-test` **inside the guest**, from `/repo` (this repository, mounted there read-write), with arguments appended and `FLTH_GUEST=1` set. Output streams as it happens and its exit status is the task's. The harness knows nothing about what it is: the `[setup]` script installs whatever the guest needs to run it — a compiler, an interpreter, a package manager's worth of tools — and anything the run should leave behind goes in the share. |
| `[share] dir` | string | `.vm-share` | Host side of the shared directory, relative to the repository (gitignore it). Always `/share` in the guest. |
| *(no key)* | | | **The consumer repository itself is mounted at `/repo` in the guest, read-write, on every boot.** It is what makes `[test] guest_command` possible, and it means a file a test wrote under the checkout is already visible in the guest — nothing to copy. |
| `[vm] memory` | string | `4G` | Guest memory, e.g. `2G`, `2048M`. |
| `[vm] cpus` | integer | `4` | Guest CPUs, 1–64. |
| `[vm] disk` | string | `32G` | Guest disk size, e.g. `16G`. |
| `[vm] ssh_port` | integer | `50122` | Host port forwarded to the guest's SSH. Auto-corrected by Vagrant if taken. |
| `[vm] deadline_minutes` | integer | `480` | The guest powers itself off this long after boot unless held. |

Paths may contain only letters, digits, `.`, `_`, `-` and `/`, must be
relative, and must not leave the repository.

## Chore tasks

### For consumers (`vm.chores.yml`, included as `vm`)

| Task | What it does |
| --- | --- |
| `chore vm:up` | Boot, apply setup, and **hold** it: stays up until `vm:down`, the reaper leaves it, the guest deadline is cancelled. |
| `chore vm:run -- <command>` | Run a command as root in the guest (booting if needed). Exit status and stdout/stderr are the guest command's. Operators like `&&` and `\|` belong to the guest. |
| `chore vm:exec -- <command>` | The same, in a VM that is ALREADY up — and it never boots one. The per-call path for a test process: no state probe beyond a process check, and one multiplexed SSH connection shared by every call (~0.03 s each). Fails naming `chore vm:up` when nothing is running. |
| `chore vm:put <file>` | Copy a file into the shared directory; print its guest path (`/share/<name>`). |
| `chore vm:share` | Print the host path of the shared directory. |
| `chore vm:test [-- args]` | Boot, run the `[test] command` on the HOST, tear down. A failing teardown fails the task; the test's own failure wins if both fail. `FLTH_KEEP_VM=1` keeps the VM. |
| `chore vm:guest-test [-- args]` | Boot, run the `[test] guest_command` INSIDE the guest from `/repo`, tear down — the same session rules. For a suite whose host cannot run it. |
| `chore vm:provision` | Re-run the setup script, changed or not. |
| `chore vm:down` | Halt, **confirm** the VM stopped, release the slot. Fails if the VM is still running or its state cannot be read. Keeps the disk. |
| `chore vm:status` | Exit 0 when running, 1 otherwise, and say which. |
| `chore vm:hold` | Mark the VM as deliberately running (reaper and guest deadline stand down). |
| `chore vm:reap` | Stop a VM nothing cleaned up, unless held. Meant for `lifecycle: after_all`. |
| `chore vm:destroy` | Delete the VM and its disk; the next boot provisions from scratch. |
| `chore vm:config` | Print the resolved config, paths, machine identity and slot location. |
| `chore vm:host:check` | Check the host; print the exact install command for anything missing. |
| `chore vm:slot:status` | Who holds the machine-wide slot, for how long, and whether their VM is alive. |
| `chore vm:slot:release-force` | Free the slot whoever holds it. A person's decision, for a holder that will not let go. |

### For the harness itself (`chores.yml`)

| Task | What it does |
| --- | --- |
| `chore check` | The VM-free self-test: `bash -n`, shellcheck, every unit test. CI job `unit`. |
| `chore smoke` | Boot a real VM and drive every command through it (`tests/smoke.sh`). CI job `smoke-x86_64`. Needs KVM or HVF. |
| `chore smoke:destroy` | Delete the smoke consumer's VM. |
| `chore host:check` | Check this host. |

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `FLTH_CONFIG` | search upward | Path of the consumer's config. |
| `FLTH_KEEP_VM` | unset | `1`: `vm:test` and `vm-session.sh` leave the VM running. |
| `FLTH_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/fs-linux-test-harness` | Machines (`machines/<project>/`) and firmware links. |
| `FLTH_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/fs-linux-test-harness` | The slot lock. Must be the same for every repository on the machine. |
| `FLTH_SLOT_WAIT` | `3600` | Seconds `up` waits for the slot before giving up. |
| `FLTH_SLOT_BOOT_GRACE` | `180` | Seconds a new slot holder is trusted before a VM must be running. |
| `FLTH_SSH_PERSIST` | `3600` | Seconds the shared SSH connection to the guest stays open when idle. |
| `FLTH_GUEST` | set by the harness | `1` in every command the harness runs in the guest. Read it, never set it: it is how a program tells that it is already inside the test VM. |
| `FLTH_FIRMWARE_CODE`, `FLTH_FIRMWARE_VARS` | `/usr/share/AAVMF/AAVMF_{CODE,VARS}.fd` | UEFI firmware for arm64 guests on a Linux host. |

## The VM

The guest architecture is the host's, and hardware acceleration is
required: a VM emulated in software is a suite that takes an hour and
times out somewhere unhelpful, so the harness refuses rather than
falling back.

| Host | Accelerator | Box | Vagrant provider plugin | Firmware | Shared directory |
| --- | --- | --- | --- | --- | --- |
| macOS, Apple Silicon | HVF | `christhomas/vagrant-rpi-bookworm-arm64` | `vagrant-qemu-christhomas` + `vagrant-notify-forwarder-christhomas` (forks that fix Mac-specific problems) | Homebrew QEMU's | virtiofs |
| Linux aarch64 | KVM | `cloud-image/debian-12` (arm64), pinned | stock `vagrant-qemu` | `FLTH_FIRMWARE_*` (Debian: AAVMF) | 9p |
| Linux x86_64 | KVM | `cloud-image/debian-12` (amd64), pinned | stock `vagrant-qemu` | none (SeaBIOS) | 9p |

**Why 9p on Linux:** the stock provider has no virtiofs support; 9p
needs no daemon and no root. The **share** uses
`security_model=mapped-xattr`, so root in the guest can create files the
host user owns. The **repository** mount uses `security_model=none`, so
the guest sees the host's real ownership, modes and extended attributes:
mapped-xattr synthesises the xattr namespace, and a tool that walks the
tree reading attributes is told one exists and then that there is no data
for it. Nothing writes ownership into the repository from the guest, so
there is nothing to map.

**Where state lives:** each consumer has its own machine (its own disk
and its own installed tooling) under `FLTH_CACHE_DIR/machines/<project>/`,
outside every repository; the harness checkout is never written to. The
trade-off: each consumer pays its own first boot and its own disk,
in exchange for setups that cannot interfere, a `destroy` that affects
only its owner, and a harness checkout that stays clean for the
`siblings` task. Boxes are shared in Vagrant's own box store.

### The engine interface

Everything the harness decides is written against a small interface
([`scripts/lib/engine.sh`](./scripts/lib/engine.sh)): `engine_prepare`,
`engine_identity`, `engine_state` (running / stopped / absent /
**unknown**), `engine_up`, `engine_down [--force]`, `engine_destroy`,
`engine_run`, `engine_copy`, `engine_alive`. Vagrant is the only
implementation ([`engine-vagrant.sh`](./scripts/lib/engine-vagrant.sh));
another engine is one file. Two properties an engine must keep: a state
it could not read is `unknown`, never `stopped`; and `engine_alive` is a
process check that costs milliseconds, because the reaper runs it on
every chore invocation.

The Vagrant engine answers `running` from the process table (a QEMU
process naming this machine's disk) without calling Vagrant, and runs
commands over plain `ssh` with Vagrant's cached ssh settings — about a
second per `run`, against five to ten for `vagrant ssh` under bundler.

**One connection, reused.** The first command opens an SSH master
deliberately (`-M -N -f`, its own streams, socket under `FLTH_STATE_DIR`)
and later commands ride it: about 0.03 s each instead of 0.7 s. The master
is opened on purpose rather than grown out of the first command — a master
that inherits a command's stdout keeps it open for as long as it persists,
so a caller capturing the output of a one-second call would wait an hour
for end-of-file. It is closed before a boot and after a stop.

**A guest that goes away fails the call.** The client keeps the
connection alive (`ServerAliveInterval=15`, `ServerAliveCountMax=8`), so
a VM halted underneath a running command — by its own deadline, by a
`destroy`, by a host out of memory — ends that command in about two
minutes instead of leaving it waiting for ever. Set `[vm]
deadline_minutes` longer than your suite takes: the deadline does not
know what is using the VM.

## The slot lock

One VM runs at a time **across every repository on the machine**. VMs
ask for gigabytes; two beside a compiler fill a laptop, and a full
machine kills background work without saying why. The cost is stated
rather than hidden: VM work in different repositories queues instead of
overlapping.

- The lock is a directory under `FLTH_STATE_DIR` (`mkdir` is atomic)
  holding one record: machine identity, project name, time taken, and a
  generation token.
- `up` takes the slot **before booting, and only when booting**. `down`
  and `destroy` release it **only once the VM is confirmed stopped** — a
  halt that left it running, or a state that could not be read, keeps
  the slot.
- A waiter breaks a lock only when the holder's VM is not running **and**
  the holder is older than the boot grace (a slot is necessarily taken
  before its VM exists). An unreadable process table is not a dead holder.
- **There is no age-alone break.** A live holder is never robbed, however
  long it has held the slot; a waiter gives up after `FLTH_SLOT_WAIT` and
  names the remedy (`chore vm:down` there, or `chore vm:slot:release-force`).
- Breaks and releases delete only the generation they inspected (checked
  before and after an atomic move), a lock displaced by a race is kept as
  an orphan rather than deleted, and a half-written record is never
  mistaken for a holder.

## What stops a VM

In order of precision:

1. **`down`** — `chore vm:down`, a chore `defer:`, `vm-session.sh`'s exit
   trap, or `vm:test`'s own teardown. Fails loudly when the VM will not stop.
2. **`reap`** — from `lifecycle: after_all`, on any later chore
   invocation: stops a VM nothing accounted for (a bare `cargo test`, a
   killed run). Fails soft, so an unrelated `chore build` is not turned red.
3. **The guest's own deadline** — scheduled inside the guest at every boot
   (`[vm] deadline_minutes`), confirmed from logind's record. The one net
   that works when the host process is hung or killed.

`hold` (and `chore vm:up`) opts out of 2 and 3 for a person working in
the guest; `down` and `destroy` clear it, and a reboot re-arms the deadline.

## Host setup

`chore vm:host:check` says what is missing on this host. In full:

**macOS (Apple Silicon)**

```sh
brew install --cask hashicorp/tap/hashicorp-vagrant
brew install antimatter-studios/tap/qemu antimatter-studios/tap/virtiofsd
vagrant plugin install vagrant-qemu-christhomas vagrant-notify-forwarder-christhomas
```

**Linux x86_64** (a CI runner does all of this with `scripts/ci-setup-linux.sh`)

```sh
sudo apt-get install qemu-system-x86 qemu-utils
# Vagrant 2.4.9 from HashiCorp's apt repository, then:
vagrant plugin install vagrant-qemu --plugin-version 0.6.3
# and read-write /dev/kvm (the kvm group)
```

**Linux aarch64.** `apt-get install qemu-system-arm qemu-utils qemu-efi-aarch64`
and read-write `/dev/kvm`. HashiCorp ships no linux-arm64 Vagrant, so a
current one runs from source under bundler, with its plugins in the
Gemfile's `:plugins` group (Vagrant's bundler mode does not use
`vagrant plugin install`):

```sh
mise install ruby@3.3.12                       # prebuilt, headers included
mkdir -p ~/.local/share/vagrant-2.4.9 && cd ~/.local/share/vagrant-2.4.9
cat > Gemfile <<'RUBY'
source "https://rubygems.org"
gem "vagrant", git: "https://github.com/hashicorp/vagrant.git", tag: "v2.4.9"
group :plugins do
  gem "vagrant-qemu", "0.6.3"
end
RUBY
PATH="$(mise where ruby@3.3.12)/bin:$PATH" bundle config set --local path ~/.local/share/vagrant-bundle
PATH="$(mise where ruby@3.3.12)/bin:$PATH" bundle install
# ~/.local/bin/vagrant: BUNDLE_GEMFILE=~/.local/share/vagrant-2.4.9/Gemfile exec <ruby>/bin/bundle exec vagrant "$@"
```

The Vagrantfile recognises a plugin loaded either way.

## CI and automated merging

Every pull request and every push to `main` runs
[`.github/workflows/ci.yml`](./.github/workflows/ci.yml):

| Job | Runs on | What a green run proves |
| --- | --- | --- |
| `unit (VM-free)` | `ubuntu-latest` | `chore check`: every script parses and is shellcheck-clean; the config reader accepts the shipped configs and refuses invalid ones with clear errors; the slot lock's guarantees (no age-alone break, generation-bound deletes, half-written records, unreadable process tables, contention between two consumers); the orchestration against a stub engine (boot retries, never releasing on an unread state, setup stamping, hold/reap, the session rules); the Vagrant engine against stub `vagrant`/`ssh`/`ps`; the guest deadline script; the Vagrantfile evaluated for all three hosts with hostile inputs refused; and that the harness names no filesystem. |
| `smoke (real VM, x86_64 KVM)` | `ubuntu-latest` with KVM | `chore smoke`: a real Debian VM boots through the harness under KVM; the smoke consumer's setup installs `e2fsprogs` inside it; a second consumer is refused the slot; exit status, output and files cross host↔guest; hold survives the reaper and a leaked VM does not; a realistic suite (build an ext4 image from host files, read back with `debugfs`, compare, `e2fsck -fn`, collect results on the host) **passes**; the same suite with one byte of file data corrupted **fails with a non-zero exit**; `FLTH_KEEP_VM=1`, `down` and `destroy` behave. |
| `ci-ok` | `ubuntu-latest` | Green only if every job above ran and succeeded (a failed, cancelled **or skipped** job fails it). |

**The required status check is `ci-ok`.** Branch protection and
auto-merge should require that one name and nothing else, so adding a
job later never needs a settings change. Superseded runs on the same
pull request are cancelled.

The arm64 path (Linux aarch64 under KVM) is proven by `chore smoke` on an
arm64 host rather than in hosted CI: GitHub's hosted arm64 runners do not
expose KVM (checked by the manual `kvm-probe` workflow). The macOS path
is proven by `chore smoke` on a Mac.

## Relation to fs-windows-test-harness

[`fs-windows-test-harness`](https://github.com/antimatter-studios/fs-windows-test-harness)
is the same idea for drivers that must run on Windows: a Mac-side
orchestrator driving a Windows VM over SSH with a scenario matrix. This
harness is the Linux counterpart and follows the same family rules —
consumed as a sibling checkout pinned by tag, configured by a TOML file
at the consumer's root named after the harness, filesystem knowledge
kept in the consumer. It is deliberately smaller: it provides the
environment and leaves the tests to the consumer, with no matrix or
scenario runner of its own.

## Roadmap / not yet

Explicitly **not** in this version:

- **FUSE mounts** of a driver under test inside the guest.
- **Differential testing against the kernel's own drivers** (the same
  operations through the driver and through the in-kernel filesystem,
  results compared).
- **A randomised operation generator.**
- An engine other than Vagrant.
- An arm64 job in hosted CI (waiting on hosted runners with KVM).

## License

[MIT](./LICENSE).

## Provenance

Extracted from three diverged copies of the same oracle-VM tooling in
`rust-fs-ext4`, `rust-fs-xfs` and `rust-fs-btrfs` (`scripts/vm.sh`,
`vm-slot.sh`, `vm-session.sh`, `tests/vagrant/debian/Vagrantfile`). Each
copy had fixes the others lacked; this repository takes the most correct
version of each behaviour and removes everything filesystem-specific.
The consumers move onto it together, each in its own pull request.
