### Fixed

- **A short `[vm] deadline_minutes` is not cut off by its own re-arm limit.** Re-arming is limited to once in a sixth of the deadline, and at most once a minute. A window of a whole minute at `deadline_minutes = 1` let a call find the stamp fresh with a second of the guest left.
