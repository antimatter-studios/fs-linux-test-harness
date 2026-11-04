### Fixed
- A signal to a command session, whether delivered to its process or its process group, reaches the command's process group before VM teardown. Processes remaining in that group receive SIGKILL after a five-second grace period, even if the command itself has already exited.
- Cancellation recorded before a session launches its command prevents that command from starting.
