### Added

- **A watchdog on the host ends a stuck guest and says why.** One runs for each guest, started and ended with it. It warns of low memory, low disk, a process making no progress in uninterruptible sleep, and an oops, soft lockup, hung task, RCU stall or panic on the guest's console, and shows the last of it in `vm.sh status`. A guest that stops answering, or a process stuck past its limit, ends the guest and frees the slot, and every suite on it ends with status 75 and a message naming the reason. `FLTH_WATCHDOG=off` starts none, and the limits are settings.
