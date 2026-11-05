### Added

- **A consumer's build state lasts between runs on a shared guest.** `/var/cache` is
  the consumer's, on the guest's own disk, for as long as the guest runs, so a second
  run does not build from nothing. A second run of one consumer at the same time has
  its own empty one. What a killed suite held is free for the next run to register.
