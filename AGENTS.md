# Working in fs-linux-test-harness (agent guide)

A generic Linux test VM for repositories that need a real Linux kernel and
real Linux tools to test against. It owns the VM's lifecycle (`up`, `run`,
`exec`, `put`, `down`, `reap`, `hold`, `destroy`), the machine-wide slot lock
that keeps one VM running per host, the shared directory, the consumer
repository mounted at `/repo`, and the guest's own poweroff deadline. It knows
nothing about what a consumer tests: no filesystem, no toolchain, no package.
A consumer checks it out as a sibling (`../fs-linux-test-harness`), pinned by
tag, includes `vm.chores.yml`, and brings its own setup script.

This file is the fast path for an agent picking up work here. It points at the
existing docs rather than duplicating them:

- **README** → `## The contract`, `## Consumer test contract`, `## The VM`,
  `## The slot lock`, `## What stops a VM`, `## CI and automated merging`.
- **CHANGELOG.md** → what each tag contains, and `[Unreleased]`.
- **`.github-guard`** → the one required check, `ci-ok`.

The section between the BEGIN/END markers below is **shared, byte-identical,
with every repository in this family**. Do not edit it here: change the
canonical copy and propagate it, or `scripts/agents-core-check.sh` will fail.
Everything after the END marker is specific to this repository.

<!-- BEGIN SHARED BLOCK: agent-core v2 sha256:38af4d2c5377d38ab382baa4eab4aa679841e2b4eba4f4d01dacd255ffa7d32e -->
## Claiming work

Several agents work these repositories at the same time. Before you start on
an issue, claim it, so nobody else spends a session on what you are already
doing. The lock is a **GitHub label**, because labels are shared state that
every agent can read and change without posting comments into the thread.

**Before starting.** Check, claim, then read back:

```sh
gh issue view <N> --json labels                      # holds `claimed`? pick another
gh issue edit <N> --add-label claimed --add-label claim/<session>
gh issue view <N> --json labels                      # read back and confirm
```

`<session>` is your session name — `agent-<random4>-<isodate>`, e.g.
`agent-3f7c-2026-09-22`. Create the `claim/<session>` label if it does not
exist.

**Resolving a race.** Adding a label is not compare-and-swap: two agents can
both add `claimed` and both believe they won. That is what the read-back is
for. If it shows more than one `claim/*` label, the **lexically lowest**
session keeps the issue; every other agent removes its own `claim/*` label and
picks different work. Each racer computes the same answer independently, so no
further coordination is needed.

**When you finish or stop.** Remove both labels — on merge, or the moment you
abandon the work:

```sh
gh issue edit <N> --remove-label claimed --remove-label claim/<session>
```

Delete your `claim/<session>` label from the repository at the end of your
session so they do not accumulate.

**Reclaiming a stale claim.** An agent that dies holding a claim would block an
issue forever. If `claimed` was applied more than 12 hours ago and the holder's
branch has no commits since, any agent may take it: remove the stale `claim/*`,
add your own, and say so in the issue.

**This is a convention, not a fence.** Nothing enforces it. An agent that
ignores it duplicates work; it cannot corrupt anything. Honour it anyway.

## Work in a worktree

Every working copy is a **git worktree** of an existing checkout, made with
`git worktree add`. Never `git clone` a second, unlinked copy — not for a
branch, a PR, a review, or a sibling you need at another ref:

```sh
git -C <checkout> fetch origin
git -C <checkout> worktree add <path> -b <type>/<name> origin/main   # new work
git -C <checkout> worktree add --detach <path> <tag>                 # a sibling at a pinned ref
git -C <checkout> worktree remove <path>                             # when done
```

A worktree shares the checkout's objects and remotes, and `git worktree list`
shows it to every agent on the machine, so nobody else mistakes it for
abandoned work or loses track of it. An unlinked clone copies all the history
again, is invisible to that list, and gets left behind in `/tmp` long after the
work that made it is merged. Remove your worktree when you finish.

## Skills to use

- **`dev-loop`** — the required loop for any non-trivial change: baseline the
  full suite → change → re-run (no baseline test may regress) → enhance tests →
  vet. Always run it.
- **`commit`** / **`pr`** — for grouping commits and opening pull requests.

Each repository names any further skills of its own below.

## A bug fix starts with a red

