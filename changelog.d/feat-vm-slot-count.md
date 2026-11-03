### Added
- `FLTH_SLOT_COUNT` configures the machine-wide concurrent VM limit, defaulting to one, with named host-memory admission before every boot and reservations for other booting guests.

### Changed
- The default guest allocation is 2 GiB, selected from real consumer `guest-test` measurements at 2, 3 and 4 GiB.

### Fixed
- Lifecycle reapers stop only a VM booted by their own invocation, leaving another run's idle VM alone.
- A reboot renews its slot's boot grace and generation so a stale waiter cannot free the reservation inspected before the reboot.
