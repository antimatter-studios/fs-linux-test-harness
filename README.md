# fs-linux-test-harness

> Reusable Linux-VM test harness for filesystem driver projects. Provides the environment (one shared guest per run profile, its lifecycle, shared directories, command execution); each driver repo supplies its own tests and installs its own tooling.

[![CI](https://github.com/antimatter-studios/fs-linux-test-harness/actions/workflows/ci.yml/badge.svg)](https://github.com/antimatter-studios/fs-linux-test-harness/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Release: v0.7.0](https://img.shields.io/badge/release-v0.7.0-blue.svg)](./CHANGELOG.md)

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
- **one guest, shared by every consumer on the host**, with a check of the host's memory before every boot,
- making sure a VM that nobody is using does not stay up.

It knows nothing about any filesystem. Everything filesystem-specific
lives in the consumer's config and scripts.

## The contract

| | The filesystem driver repo (consumer) | The harness |
| --- | --- | --- |
| **Owns** | Its tests: fixture recipes, checks, what "correct" means. | The generic environment only: the shared guest and its lifecycle (up / run / put / share / down / status / reap / hold / destroy), the shared directory, running commands and collecting results. |
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
| `scripts/vm-session.sh` | A session: `vm.sh session <command...>` runs a command inside one, and a script that sources it becomes one. It is one run on the shared guest, ended when the command ends, however it ends; the guest stays up for the next run. |
| `scripts/host-tools.sh` | Checks the host and prints exactly what to install. |
| `scripts/ci-setup-linux.sh` | Sets a hosted x86_64 Linux CI runner up to boot the VM (KVM access, QEMU, Vagrant, vagrant-qemu), for the harness's CI and every consumer's; `--box-cache-key` prints the box cache key. |
| `scripts/lib/` | `config.sh` (the TOML reader), `engine.sh` (the engine interface), `engine-vagrant.sh` (its Vagrant implementation), `common.sh` (paths). |
| `vagrant/` | The Vagrantfile (chooses box, accelerator, plugins and sharing by host) and the guest-side `apt-ready.sh`, `deadline.sh`, `mount-share.sh` and `mount-cache.sh`. |
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
  LINUX_HARNESS_REF: v0.7.0
# ... and add to the siblings task's list:
#   fs-linux-test-harness https://github.com/antimatter-studios/fs-linux-test-harness.git '{{.LINUX_HARNESS_REF}}'
```

**2. Include the VM tasks, install the reaper, and run the tests inside a session.**

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
      - ../fs-linux-test-harness/scripts/vm.sh session cargo test
```

`vm.sh session <command...>` runs the command inside a **session**: one run on
the shared guest, which is cleaned up and taken off the guest's list of users
when the command ends — passed, failed or killed — and run any way at all, not
only through chore. The guest stays up for the next run. Put it in the script your tiers run (`scripts/test.sh`) rather
than in each task, so a run by hand gets it too. See [rule 2](#talking-to-the-guest-from-a-test-process).

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

Nothing holds the package manager when it runs: every boot first runs
`vagrant/guest/apt-ready.sh`, which disables the macOS box's first-boot
dialog (`userconfig.service`, which waits for a keyboard and holds the dpkg
lock), then waits up to five minutes for anything else holding the lock and
fails the boot, naming the lock and the process, if it is still held. Once
the locks are free it runs `dpkg --configure -a`, finishing any transaction
an earlier boot was stopped in the middle of, so a setup script never meets
"dpkg was interrupted" and needs no recovery of its own.

**4. Use it.**

```sh
chore vm:host:check                 # what this machine is missing, if anything
chore vm:run -- uname -a            # boots on first use, applies setup, runs as root
chore vm:put test.img               # prints /share/test.img
chore vm:run -- 'xfs_repair -n /share/test.img'
chore vm:down
```

A test binary calls the harness directly:
`../fs-linux-test-harness/scripts/vm.sh run "xfs_repair -n /share/test.img"`,
and the runner that starts it runs it through
`../fs-linux-test-harness/scripts/vm.sh session <command...>`. A shell
wrapper that boots the VM sources `../fs-linux-test-harness/scripts/vm-session.sh`
near its top instead; its run ends when it exits.

Nothing else is set up: every consumer on the host uses one shared guest, and each
run attaches its own tree to it while it runs ([One guest for every
consumer](#one-guest-for-every-consumer)).

Copy-ready versions of all of this are in [`examples/minimal/`](./examples/minimal/);
a consumer that really runs is in [`tests/smoke-consumer/`](./tests/smoke-consumer/).

## Consumer test contract

The harness is the environment; this is the shape of the TESTS a
filesystem driver repository builds on it. It is what
[rust-fs-ext4](https://github.com/antimatter-studios/rust-fs-ext4), the first
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
2. **One boot per run, and the test runner owns it.** Bring the VM up
   once (the first call of the suite, or the task) and leave it; the
   harness keeps ONE multiplexed SSH connection alive, avoiding a fresh
   SSH handshake for every command. The script
   that runs the suite (`scripts/test.sh`, whatever every tier calls) runs
   it through `vm.sh session <command...>`, so the run is on the guest's
   list of users while it lasts and is cleaned up when it ends, however it
   ends:

   ```sh
   exec "$repo/../fs-linux-test-harness/scripts/vm.sh" session cargo test "$@"
   ```

   **Do not leave it to the reaper.** The guest is shared with every other
   consumer on the host, and `chore vm:down` stops it only when nobody is on
   that list: a run outside a session is on it only for each single call, so
   the guest can be stopped between two of them. The reaper is the net for a
   run that never reached the runner (a bare `cargo test`), not the plan.

   The runner decides where a session makes sense, so the consumer does not
   have to: in the guest (`FLTH_GUEST=1`) and on a host that cannot run the
   VM (`host-tools.sh --quiet` fails — a CI runner without KVM) it runs the
   command as it is, and asks the engine nothing. The guest stays up when the
   run ends, for the next run of this consumer or another; `chore vm:up` also
   holds it, which cancels its idle deadline.
3. **Nothing is copied.** The consumer repository is mounted in the guest
   (`/repo`), so a file the test wrote under the checkout is already
   there; the shared directory (`/share`) is for what a run hands across.
   A test that keeps its scratch files inside the repository can pass the
   guest the same absolute path it used on the host — rust-fs-ext4
   symlinks the host's own path to `/repo` in the guest and passes
   arguments through unchanged. That is for reading what the test wrote:
   a tool that works on an IMAGE may need the guest's own disk instead
   (next section).

Batch where it matters: one guest call that mounts an image, walks it,
hashes every file and prints a report beats a hundred round trips asking
one question each.

### Where a tool works on an image

**The shares are not a disk.** `/share` and `/repo` are host directories
behind a server — virtiofsd on macOS, QEMU's 9p on Linux — and each one
refuses something a filesystem tool does to an image file:

| On | What fails | How it shows |
| --- | --- | --- |
| macOS (virtiofs), virtiofsd before 1.14.0 | any `O_DIRECT` open of a shared file — `xfs_repair`, `xfs_db`, `losetup --direct-io=on`, `dd iflag=direct` (#26) | `ENOTDIR` ("Not a directory"), whatever the image holds |
| macOS (virtiofs), virtiofsd 1.14.0 | a file hard-linked and then removed under its first name cannot be opened under its new name for a moment (#162) | `ENOENT` on a file that is there; `ls` lists it soon after |
| Linux (9p) | `mmap` of a shared file is unreliable | a tool killed by `SIGSEGV`, exit 139 (seen on CI's x86_64 guest) |
| Linux (9p), `/repo` | setting ownership (`chown`, a tool restoring recorded uids): `security_model=none` cannot | `Operation not permitted` |

The macOS row is a defect in the host's virtiofsd, not in the guest:
before 1.14.0 it decoded an arm64 guest's open flags with x86_64 values,
and arm64's `O_DIRECT` is x86_64's `O_DIRECTORY`, so the host opened the
image as a directory (christhomas/virtiofsd#3). virtiofsd v1.14.0 decodes
them with the guest's own values, and `chore vm:host:check` refuses an
older one. In the six Apple Silicon smoke runs recorded on 2026-11-03
with virtiofsd 1.14.0 during #84 and #86, both `O_DIRECT` checks passed
(#89). CI here never sees the defect: CI's guest is x86_64 and shares
over 9p.

Each of these reads as a verdict on the image rather than on where it
was kept. So **a tool that works on an image works on the guest's own disk**:
copy the image (or the source tree) to `/var/tmp`, run the tool there, and
copy only the finished artefact back to `/share`. `/var/tmp`, not `/tmp`:
a tmpfs `/tmp` is sized from the guest's RAM. A tool that only reads its
image with buffered I/O works on the shares, but a suite that copies does
not have to know which of its tools those are.

The smoke consumer does exactly this (`tests/smoke-consumer/guest-suite.sh`),
and `tests/guest-scratch.sh` fails the build if any of its guest-side
scripts points an image tool at the share or the repository mount.
`chore smoke` opens a file on each share with `O_DIRECT`, which is the
end-to-end check of the virtiofsd fix on a Mac.

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

### Output: quiet by default, `--verbose` on request

A task prints a **verdict**, not a transcript: a line per suite, a final
count, and the path of the file that holds everything else. The detail is
never thrown away — it is written to a log under the repository's own
scratch directory and named at the end — but a passing run does not put it
on the terminal.

| | Prints |
| --- | --- |
| **Pass** | one line per suite, a final `N passed` (or the count of comparisons an oracle made), and the log path |
| **Fail** | the verdict, the log path, the command's own status — and nothing else. `--tail N` or `OUTPUT_BUDGET_FAIL_TAIL=N` prints that many lines of the log for whoever is watching |
| **`--verbose` / `-v`, or `OUTPUT_BUDGET_VERBOSE=1`** | everything, streamed live: the VM booting, each guest command, every test name |
| **CI** | the quiet form, with the log uploaded as an artefact |

Two reasons, and the second is the one people forget. A run that prints
three thousand lines hides the twenty that matter, so a failure costs
minutes of scrolling. And every reader pays for that output — a person, a
CI log viewer, and an agent working on the repository, which re-reads its
whole transcript on each step and so pays for a verbose run many times
over. Quiet by default is not tidiness; it is what makes a failure
findable and a long session affordable.

**The wrapper that does this is `rust-fs-core`'s, not this repository's.**
`scripts/output-budget.sh` in `antimatter-studios/rust-fs-core` runs the
command, writes everything to a log, prints one line on success, prints the
verdict and the log path on failure, and **exits 65 when a run passed but
printed more than its budget** — a status you can tell apart from a failing
suite. `--verbose` (or `OUTPUT_BUDGET_VERBOSE=1`) streams as well, and does
not exempt a run from its budget.

This repository used to carry a copy of it, and that is exactly how the
family ended up with three divergent copies reached four different ways, each
one internally consistent and nothing comparing them
(antimatter-studios/rust-fs-core#153). There is one copy now, in core, and a
consumer resolves it at run time:

```sh
# in the consumer's scripts/tier.sh: ask where core is, verify what you
# found, and use it. Do not commit a copy.
core="$(cargo metadata --format-version 1 --locked \
        | jq -r '.packages[] | select(.name == "rust-fs-core") | .manifest_path')"
budget="$(dirname "$core")/scripts/output-budget.sh"
[ "$(bash "$budget" --version)" = 'rust-fs-core-output-budget 1' ] || exit 1

bash "$budget" \
    --log .test-logs/oracle.log --max-lines 120 --label 'test:oracle' \
    -- cargo test --test oracle_debugfs
```

The harness's job is the VM, not the wrapper. What it still asks of a
consumer is the *policy*: set the budget from a measured run, and raise it
deliberately when a suite grows — the same way the executed-test floors are
set. A budget nobody can breach measures nothing.

`--verbose` exists because watching matters sometimes: a VM that is slow to
boot, a suite that hangs, a guest command that needs seeing as it happens.
It is a flag on the task, not a different code path — the same run, more of
it shown.

### The tasks

Same names in every consumer:

| Task | What it does |
| --- | --- |
| `chore siblings` | Check the sibling repositories out at their pinned refs, the harness included (`../fs-linux-test-harness`). Refuses to move a dirty sibling. |
| `chore tools` | Install and verify what the HOST needs — which is NOT the oracle tools: they live in the guest, installed by the `[setup]` script. Typically the VM's own requirements (`vm:host:check`) plus anything a non-oracle host test needs. `--check` mode for the other tasks to fail early. |
| `chore fixtures` | Build every fixture image. Kernel work goes through the harness (`vm.sh run`, from a script that sources `vm-session.sh` so its run ends however the build ends); plain `mkfs`/debugger work happens on the host. Declares `sources`/`generates` so an unchanged recipe does not reboot a VM. Pins what makes a build vary (UUIDs, hash seeds) and says what still does. |
| `chore test:unit` | The tests that need no tool and no fixture. CI runs it on a runner with no fixtures, which is what proves the split. |
| `chore test:oracle` | The driver writes, independent tools read back IN THE GUEST: `fsck -n` for consistency **and** the filesystem's debugger for content and metadata (dump and compare, stat, extent maps, block ownership, the journal) — including a negative case that corrupts a data byte and shows the consistency checker passing while the content check fails, because that is the gap the second tool closes. |
| `chore test:kernel` | The driver writes, THE REAL KERNEL reads back: the image loop-mounted in the guest, and names, sizes, modes, xattrs, ACLs and content hashes compared against what was written — plus one reverse case (the kernel writes, the driver reads) and one deliberate corruption that must fail. |
| `chore test:vm` | The whole suite built and run INSIDE the guest (`vm.sh guest-test`), which is how a host that is not Linux runs a Linux suite at all. CI runs it on a KVM runner so the path cannot rot. |
| `chore test` | Everything, exactly as CI runs it: unit, a check that what the host provides is present (so a missing one fails once, not in every test), the oracles with their output captured (to the log, and echoed only under `--verbose`, so a pass is a verdict and a failure is an excerpt), the kernel oracles, the whole suite, the script tests. On a host that is not Linux it runs `test:vm` instead — the same suite, one Linux away. |
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
added, renamed or split without a branch-protection change. A consumer pins
the harness by tag, like every other sibling: `LINUX_HARNESS_REF` in its
`chores.yml`.

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
| `[project] name` | string | **required** | Lowercase letters, digits and inner hyphens, at most 63. The name the shared guest lists this consumer's suites under, and the name of its setup stamp and its directories in the guest; keep names unique across projects. |
| `[setup] script` | string | **required** | Path relative to the repository. Run as root inside the shared guest when this consumer joins a boot, **only when it has changed** since it was last applied on that boot (a SHA-256 stamp in the guest), with stdin from `/dev/null` and `FLTH_PROJECT` and `FLTH_SHARE` set. It goes with the boot: the next boot runs it again. A failure fails `up` and leaves the guest running for inspection. `chore vm:provision` re-runs it regardless. |
| `[test] command` | string | none | Run by `chore vm:test` on the **host**, from the repository root, with the guest up, as a run of its own; extra arguments are appended. It reaches the guest through `FLTH_VM` (the path of `vm.sh`) and finds the share at `FLTH_SHARE_HOST`. The guest stays up afterwards. |
| `[test] guest_command` | string | none | Run by `chore vm:guest-test` **inside the guest**, from `/repo` (this repository, mounted there read-write), with arguments appended and `FLTH_GUEST=1` set. Output streams as it happens and its exit status is the task's. The harness knows nothing about what it is: the `[setup]` script installs whatever the guest needs to run it — a compiler, an interpreter, a package manager's worth of tools — and anything the run should leave behind goes in the share. |
| `[cache] size` | string | none | **Declares a cache that outlives a run**, e.g. `16G`. A directory of the shared guest's, mounted at `/cache` in every run of this consumer and kept across its runs for as long as the guest is up. It goes with the boot (#186), and the size is not enforced. For in-guest build state a run can rebuild but should not have to: point a toolchain's home or build directory under `/cache`. No `[cache]` section, no `/cache`. |
| `[share] dir` | string | `.vm-share` | Host side of the shared directory, relative to the repository (gitignore it). Always `/share` in the guest. |
| *(no key)* | | | **The consumer repository itself is mounted at `/repo` in the guest, read-write, on every boot.** It is what makes `[test] guest_command` possible, and it means a file a test wrote under the checkout is already visible in the guest — nothing to copy. |
| `[vm] memory`, `[vm] cpus`, `[vm] disk`, `[vm] ssh_port`, `[vm] deadline_minutes` | | | **Read and validated, and not used.** They described the VM of its own a consumer had before the shared guest was the only one. The shared guest's size and deadline are the host's: `FLTH_SHARED_MEMORY`, `FLTH_SHARED_CPUS`, `FLTH_SHARED_DISK` and `FLTH_SHARED_DEADLINE` (see [Environment](#environment)). They may be removed from a consumer's config. |
| `[vm] guest` | string | `"debian-12"` | Which pinned guest boots: `"debian-12"` (kernel 6.1) or `"debian-13"` (kernel 6.12, xfsprogs 6.13). The harness pins each release's box and version; a consumer names the release, never a box. Each release is a shared guest of its own (`machines/shared-<guest>/`). A consumer needing both runs a second config with its own `[project] name` through `FLTH_CONFIG`. `"debian-13"` is Linux hosts only: the macOS guest is Debian 12. |
| `[vm] profile` | string | none | A named run environment from `run-profiles/<name>.toml`. The profile selects the base guest, pinned preparation script and optional exact kernel release and modules. Suites with identical resolved profiles share one VM. `FLTH_PROFILE` overrides this key for an individual suite. See [Run profiles](#run-profiles). |

Paths may contain only letters, digits, `.`, `_`, `-` and `/`, must be
relative, and must not leave the repository.

## Chore tasks

### For consumers (`vm.chores.yml`, included as `vm`)

| Task | What it does |
| --- | --- |
| `chore vm:up` | Boot the shared guest if it is not up, apply this consumer's setup, and **hold** it: the guest deadline is cancelled, and it stays up until `vm:down`. |
| `chore vm:run -- <command>` | Run a command as root in the guest (booting if needed). Exit status and stdout/stderr are the guest command's. Operators like `&&` and `\|` belong to the guest. |
| `chore vm:exec -- <command>` | The same, in a VM that is ALREADY up — and it never boots one. The per-call path for a test process: no state probe beyond a process check, and one multiplexed SSH connection shared by every call. Smoke measures the complete call against calls without reuse. Fails naming `chore vm:up` when nothing is running. |
| `chore vm:put <file>` | Copy a file into the shared directory; print its guest path (`/share/<name>`). |
| `chore vm:share` | Print the host path of the shared directory. |
| `chore vm:test [-- args]` | Boot the shared guest if needed and run the `[test] command` on the HOST, as a run of its own. Its status is the command's; the guest stays up for the next run. |
| `chore vm:guest-test [-- args]` | The same for the `[test] guest_command`, run INSIDE the guest from `/repo`. For a suite whose host cannot run it. |
| `chore vm:session -- <command>` | Run a command on the HOST inside a session: one run on the shared guest, ended when the command ends — passed, failed or killed. What a consumer's test runner calls as `vm.sh session <command...>`; see [rule 2](#talking-to-the-guest-from-a-test-process). |
| `chore vm:provision` | Re-run this consumer's setup script, changed or not, in the running guest. The guest is not stopped for it. |
| `chore vm:reload` | Restart the shared guest in place, unless another suite is using it. |
| `chore vm:down` | Stop the shared guest and **confirm** it stopped, unless a suite is using it: then it says who and succeeds, leaving the guest up. Fails if the guest is still running or its state cannot be read. |
| `chore vm:status` | Exit 0 when the shared guest is running, 1 otherwise, and say which, and who is using it. |
| `chore vm:hold` | Mark the guest as deliberately running (its deadline stands down). |
| `chore vm:reap` | Stop a guest whose boot did not finish, and drop suites that have gone from the list. Meant for `lifecycle: after_all`. An idle shared guest is not a leak, and stays up. |
| `chore vm:destroy` | Delete the shared guest and its disk, unless a suite is using it. The box stays in Vagrant's store, so the next boot does not download it again. |
| `chore vm:config` | Print the resolved config, the shared guest's machine, its QMP socket (`qmp=`), the run a call outside any session uses (`run.standing=`) and how many trees can be attached at once (`slots=`). |
| `chore vm:host:check` | Check the host; print the exact install command for anything missing. |

### For the harness itself (`chores.yml`)

| Task | What it does |
| --- | --- |
| `chore check` | The VM-free self-test: `bash -n`, shellcheck, every unit test. CI job `unit`. |
| `chore smoke` | Boot a real VM and drive every command through it (`tests/smoke.sh`). CI job `smoke-x86_64`. Needs KVM or HVF. |
| `chore smoke:destroy` | Delete the smoke run's shared guest, which lives in a cache directory of its own. |
| `chore host:check` | Check this host. |

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `FLTH_CONFIG` | search upward | Path of the consumer's config. |
| `FLTH_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/fs-linux-test-harness` | Machines (`machines/shared-<guest>/`) and firmware links. Must be the same for every consumer on the host, or each gets a guest of its own. |
| `FLTH_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/fs-linux-test-harness` | Sockets and Vagrant's temporary directory, on a path short enough for a socket. |
| `FLTH_SHARED_SLOTS` | `32` | How many runs' trees can be attached to the shared guest at once: the free PCIe root ports it boots with, 1–64. A run past it is refused, naming the setting. |
| `FLTH_VIRTIOFSD` | `virtiofsd` on PATH, then `/usr/libexec/virtiofsd` | The virtiofsd that serves a run's tree. |
| `FLTH_SHARED_MEMORY`, `FLTH_SHARED_CPUS`, `FLTH_SHARED_DISK` | `8G`, `8`, `64G` | The size of the shared guest. |
| `FLTH_SHARED_DEADLINE` | `480` | Minutes the shared guest stays up **with nothing asking anything of it**, unless held. Every `run` and `exec` re-arms it when the call starts and when it ends, so a suite of many calls is never cut off however long it runs; only a single call longer than this is. The setup call re-arms it too. The guest takes new logins until it powers off. Re-arming happens at most once in a sixth of this, and at most once a minute, so the poweroff can fall up to that much early. |
| `FLTH_SHARED_MIN_AVAILABLE` | `2048` | MiB of the shared guest's available memory below which a suite joining it is told the numbers and who is using it. |
| `FLTH_WATCHDOG` | on | `off` starts no [watchdog](#what-stops-a-vm) with a guest. |
| `FLTH_WATCHDOG_INTERVAL` | `60` | Seconds between the watchdog's looks at a guest. |
| `FLTH_WATCHDOG_WARN_SECS` | `300` | Seconds a process goes in uninterruptible sleep with no progress before it is warned of. |
| `FLTH_WATCHDOG_STUCK_SECS` | `1800` | The same, before the watchdog ends the guest. |
| `FLTH_WATCHDOG_SILENT_SECS` | `600` | Seconds a guest goes without answering before the watchdog ends it. |
| `FLTH_WATCHDOG_LOW_PERCENT` | `5` | Memory or disk left, as a percentage, below which it warns. |
| `FLTH_SSH_PERSIST` | `3600` | Seconds the shared SSH connection to the guest stays open when idle. |
| `FLTH_GUEST` | set by the harness | `1` in every command the harness runs in the guest. Read it, never set it: it is how a program tells that it is already inside the test VM. |
| `FLTH_PROFILE` | `[vm] profile`, or none | Select a named run profile for this suite and its whole session. |
| `FLTH_PROFILE_DIR` | `<consumer>/run-profiles` | Host directory containing profile manifests and their pinned preparation scripts; use one catalog across repositories if desired. |
| `FLTH_FIRMWARE_CODE`, `FLTH_FIRMWARE_VARS` | `/usr/share/AAVMF/AAVMF_{CODE,VARS}.fd` | UEFI firmware for arm64 guests on a Linux host. |

## The VM

The guest architecture is the host's, and hardware acceleration is
required: a VM emulated in software is a suite that takes an hour and
times out somewhere unhelpful, so the harness refuses rather than
falling back.

| Host | Accelerator | Box | Vagrant provider plugin | Firmware | Shared directory |
| --- | --- | --- | --- | --- | --- |
| macOS, Apple Silicon | HVF | `christhomas/vagrant-rpi-bookworm-arm64` | `vagrant-qemu-christhomas` + `vagrant-notify-forwarder-christhomas` (forks that fix Mac-specific problems) | Homebrew QEMU's | virtiofs, attached per run |
| Linux aarch64 | KVM | `cloud-image/debian-12` (arm64), pinned | stock `vagrant-qemu` | `FLTH_FIRMWARE_*` (Debian: AAVMF) | virtiofs, attached per run |
| Linux x86_64 | KVM | `cloud-image/debian-12` (amd64), pinned, q35 | stock `vagrant-qemu` | none (SeaBIOS) | virtiofs, attached per run |

**Apple Silicon smoke runs have been recorded.** On 2026-11-03,
`tests/smoke.sh` ran six times during the work on #84, using
virtiofsd 1.14.0, `vagrant-qemu-christhomas` 0.6.0 and
`vagrant-notify-forwarder-christhomas` 0.7.5 (#86, #89). With the #86 fix,
two of three runs passed all 95 checks; the third failed only the exec
cost check tracked in #83 (299ms against its 250ms limit). All six runs
passed both `O_DIRECT` checks. This records a working smoke path with
those versions, not a promise that every Mac smoke run passes: #83 still
fails on some runs.

The Linux x86_64 row is proven by CI's smoke job on every pull request,
and the Linux aarch64 row by `chore smoke` on an arm64 host. The
`macos-host` workflow installs the host setup below on an Apple Silicon
runner and validates the Vagrantfile under the real forked provider, but
cannot boot: GitHub's macOS runners have no nested virtualisation, so no
HVF. The Mac boot evidence above comes from the recorded host runs, not
that workflow. With virtiofsd before 1.14.0, which
`chore vm:host:check` now refuses, a file on either virtiofs share cannot
be opened with `O_DIRECT` (#26; see "Where a tool works on an image").

**No host file events reach a macOS guest.** The forwarder plugin stays
enabled, because the macOS boot needs it, but the harness replaces its guest
receiver with one that exits, so `inotify` in the guest does not see the host's
changes to a share. The receiver up to notify-forwarder v1.1.0 writes into the
files an event names and truncates one it reads as empty, which can empty a file
the host has just written (#84). v1.2.1, from plugin 0.7.7, no longer writes data,
and the replacement stays for the reasons recorded in `vagrant/Vagrantfile` (#87).
Measured on 2026-11-04 on an Apple Silicon host, in one guest:

| Receiver | Payloads the host wrote that ended wrong | Streams the guest wrote that read back wrong |
|---|---|---|
| v1.1.0 | 11 of 168 empty | 35 of 992 |
| v1.2.1, started after the shares are mounted | 0 of 168 | 0 of 992 |
| none | 0 of 168 | 0 of 992 |

**A macOS boot's forwarder processes end with it.** `vm.sh down` and `vm.sh
destroy` stop them, and so does the end of a session on a guest that powered
itself off (#82, #135). Plugin 0.7.7 runs one watcher per machine in place of two,
and stops it itself, or within about 15 seconds of its guest no longer answering.

**The box is not published.** It is not in the public Vagrant registry,
and its GitHub release is in a private repository, whose download URL
answers 404 to Vagrant. `chore vm:host:check` says so and prints the
command that adds a copy of the `.box` file by hand.

**Why virtiofs on Linux too:** a run's tree is attached while the guest runs, and
QEMU has no way to add a 9p device's backend at runtime, only from its command line.
The stock provider has no virtiofs support of its own, so the harness starts the
distribution's virtiofsd itself, unprivileged and with no sandbox, and attaches the
device through QMP (see [One guest for every consumer](#one-guest-for-every-consumer)).
The Linux aarch64 path is untested: its guest boots UEFI with ACPI, so it takes the
same `device_del` as x86_64.

**Where state lives:** there is one machine for each guest release,
`FLTH_CACHE_DIR/machines/shared-<guest>/`, outside every repository; the
harness checkout is never written to. Every consumer on the host uses it
(see [One guest for every consumer](#one-guest-for-every-consumer)). Boxes
are shared in Vagrant's own box store.

**Every run starts from the same disk.** The machine's disk is the box's
and carries nobody's setup. Every boot is **disposable**: QEMU opens the
disk read-only (`snapshot=on`) and sends every write to a temporary overlay
under `FLTH_STATE_DIR/tmp`, unlinked as soon as it is open, so it is gone
when the VM stops however it stops. A mount, a loop device, a half-finished
install or a full `/var/tmp` that one boot leaves behind cannot be seen by
the next. Within a boot, each run has its own `/tmp`, `/var/tmp` and `/mnt`
(below). Teardown inside a suite is a courtesy, not the guarantee: it does
not run when a test crashes halfway, which is when the state it would have
cleaned up is worst.

**What the guest deletes goes back to the host.** The overlay is on the
host's disk and grows with each block the guest touches. The drive takes
`discard=unmap` and the guest's root is remounted with `discard`
(`vagrant/guest/online-discard.sh`), so a freed block leaves the overlay soon
after the guest's filesystem commits. Measured through QEMU's monitor on an Apple
Silicon host, after writing and deleting 1 GiB twice: 1.33 GiB of overlay before
this, 25.3 MiB after. On a KVM runner the overlay read up to 1802 MiB straight
after a `sync` and 11 MiB three seconds later, having written and deleted 14336
MiB by then. What a suite keeps is still on the host's disk, and a host with too little for it
pauses the guest; `vm.sh` then says so (below).

Each consumer's setup script runs when it joins a boot, on that boot, and
goes with it: after the guest stops, each consumer's setup runs again when
it next joins. Install what every run needs in the setup script; put what
should outlive the guest on the share or in the repository mount, both of
which live on the host. A declared cache (`[cache] size`) is a directory of
the guest's and lasts as long as the guest does.

**A kernel the setup script installs is never run.** The shared guest does not
restart for one consumer's setup, so a setup that installs a kernel the guest
is not running fails that consumer's join, naming both kernels (#157, #207).

**A boot that fails shows the guest's console.** The provider sends the
guest's serial console, where its kernel and init write, to a socket
nothing reads, so a boot that never answers SSH used to end with
Vagrant's "Timed out while waiting for the machine to boot" and nothing
else. QEMU now also logs that console to
`machines/<project>/console.log`, afresh on every boot, on every host.
When a boot attempt fails, `up` prints its last 60 lines to stderr
before it retries or gives up, each labelled, so a CI log tells a kernel
panic from a root that never mounted from a network that never came up.
For a guest whose kernel could not mount its root, it reads:

```text
[vm] the guest's console, the last 60 lines of <FLTH_CACHE_DIR>/machines/<project>/console.log:
[console] [    2.481193] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
[console] ...
[vm] boot failed, retrying in 5s (attempt 1 of 3)...
```

The file stays after a boot, failed or not, until the next one starts.

**A box that cannot be fetched is not a failed boot.** No VM started, so
there is no console to read and the three attempts above do not apply.
When Vagrant reports that the box catalog or the box's download failed with
a 5xx, a 408, 425 or 429, or no answer at all, `up` waits 30, 60 and then 120
seconds between tries, for 15 minutes at most. It then fails
naming the catalog and what it answered:

```text
vm: the box could not be fetched: the box catalog https://vagrantcloud.com/cloud-image/debian-12 answered HTTP 503, and was still failing after 900s. No VM was started.
```

Any other 4xx is an answer waiting will not change, and takes the ordinary
boot retries.

### The engine interface

Everything the harness decides is written against a small interface
([`scripts/lib/engine.sh`](./scripts/lib/engine.sh)): `engine_prepare`,
`engine_identity`, `engine_state` (running / stopped / absent /
**unknown**), `engine_up`, `engine_down [--force]`, `engine_destroy`,
`engine_run`, `engine_copy`, `engine_alive`, `engine_console_log`,
`engine_box_failure`,
`engine_vm_status`, `engine_guest_answers`, `engine_overlay_dir`. Vagrant is the only
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
and later commands ride it. The master
is opened on purpose rather than grown out of the first command — a master
that inherits a command's stdout keeps it open for as long as it persists,
so a caller capturing the output of a one-second call would wait an hour
for end-of-file. It is closed before a boot and after a stop.

**The complete call is timed, not mistaken for SSH alone.** `tests/smoke.sh`
uses `tests/exec-cost.rb` and a monotonic clock to time ten ordinary `exec`
calls and ten with `ControlPath=none` and `ControlMaster=no`, interleaving
them in alternating order. Every command must succeed. The ordinary average
must be below 250 ms on Linux or 500 ms on macOS, and at least 20% faster
than the measured calls without reuse; meeting the fixed budget alone does
not establish reuse.

On an Apple M1 Max with a Debian 12 HVF guest on 2026-11-03, ten interleaved
calls per version averaged 456.3 ms before candidate-only process inspection
and 291.1 ms after it. The old 250 ms assertion failed even though SSH's
`mux_client_request_session` confirmed use of the master. The full
`ps -eo args=` scan alone measured 65.5 ms per call in a separate twenty-call
sample, before the shell copied and scanned its output. Loading the libraries,
then the configuration, then preparing the engine measured 9, 31 and 43 ms
cumulatively in a separate ten-call sample. Raw reused SSH measured 12–23 ms;
raw fresh SSH measured 108–141 ms across two ten-call samples.

The revised smoke check measured 366.3 ms against 522.0 ms with reuse disabled
and passed. Forcing fresh SSH in both modes measured 544.3 ms against 482.0 ms
and failed both the budget and reuse comparison. These are measurements of
that host under changing load, not universal SSH or wrapper latencies.

**Sockets live on a path the harness controls.** A Unix socket path is
limited to about 104 bytes. The ssh control socket is under
`FLTH_STATE_DIR/ssh/`, and on macOS `vagrant up` runs with `TMPDIR` set to
`FLTH_STATE_DIR/tmp`, where the QEMU provider creates its virtiofs sockets
— never the caller's `TMPDIR`, which may be a scratch directory deep inside
a checkout. If even that path is too long, the boot is refused with the
path and the length it would reach.

**Unused provider artifacts are reclaimed.** The macOS provider also puts
QEMU's named shared-memory file and virtiofs socket pidfiles in that directory.
The harness checks it before and after start, halt, and destroy, so the next
start also reclaims leftovers from an abrupt exit. Only recognized regular
files owned by the current user are eligible. A process naming an artifact,
an open file, or an unsuccessful process/open-file inspection keeps it.
Inspection uses `ps` and `lsof`; missing `lsof` retains files with a diagnostic,
never guesses that they are unused. A directory-wide advisory lock serializes
cleanup and startup until QEMU appears in the process table; the guest's boot
then proceeds without it.
This mitigates the provider leak tracked in
[vagrant-qemu#9](https://github.com/antimatter-studios/vagrant-qemu/issues/9);
it does not change the separate notify-forwarder lifecycle.

**A boot runs in a process group of its own.** What `vagrant up` leaves running
for the VM is outside the group of the command that booted it, as QEMU is. A
signal to a session ends the command's descendants and leaves a VM that stays up
with its shares; `vm.sh down` and `vm.sh destroy` stop those daemons. A signal or KILL that reaches
`vm.sh up` while the boot is still running stops the boot and what it started.

TERM, INT, and HUP sent to a bare `vm.sh up`, or its process group, also stop
an unfinished guest before `up` releases its boot lock and exits. This does not
need a session or a later harness call: an early guest has not yet armed its own
poweroff deadline. A boot that ignores the signal is killed after five seconds.
KILL cannot run that cleanup; the unfinished-boot marker still lets a later
session end, `reap`, `up`, or `run` deal with the guest it left.

**A boot that did not finish is not a VM to keep.** QEMU starts early in a boot
and the shares are mounted late, so a boot stopped between the two leaves a guest
with no `/share` and no `/repo`. A session's end stops that guest whatever would
have kept it: a hold, another live session or another worktree. So does `vm.sh
reap`. If it is still there, `vm.sh up` and `vm.sh run` replace it,
`vm.sh exec` refuses it and `vm.sh status` says so. A boot that another process is
still running is left alone.

**A signal stops the guest command too.** A command started through `vm.sh run`
or `vm.sh exec` runs in the guest in a process group of its own, and the call's
stdin stays open while the host side lives. When that ends, by a signal, by KILL
or by a lost connection, a watcher in the guest sends TERM to that group and to
the descendants it finds through their parents, and KILL after about five seconds
to what is left. The VM stays up and other calls in that guest keep running. A
call that ended on its own stops nothing, so what it left in the background stays;
so does a daemon that has already left the command's process tree and group.

**A guest that goes away fails the call.** The client keeps the
connection alive (`ServerAliveInterval=15`, `ServerAliveCountMax=8`), so
a VM halted underneath a running command — by its own deadline, by a
`destroy`, by a host out of memory — ends that command in about two
minutes instead of leaving it waiting for ever. The guest's deadline
(`FLTH_SHARED_DEADLINE`) is an idle timeout, re-armed by every call, so it has to outlast your
longest single call — a whole `vm:guest-test` run is one call — not your
whole suite.

**A lost connection says what stopped the guest.** ssh's own failures are
status 255, and Vagrant's ssh settings keep ssh quiet about them. When `run`,
`exec`, `guest-test` or a setup script gets 255, `vm.sh` keeps that status and
prints on stderr, before any teardown frees the evidence, what it found:

```text
vm: exit 255: ssh lost its connection to the guest, or the command itself exited 255.
vm: what stopped it: QEMU paused the guest.
vm: a write to the guest's disk failed. The overlay grows on the host's disk, and a full host disk stops a guest this way.
vm: QEMU says: VM status: paused (io-error)
vm: QEMU says: I/O status: nospace
vm: 16 MB free on the host's disk holding the overlay (<FLTH_STATE_DIR>/tmp); the overlay is 3.49 GiB.
[vm] the guest's console, the last 20 lines of <FLTH_CACHE_DIR>/machines/<project>/console.log:
```

The other answers are a guest that powered itself off, a QEMU that ended with
no power-off on the console, a guest that does not answer, and one that does,
where ssh cannot tell a lost connection from a command that exited 255 itself.

## Run profiles

A suite can declare the prepared environment it needs without changing another
suite's VM. A run profile can isolate tools, system settings or a kernel.
Put `profile = "kernel-oracle"` in its config's `[vm]` section, or
select a profile for a tier with an environment variable:

```sh
FLTH_PROFILE=kernel-oracle chore test:vm
FLTH_PROFILE=another-kernel chore test:vm
```

Each selection applies to the whole session, including its `up`, `run`, `exec`,
`down` and `destroy` calls. Keep that environment for the session's lifetime.
`vm.sh config` reports the selected profile, release, required modules,
fingerprint and machine path; `status` also names the profile.

Create `run-profiles/kernel-oracle.toml` beside the consumer config:

```toml
[profile]
guest = "debian-12"
modules = "loop"
setup = "prepare.sh"
setup_sha256 = "<64 lowercase hex digits from the preparation script's SHA-256>"

[x86_64]
release = "6.12.57+deb12-amd64"

[aarch64]
release = "6.12.57+deb12-arm64"
```

These releases illustrate the format: choose releases available from your
pinned package source or kernel artifact. The manifest uses the same strict
quoted-string TOML subset as the consumer config. `[profile]` is required;
`[x86_64]` and `[aarch64]` override its fields for the host architecture. A common
`release` is also allowed. Omit it from every section to retain the pinned box's
kernel; preparation changes alone still allocate a separate VM. Once any section
pins a release, every supported host architecture must resolve an exact release.
Unknown or duplicate sections and keys, invalid module names and missing pinned
releases fail before an engine is touched. `modules` is
a whitespace-separated list of names, not paths; ordering and duplicates do not
change the identity. The profile's `guest` takes precedence over `[vm] guest.
The existing macOS restriction still applies: its base guest must be Debian 12.

The preparation script lives inside the manifest's directory and runs as root
before any consumer joins. It receives `FLTH_GUEST=1`, `FLTH_KERNEL_RELEASE` and
`FLTH_KERNEL_ARCH` (`x86_64` or `aarch64`). `FLTH_KERNEL_RELEASE` is empty when
the profile keeps the box's kernel. When a release is pinned, install that release's
kernel, initrd and matching modules at `/boot/vmlinuz-<release>`,
`/boot/initrd.img-<release>` and `/lib/modules/<release>`. For example, after
configuring a pinned package source, a Debian preparation can install
`"linux-image-$FLTH_KERNEL_RELEASE"`. Keep package or artifact versions and
download checksums in the script: its checksum pins the script's bytes, not
whatever an unpinned download might return. Compute `setup_sha256` with
`sha256sum prepare.sh` on Linux or `shasum -a 256 prepare.sh` on macOS. Scripts
are limited to 64 KiB. Omit both `setup` and `setup_sha256` when the pinned box
already contains the environment required by the profile. For a preparation-only
profile, the complete manifest can be:

```toml
[profile]
setup = "prepare-tools.sh"
setup_sha256 = "<64 lowercase hex digits from prepare-tools.sh>"
```

The first suite takes the profile's boot lock and prepares a persistent disk.
For an explicit release, the harness checks the installed kernel, initrd, module
directory and module dependencies and copies the exact boot files and root
command line to the host. A preparation-only profile keeps the box's boot files
and records its running release instead. Both paths flush the guest and confirm
it stopped. Only then is preparation recorded as
ready. A failed or interrupted preparation is rebuilt on retry. Later boots
check the cached boot files' integrity, boot the selected kernel with matching
initrd and disk, check `uname -r`, and load every required module before admitting
consumers. Corrupt cached files fail with instructions to destroy that selected
profile and prepare it again.

Every test boot remains disposable. Each consumer's ordinary `[setup]` still
runs once per boot and its writes disappear when that boot ends. Put differences
that require separate VMs in the profile preparation; use consumer setup for tools
that can coexist in one guest. The existing refusal of a consumer setup that installs another
kernel still applies.

Profiles share by resolved content: architecture, base guest, exact release,
required modules and preparation bytes. Identical profiles in different
repositories or under different aliases share a VM; different contents get
different machines (`machines/shared-<guest>-p<fingerprint-prefix>/`). A changed
profile never replaces an active guest. Its old guest finishes its sessions and
idle deadline independently; use the old manifest to address it explicitly.
Each profile has its own boot lock, suite list, lifecycle and hotplug devices.
The existing host memory admission check applies before every preparation or
runtime boot. Profiles do not reserve a machine-wide slot.

Set `FLTH_PROFILE_DIR` to a common catalog directory when several repositories
use the same definitions. Without a profile, the existing pinned guest and
`machines/shared-<guest>/` identity are unchanged.

## One guest for every consumer

Consumers using the same run profile share **one guest**. Without a profile,
consumers selecting the same base guest keep sharing its default VM.
Nothing has to be set for it:

```sh
chore test:vm      # in one consumer
chore test:vm      # in another, or another worktree of the same one, at the same time
chore vm:down      # when you are done: stops it if nobody is using it
```

**Each run attaches its own tree** to the running guest (#222): a `vhost-user-fs`
device served by a virtiofsd of its own, hot-plugged into one of the free PCIe root
ports the guest boots with (`FLTH_SHARED_SLOTS`, 32), tagged with the run's id, and
mounted at `/repo` in the run's namespace. `/share` is the consumer's `[share] dir`
in that tree. So a tree anywhere on the host can be tested: a worktree on another
volume or under `/tmp` included, and there is no host directory to set. Attaching
takes about a fifth of a second. A session's run is attached at its first call and
detached when it ends; a call outside any session uses its worktree's standing run,
which stays attached as long as the guest runs. `vm.sh reap` detaches the device of
a run whose session died without ending it.

**A run's virtiofsd never goes while the guest can use its mount.** A request the
guest sends after the daemon has gone never completes, and removing that device then
wedges PCI hot-plug and every new virtiofs mount in the guest until it reboots. So:

- the daemon runs in a session of its own, where no signal to a suite reaches it;
- a run ends in the guest first: its processes are stopped, the loop devices backed
  by its tree detached, and its namespace dropped. Only then is the device removed,
  then its chardev, and only then is the daemon stopped, if it has not stopped by
  itself;
- a daemon that has gone anyway is found by the watchdog each minute and by the next
  call of its run. Its device is removed at once, before anything else runs in that
  run; then the run is ended, and its suites end with **status 75**, saying why.

On a Linux host the device is removed with `device_del`, which q35's ACPI hot-plug
takes in tens of milliseconds. The macOS guest has no ACPI, and its kernel waits five
seconds after `device_del`, so the guest is asked to power the slot off itself, about
a second.

Every consumer joining one boot needs the same harness version: a join from another
is refused, because the guest was given the version's `guest-run.sh` when it booted.

**One boot, each consumer's own setup.** The first suite boots the guest. The machine
is `machines/shared-<guest>/`, so a consumer naming another `[vm] guest` gets a guest
of that release. Its size comes from `FLTH_SHARED_MEMORY`, `FLTH_SHARED_CPUS` and
`FLTH_SHARED_DISK`, and its idle deadline from `FLTH_SHARED_DEADLINE`, not from a
consumer's `[vm]` section. Each consumer's `[setup]` script runs when that consumer
first joins a boot, one at a time, and tools install alongside each other. Nothing
merges the scripts, and two versions of one tool are not provided for. A setup that
installs a kernel the guest is not running fails that consumer's join, naming both
kernels, because the shared guest does not restart for one consumer (#157, #207).
Setup stays with the boot: after the guest stops each consumer's setup runs again
when it joins. A run profile's preparation is the persistent base beneath
these disposable boots.

**The host's memory is checked before every boot attempt.** A guest asks for
gigabytes, and a full machine does not fail cleanly: it kills background work
with no message connecting the two. So a boot needs the guest's memory plus
**2048 MiB left for the host** in what the host has available: Linux's
`MemAvailable`, or macOS's free, inactive and speculative pages at the page size
`vm_stat` reports. A boot the host has no room for is refused, naming the numbers;
a measurement that could not be made refuses too.

**A suite joining a guest with little memory left is told** (#185): the guest's own
`MemAvailable`, its total, and the suites using it, when what is available is under
`FLTH_SHARED_MIN_AVAILABLE` (2048 MiB). It still joins. Size the guest from what its
suites use at once: measured on an Apple Silicon host, three suites (two compiling
their whole suites, one running tests) peaked at 6960 MiB used of a guest's memory,
with 2986 MiB still available; six at once, three of them compiling in release, ran a
10G guest out of memory, and its kernel killed processes. `FLTH_SHARED_MEMORY` sets
the size at the next boot.

**A guest whose kernel has oopsed keeps answering** (#196), so a suite on it can go on
and report what follows as its own result. A suite joining such a guest (`vm.sh up`),
and a session ending on it, is told so, naming the first oops in the guest's console
and the process it hit, and where the console is. `chore vm:down` and a new boot give
a kernel that has not.

**The guest stays up between runs**, so a run does not pay for a boot. A suite
registers when its session begins and deregisters when it ends.

- `chore vm:status` lists the suites using the guest.
- A `vm.sh run` or `vm.sh exec` outside any session is on that list for as long as it
  lasts.
- `chore vm:down` stops the guest only when that list is empty. Otherwise it says
  who is using it, leaves the guest up and succeeds.
- A suite that was killed outright never deregisters. Its entry records its
  process, and is dropped before anyone counts.
- `chore vm:destroy` is refused while the list is not empty.
- With nothing asking anything of it, the guest powers itself off after
  `FLTH_SHARED_DEADLINE` minutes, 480 by default.

Registering, booting and the shutdown check take the same lock, so a suite that
registers during a shutdown waits for it and then boots a new guest, and two
suites that both find no guest boot one.

**Each run has its own files.** A session is a run, with a random root on the
guest's own disk, `/var/lib/fs-linux-test-harness/runs/<id>/`, which `FLTH_RUN_ROOT`
names. Its commands run in a private mount namespace where that root's directories
are mounted at `/tmp`, `/var/tmp` and `/mnt`, so a suite's scripts keep the paths they
already use and cannot see another run's.

`/var/cache` is the consumer's, under `/var/lib/fs-linux-test-harness/consumers/`, and
lasts as long as the guest. That is where the family's suites keep their build
directories, so a second run does not build from nothing. A second run of one consumer
at the same time has its own empty one, because two runs cannot share a build directory.
A package registry a suite keeps on the guest's own disk, under `/var/lib` or `/var/cache`,
lasts too.

`guest-test` also copies the tree into the root and mounts the copy at `/repo`,
leaving out `tmp/`, the share and any directory marked with a `CACHEDIR.TAG`. Calls
made by a suite on the host see the live checkout, because that suite writes files
there for the guest to read. A call outside any session uses a standing run of its
worktree, which lasts as long as the guest.

A consumer that declares a cache (`[cache] size`) has `/cache` as a directory on the
guest's own disk, kept across its runs for as long as the guest is up, with no size limit
of its own. The machine has no second disk.

**The end of a run** stops every process in its namespace, TERM and then KILL, detaches
the loop devices backed by its root, and deletes the root. That is what a signal to
one suite does to its commands in the guest, and no other run is touched. A process
that no signal ends, one in uninterruptible sleep (state D), which only a reboot
clears, is named with its state and where in the kernel it waits, and the end goes on
without it: the run's `/var/cache` is freed and its root deleted, and each step that
could wait on it is bounded (#187). If the guest
is lost, every suite using it is named in the report on stderr.

**What a path does not separate.** All runs share one kernel:

- A kernel a consumer's setup installs is not the one running, because the guest does
  not restart for it.
- A kernel crash, or anything that powers the guest off, stops every suite.
- Loop device numbers come from the kernel on request, so a suite that asks with
  `losetup -f` is fine, and one that names `/dev/loop0` or runs `losetup -D` is not.
- Unloading a kernel module, or anything else that changes the kernel for everyone,
  reaches the other suites too.

Issue #157 lists the consumers that do any of these today.

## What stops a VM

In order of precision:

1. **`down`** — `chore vm:down` or a chore `defer:`, which stops the shared guest
   only when no suite is using it, and fails loudly when the guest will not stop.
   A **session's end** — `vm.sh session <command...>` finishing, or the exit trap of
   a script that sources it — ends its run and stops nothing else, unless the boot it
   started did not finish: that guest has no shares, and is stopped.
2. **`reap`** — from `lifecycle: after_all`. It stops a guest whose boot did not
   finish, and drops suites whose process has gone from the list. An idle shared
   guest is not a leak: it is there for the next run, and `reap` leaves it. Fails
   soft, so an unrelated `chore build` is not turned red.
3. **The guest's own deadline** — scheduled inside the guest at every boot
   (`FLTH_SHARED_DEADLINE`), confirmed from logind's record, and re-armed
   by the setup call, `run` and `exec` as the call starts and as it ends (at
   most once a minute, or once in a sixth of a shorter deadline), so it measures
   idleness rather than the boot's lifetime. logind's `/run/nologin` for a
   shutdown's last five minutes does not stop the harness reaching the guest:
   `deadline.sh` comments `pam_nologin` out of the guest's `/etc/pam.d/sshd`. The
   one net that works when the host process is hung or killed.

4. **The watchdog** — one process on the host for a running guest, started with it
   and ended with it. Each minute it asks the guest about memory, disk and processes
   in uninterruptible sleep, and writes what it sees to `watchdog.log` in the machine
   directory; `chore vm:status` shows the last of it. A warning names the process and
   its suite and stops nothing. So does what the kernel writes on the console, which
   is read on the host: an oops, a soft lockup, a hung task, an RCU stall or a panic,
   and a taint that says one happened. A guest that has stopped answering, or a process that
   has made no progress past its limit, which only a reboot can clear, ends the guest,
   whichever suite it belongs to. Every suite on that guest then
   ends with **status 75** and a message naming the reason, so an interrupted run is
   not read as a failure of what it was testing. A process doing heavy I/O is in the
   same sleep for hours, so progress is measured by its time on the CPU and its bytes
   read and written, not by the state alone. The limits are settings.

`hold` (and `chore vm:up`) cancels 3 for a person working in the guest: the guest
stays up until `down` or `destroy` clears the hold. A reboot re-arms the deadline.

## Host setup

`chore vm:host:check` says what is missing on this host. In full:

**macOS (Apple Silicon)**

```sh
brew install --cask hashicorp/tap/hashicorp-vagrant
brew install antimatter-studios/tap/qemu antimatter-studios/tap/virtiofsd   # virtiofsd 1.14.0 or newer
vagrant plugin install vagrant-qemu-christhomas
vagrant plugin install vagrant-notify-forwarder-christhomas --plugin-version 0.7.7
# the box (christhomas/vagrant-rpi-bookworm-arm64) needs no step: the first
# boot fetches it from its public GitHub release (#8)
```

**Linux x86_64** (a CI runner does all of this with `scripts/ci-setup-linux.sh`)

```sh
sudo apt-get install qemu-system-x86 qemu-utils virtiofsd
# Vagrant 2.4.9 from HashiCorp's apt repository, then:
vagrant plugin install vagrant-qemu --plugin-version 0.6.3
# and read-write /dev/kvm (the kvm group)
```

**Linux aarch64.** `apt-get install qemu-system-arm qemu-utils qemu-efi-aarch64 virtiofsd`
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

The VM-free checks run with the host's system Bash and Ruby (including
macOS Bash 3.2 and Ruby 2.6). Install `shellcheck` and `timeout` as well
(`brew install shellcheck coreutils` on macOS). The stub engine executes
Debian guest scripts locally, so it separately needs Bash 4.2 or newer:
on macOS, install `bash` and run
`FLTH_TEST_GUEST_BASH="$(brew --prefix bash)/bin/bash" chore check`.
That selects only the guest interpreter; the host scripts still use
`/bin/bash`. A missing or incompatible guest interpreter fails once,
before the suites start, with the requirement named.

`new_sandbox` uses an explicit `mktemp` template under `TMPDIR`. Tests
that need Unix sockets use a short directory under `/tmp` by default;
set `FLTH_TEST_SOCKET_ROOT` to another short scratch root to keep those
directories elsewhere. The production 103-byte socket limit is unchanged.

Every pull request and every push to `main` runs
[`.github/workflows/ci.yml`](./.github/workflows/ci.yml):

| Job | Runs on | What a green run proves |
| --- | --- | --- |
| `unit (VM-free, OS)` | `ubuntu-latest` and `macos-15` arm64 | `chore check` with each host's system Bash: every script parses and is shellcheck-clean; the config reader accepts the shipped configs and refuses invalid ones with clear errors; the orchestration against a stub engine (the shared guest's default root, worktrees, the list of suites, the host memory check, boot retries, never taking an unread state for a stop, setup stamping, hold/reap, the session rules); the Vagrant engine against stub `vagrant`/`ssh`/`ps`; the guest deadline script; the Vagrantfile evaluated for all three hosts with hostile inputs refused; and that the harness names no filesystem. |
| `smoke (real VM, x86_64 KVM)` | `ubuntu-latest` with KVM | `chore smoke`: a real Debian VM boots through the harness under KVM; the smoke consumer's setup installs `e2fsprogs` inside it; the machine is the shared guest's and sees the directory holding the checkout, with nothing set; a run that leaves a file, a loop device and a mount behind changes no byte of the machine's disk, and the next boot sees none of it; exit status, output and files cross host↔guest; the reaper leaves the shared guest up; a consumer whose setup installs a kernel is refused; two consumers join one guest at once; a realistic suite (build an ext4 image from host files, read back with `debugfs`, compare, `e2fsck -fn`, collect results on the host) **passes**; the same suite with one byte of file data corrupted **fails with a non-zero exit**; `down` and `destroy` behave. |
| `ci-ok` | `ubuntu-latest` | Green only if every job above ran and succeeded (a failed, cancelled **or skipped** job fails it). |

**The required status check is `ci-ok`.** Branch protection and
auto-merge should require that one name and nothing else, so adding a
job later never needs a settings change. Superseded runs on the same
pull request are cancelled.

The arm64 path (Linux aarch64 under KVM) is proven by `chore smoke` on an
arm64 host rather than in hosted CI: GitHub's hosted arm64 runners do not
expose KVM (checked by the manual `kvm-probe` workflow). The macOS path
has the Apple Silicon smoke evidence recorded under "The VM" (#84, #86,
#89), with the remaining intermittent exec cost failure tracked in #83.

GitHub's hosted macOS runners cannot boot it either: they are M1 virtual
machines with no nested virtualisation, so HVF is unavailable. The
[`macos-host`](./.github/workflows/macos-host.yml) workflow takes it as far
as a hosted runner can, on `macos-15` (arm64), whenever the Vagrantfile,
`host-tools.sh` or the Vagrant engine changes: the macOS host setup
installs, QEMU has the `vhost-user-fs` device, `host:check` names the
unpublished box and nothing else, and `vagrant validate` accepts the
Vagrantfile under real Vagrant and the forked provider. It records whether
the runner can start an HVF guest, and warns if one ever can. It is not
part of `ci-ok`.

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
`rust-fs-ext4`, `rust-fs-xfs` and `rust-fs-btrfs` (`scripts/vm.sh`, a
`vm-slot.sh` since removed, `vm-session.sh`, `tests/vagrant/debian/Vagrantfile`). Each
copy had fixes the others lacked; this repository takes the most correct
version of each behaviour and removes everything filesystem-specific.
The consumers move onto it together, each in its own pull request.