**Prove it is broken first** — a failing check or test — *then* fix it, *then*
prove that same check is green, *then* confirm the full baseline still passes.
Never write the fix before you have a red. A fix with no failing test to its
name is a claim, not a result.

## Nothing skips

A test that cannot run **fails**, naming the task that would provide what it
needed. Never add an early return for a missing fixture, tool or VM: a skipped
test reads exactly like a passing one, and a suite that quietly declines to run
is indistinguishable from a suite that passes.

Where a tier reports skips or ignored tests, that is a gate, not a note.

## Validate against something that is not us

A driver's own readers share its interpretation of the format, so they cannot
catch a misreading: the mistake is baked into the fixture *and* the parser, and
they agree with each other while disagreeing with every real filesystem. Unit
tests over self-built fixtures prove self-consistency, not correctness.

Every structure that is parsed or written gets a cross-validation test against
an **independent oracle** — the platform's own tools, a real kernel, or a third
implementation — before it is considered done. Each repository names its
oracles below.

## Output is budgeted

Test tiers run through `scripts/tier.sh`, which runs the suite **quietly**: the
whole run goes to `tmp/logs/<tier>.log`, a pass prints one verdict line naming
that log, and a failure prints the verdict, the command's status and the log's
path — `--tail N`, or `OUTPUT_BUDGET_FAIL_TAIL=N`, prints the tail for whoever
is watching. **Read the log**: a failing tier names it and does not recite it.
CI keeps the logs as an artifact, so the detail is always retrievable.

The budget caps the log, not merely what is shown, and every number in the
table was measured. A run that passes but prints more than its budget **fails**.

The reader who pays most for a noisy suite is an agent that re-reads its whole
transcript on every step, and so pays for one loud run many times over. If a
tier legitimately grows, raise its row **with the measurement that justifies
it**. Do not silence output to fit, and do not route around `tier.sh`.

## Commits and branches

- Branches are `<type>/<name>`, matching the commit type: `fix/`, `feat/`,
  `ci/`, `docs/`, `chore/`, `test/`.
- A commit is a subject plus flat one-sentence bullets. Subjects are
  declarative, not imperative: "the run-end bound is checked", not "check the
  run-end bound".
- **No AI attribution and no co-author trailers**, in commits or in pull
  request descriptions.
- `main` takes **squash merges only**.

## Project rules

- **No GPL/LGPL/AGPL dependencies.** Permissive only (MIT/BSD/Apache).
  Shelling out to a copyleft CLI as a *test oracle* is fine — linking or
  copying it is not.
- **Each of these is a standalone project.** Never mention a consuming
  application in the README, the source, or CLI help.
<!-- END SHARED BLOCK: agent-core v2 -->

## Where the shared block does not map cleanly

- **"Output is budgeted"** names `scripts/tier.sh`. There is no `tier.sh`
  here and no output-budget wrapper: the canonical wrapper lives in
  `rust-fs-core`, which consumers resolve at run time, and this repository
  deliberately keeps no copy (CHANGELOG, `### Removed`). The harness's own
  suite is small and prints one `PASS`/`FAIL` line per check. Keep it that way:
  a test that starts printing a transcript is a defect here.
- **"Validate against something that is not us"** means **a real VM**. The
  unit tests drive the orchestration through a stub engine that answers from
  files. That proves the harness agrees with itself, and nothing more. What
  the harness promises about a guest is checked in `tests/smoke.sh`, against a
  booted Debian guest and its own tools: logind for the poweroff deadline,
  dpkg for the package manager's lock, and `mkfs.ext4`/`debugfs`/`e2fsck` for
  a suite that must pass and a corrupted one that must fail. A promise about
  the guest with no smoke check is a claim.

## Running tests

```sh
chore check           # tests/run.sh: bash -n, shellcheck, ruby -c, every test
bash tests/vm.sh      # one test file (VM-free, seconds)
chore smoke           # boots a REAL VM (KVM on Linux, HVF on macOS), up to 60m
chore host:check      # what this host is missing to run the VM
```

`tests/run.sh` finds every `tests/*.sh` by glob, apart from `lib.sh`, `run.sh`
and `smoke.sh`, so a new test file needs no registration. `shellcheck` and
`ruby` are **required**: a missing one fails the run, it does not skip.

CI (`.github/workflows/ci.yml`):

| job | proves |
|---|---|
| `unit (VM-free)` | `chore check` |
| `smoke (real VM, x86_64 KVM)` | `chore smoke` on `ubuntu-latest` with KVM |
| `ci-ok` | the single required check: every job above ran and succeeded |

