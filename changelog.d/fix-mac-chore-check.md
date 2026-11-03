### Fixed

- Session commands retain interrupt handling under macOS Bash 3.2, and sourced sessions report SIGINT as status 130 while still running teardown.
- VM-free checks support macOS system Bash and Ruby, use short socket scratch roots, and select a capable guest-script Bash explicitly without changing the host interpreter.

### Changed

- The required VM-free CI tier runs on macOS arm64 as well as Linux.
