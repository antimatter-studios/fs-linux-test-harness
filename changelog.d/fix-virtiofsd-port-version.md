### Fixed

- **A Mac host whose virtiofsd breaks hard links is refused.** `chore
  vm:host:check` on macOS reads the release of the virtiofsd the engine would
  start from `virtiofsd --port-version`, and refuses a build older than port
  release 1.14.0.1 or one without the flag. Before 1.14.0.1 a hard-linked file
  could not be opened once its first name was removed, and opened another file
  once one was renamed over it (christhomas/virtiofsd#9). Its `--version`
  prints 1.14.0 either way, so only the new flag can tell; builds print it
  from 1.14.0.2 (`brew update && brew upgrade antimatter-studios/tap/virtiofsd`).
  Linux is unchanged (#276).
