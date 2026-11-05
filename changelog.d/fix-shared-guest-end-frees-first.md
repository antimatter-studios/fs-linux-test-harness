### Fixed

- **A run on a shared guest frees what it held before deleting its root.** Deleting a
  large root took minutes, and a suite restarted during that got an empty `/var/cache`
  instead of the consumer's.
