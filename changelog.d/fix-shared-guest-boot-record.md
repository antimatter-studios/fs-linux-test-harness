### Fixed

- **A join that disagrees with a shared guest's boot is refused.** A guest sees one
  `FLTH_SHARED_ROOT` and carries one version of its run tool, both fixed at boot. A
  consumer joining with another directory or harness version got a failed mount or
  a misread command. `up` now refuses it, saying which differs, and the guest stays up.
