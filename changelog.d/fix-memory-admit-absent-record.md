### Fixed

- **An acquire waits beside a holder with no memory file.** A holder from a
  harness before v0.5.5 writes no reservation, and memory admission refused to
  start beside one during its boot grace. Admission and the check before each
  boot now wait until that holder settles or goes, and a holder past its grace
  with no VM reserves nothing. A reservation that is present but malformed is
  still refused.
