### Fixed

- **A dead holder no longer reserves pending memory.** Once its boot grace
  has expired and no VM is running for it, a holder's recorded reservation
  no longer blocks admission into a free lower slot. An unreadable process
  table still keeps the reservation counted.
