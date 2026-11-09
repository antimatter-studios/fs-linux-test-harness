### Fixed

- **A session or an `up` on a macOS host no longer prints "child setpgid ...
  Operation not permitted".** The session's command, `up`'s boot and the
  escalation that follows a signal now make their process groups from the child
  alone, through Perl, instead of through Bash job control, whose two concurrent
  setpgid calls race on macOS (#209). Each still runs in a group of its own, and
  a signal still reaches it.
