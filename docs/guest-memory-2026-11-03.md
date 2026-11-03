# Guest memory measurement — 2026-11-03

## Decision

The default `[vm] memory` is **`2G`**. It is the smallest allocation tested
that completes the real consumer's declared, unfiltered `guest-test` suite.
This leaves more host headroom when two consumers run together. Consumers
with larger workloads can still override the allocation.

These are capacity observations on a busy shared host, not an isolated
performance ranking or a guarantee for every consumer.

## Workload and method

- Consumer: `antimatter-studios/rust-fs-erofs`, v0.5.1,
  commit `d53b52d1f5375d0ce21ca872a7407e2d1afb50e3`.
- Command: `/usr/bin/time -l scripts/vm.sh guest-test`, invoking the
  consumer's declared `scripts/guest-suite.sh` without test filtering.
- Host: MacBookPro18,2, Apple M1 Max, 10 logical CPUs, 64 GiB RAM,
  macOS 26.3 (25D125). Other workers and compilers remained active.
- Guest: Debian 12, Linux `6.1.0-42-cloud-arm64`, aarch64, four vCPUs,
  16 GiB disk, 512 MiB swap, Rust/Cargo 1.95.0.
- Each measurement booted a disposable guest from the same provisioned
  base. Boot, provisioning, and fixture generation happened before timing.
  The timed call included the consumer's guest toolchain setup, dependency
  downloads, compilation, and tests. Generated input fixtures were reused
  from the consumer checkout; the disposable guest build state was not.
- The harness runtime was frozen before measurement so a running shell
  never read a changing source file. The measured `vm.sh` is identical to
  this change's `vm.sh`; a later slot-generation renewal fix does not change
  the timed workload.

## Results

All three allocations ran 46 test suites: **656 passed, zero ignored**.
Wall time is the entire `guest-test` invocation, not just the guest script's
own timer. Guest memory is the kernel's `MemTotal`; swap usage is a
post-run snapshot, not peak usage.

| Configured allocation | Guest MemTotal (KiB) | Wall time (seconds) | Exit | Swap used after run (KiB) |
| --- | ---: | ---: | ---: | ---: |
| `2G` | 2,032,972 | 280.71 | 0 | 1,740 |
| `3G` | 3,060,040 | 656.04 | 0 | 0 |
| `4G` | 4,023,872 | 327.01 | 0 | 0 |

The 2 GiB run began at 11:22 CET and finished at 11:27; the 3 GiB run
began at 11:35 and finished at 11:46; the 4 GiB run began at 11:52 and
finished at 11:58. Host one-minute load averages around the timed calls
were 66.09 to 45.87, 155.02 to 194.86, and 35.76 to 158.16, respectively.
These uncontrolled loads make timing differences unsuitable for attributing
speed changes to the guest allocation. None of the three runs recorded a
kernel OOM message. The host `time -l` process RSS measures the wrapper,
not the daemonized QEMU guest, so it is not reported as guest peak memory.

An earlier attempt missing generated fixtures and a run interrupted by a
live host-script edit are excluded from these successful measurements.

## Concurrency and ownership evidence

With `FLTH_SLOT_COUNT=2`, the real `rust-fs-erofs` VM ran beside another
consumer's VM. A third consumer, `flth-slot-third-103`, was refused after
its explicitly zero-second wait and the diagnostic named both holders:
`rust-fs-bcachefs` and `rust-fs-erofs`. The VM-free parallel regression
additionally blocks a third process on a FIFO while both holders remain,
then proves it acquires a slot after exactly one holder releases it.

During each measurement, a separate chore invocation ran an `after_all`
reaper against the idle, unheld measurement VM. It left the VM running and
reported that another invocation owned it. The lifecycle regression also
proves a sweep stops its own VM while preserving the other consumer's VM.
Each measurement stopped only the QEMU PID whose boot-owner record and
process start time matched that measurement driver.

Raw measurement logs remain under
`~/tmp/constellation-loop/harness-103/`, including `measurement-{2G,3G,4G}.log`,
`time-{2G,3G,4G}.log`, `guest-test-{2G,3G,4G}.log`, guest memory snapshots,
`real-third-wait.log`, and the `idle-reap-*.log` files.
