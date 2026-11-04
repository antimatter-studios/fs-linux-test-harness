### Fixed

- **A command from another worktree no longer joins a guest that has the first
  one mounted.** Every worktree of a project shares a machine, and its guest
  mounts the worktree that booted it. `up`, `run`, `exec`, `put`, `hold`,
  `provision` and what runs through them now fail naming both worktrees, a
  session or reap from another worktree leaves that VM running, and `status`
  names the worktree the guest has mounted.
