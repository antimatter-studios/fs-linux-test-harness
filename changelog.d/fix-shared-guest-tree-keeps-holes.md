### Fixed

- **A run's copy of its tree on a shared guest keeps holes.** A copy filled every hole
  in a suite's images, taking one consumer's 3.5 GiB of fixtures to 38 GiB of the
  guest's disk.
