### Added

- **`FLTH_WATCHDOG_TREE_SECS` (default 300).** How long a call may wait, with no
  progress, on a FUSE reply its run's virtiofsd does not send before the watchdog
  ends the guest.

### Fixed

- **A call waiting on a run's virtiofsd that has gone or stopped answering fails
  within a bound (#289).** It used to wait until whatever ran it gave up, hours in a
  CI job, because the guest still answers and the waiting process need not be in
  uninterruptible sleep. The watchdog now reads each run's outstanding requests and
  the threads waiting on a FUSE reply, and ends the guest with status 75 and a
  message naming the run's tree and its virtiofsd. A daemon that has gone with
  nothing outstanding still ends only its own run.
