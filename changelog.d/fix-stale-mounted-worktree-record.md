### Fixed
- A mounted-worktree record is trusted only for the VM boot that wrote it, so a boot by an older harness cannot leave a stale record that refuses legitimate commands or names the wrong mounted worktree.