The Linux aarch64 path is proven by `chore smoke` on an arm64 host by hand
(hosted arm64 runners expose no KVM). **The macOS path has never been
booted** (#8). Do not describe it as working.

**Do not boot VMs from an agent on a shared host** unless you were asked to.
A VM takes gigabytes and the global slot, and it queues every other
repository behind it. Run the VM-free tests locally and let the `smoke` job
boot the guest.

## The house style of a test

`tests/lib.sh` supplies `ok`/`bad`, `check_eq`/`check_contains`/`check_lacks`,
`new_sandbox` (a `mktemp -d` with `FLTH_CACHE_DIR` and `FLTH_STATE_DIR` inside
it, so the real slot and machines are never touched) and `finish <name>`, which
prints `PASS  <name> (N checks)` and sets the exit status.

- **`make_stub_harness`** copies `scripts/` into the sandbox with
  `tests/stubs/engine.sh` as the engine, and puts a no-op `sleep` and a
  logging `shutdown` on `PATH`. A background wait that relies on `sleep` does
  not wait there.
- **The stub engine runs guest scripts on the host**, with the guest's fixed
  paths rewritten into the stub directory: the setup stamp under
  `/var/lib/fs-linux-test-harness`, the hold marker and the deadline stamp in
  `/run`, and `/repo`. A new fixed guest path needs a rewrite line there, or
  the test will touch the host's real path.
- **Guest scripts** (`vagrant/guest/*.sh`) are tested standalone, the way
  `tests/deadline.sh` and `tests/apt-ready.sh` do it: `sed` their absolute
  paths into a sandbox and stub the commands they call.

## What `tests/generic.sh` will refuse

- **No filesystem, filesystem tool, language, toolchain or package manager
  named in `scripts/`, `vagrant/` or the chore files, comments included.**
  "btrfs" in a comment fails the build. Filesystem knowledge belongs to the
  consumer, and so does knowing how to build it.
- **Every public `vm.sh` command needs a task in `vm.chores.yml`.** "Public"
  means a `#   vm.sh <cmd>` line in `vm.sh`'s usage header. Internal plumbing,
  such as `session-begin` and `session-end` that `vm-session.sh` calls, is
  documented outside that list, not given a task.
- **The pieces that must agree, agree.** The hold marker, the share and repo
  mount points, and the box cache key are each read from their one definition
  and compared.

## Things a newcomer trips on

- **Vagrant is only ever driven through `scripts/vm.sh`.** The Vagrantfile
  reads `FLTH_*` variables that `engine_prepare` exports, and it stops at the
  first missing one if run by hand.
- **One VM per project, shared by every checkout and worktree of it.** The
  machine directory is keyed by `[project] name`. Two worktrees running
  sessions at once share one guest: the reaper leaves it alone while any
  session's process is alive, and the last session out brings it down.
- **`deadline_minutes` is an idle timeout.** Every `run` and `exec` re-arms it
  as the call starts and ends, so a single call longer than it (a whole
  `guest-test` run is one call) is still cut off.
- **Unix socket paths are limited to about 104 bytes.** Sockets the harness
  makes live under `FLTH_STATE_DIR`, never under the caller's `TMPDIR`.
  `FLTH_STATE_DIR` also holds the machine-wide slot, so moving it for one
  repository splits the lock.
- **`unknown` is never `stopped`.** A state that could not be read keeps the
  slot. Do not "simplify" that away.
- **Work in a worktree with its own `tmp/`**, and point `TMPDIR` at it, so
  sandboxes stay off a shared `/tmp`. `tmp/` is gitignored.

## Releasing

Consumers pin a tag, so a fix reaches them only once it is released.

1. A pull request moves `## [Unreleased]` into `## vX.Y.Z — <date>` in
   `CHANGELOG.md`, without editing the entries, and fixes anything in the
   README that still names the previous version.
2. Once it is merged and `ci-ok` is green on `main`, tag the merge commit
   `vX.Y.Z` and push the tag. There is no release workflow and no build
   artifact: the tag is the release. The pre-push guard refuses a version tag
   whose CHANGELOG section is missing.

Semver, with breaking changes allowed in a minor version until 1.0. A change
a consumer must act on (a renamed task, a config key, a new host requirement)
is a minor bump; fixes behind the same contract are a patch.
