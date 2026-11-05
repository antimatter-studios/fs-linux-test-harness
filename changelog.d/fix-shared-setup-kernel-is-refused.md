### Fixed

- **A consumer whose setup installs a kernel cannot join a shared guest and be told it succeeded.** A shared guest does not restart for one consumer's setup, so that consumer's kernel tests would have run on the kernel the guest booted. Its join now fails, naming the kernel it installed and the one running, and so do its later calls on that boot. Other consumers are not affected.
