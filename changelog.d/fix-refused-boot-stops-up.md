### Fixed
- A memory-admission refusal stops `vm.sh up` before setup or any later guest work, whether the refused boot provisions the disk or runs it disposably, and releases the stopped machine’s slot and up lock.
- Failed preparation, provisioning, setup and guest-command construction steps propagate their status instead of continuing while the up wrapper captures failures.
