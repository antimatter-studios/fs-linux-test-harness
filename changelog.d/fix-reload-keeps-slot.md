### Added

- **`vm.sh reload` (`chore vm:reload`) restarts a running VM in place and keeps
  its slot.** `vm-slot.sh renew` does the same for a consumer that runs its own
  `vagrant reload`, as `vm-slot.sh renew && vagrant reload`.

### Changed

- **A dead holder is reclaimed later.** A waiter now takes the slot of a holder
  past its boot grace only once its VM has been seen absent, with no gap, for
  `FLTH_SLOT_ABSENT_GRACE`, which defaults to the boot grace of 180 seconds.
  Until then the holder's memory is waited for.

### Fixed

- **A restart in place no longer loses a VM its slot.** An in-place reload of a
  VM past its boot grace looked like an abandoned holder, so a rival took the
  slot and the host ran more VMs than `FLTH_SLOT_COUNT`. A restart the harness
  is told about now keeps its slot. One it is not told about keeps it for the
  absence window only, and a VM down for longer can still return past the limit.
- **A provisioning boot keeps its slot between its stop and the next boot**,
  however long its setup script ran.
