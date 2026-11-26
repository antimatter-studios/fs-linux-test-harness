### Fixed
- **An index with no candidate is retried after a wait.** With no mirror list to move to, the QEMU install waits before each retry and the failure names the sources it fetched from, rather than running all three attempts within two seconds (#304).
