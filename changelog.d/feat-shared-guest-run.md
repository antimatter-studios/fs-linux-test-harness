### Added

- **Each run on a shared guest has its own random root and mounts.** A session is
  a run. Its calls into the guest run in a private mount namespace, with
  directories under `/var/lib/fs-linux-test-harness/runs/<id>/` mounted at `/tmp`,
  `/var/tmp`, `/var/cache` and `/mnt`, and `FLTH_RUN_ROOT` naming the root.
  `guest-test` also copies the tree there and mounts it at `/repo`. The end of a
  run stops its commands, detaches the loop devices backed by its root and deletes
  it, and leaves every other run alone. A suite killed outright gets the same when
  it is dropped from the list.
