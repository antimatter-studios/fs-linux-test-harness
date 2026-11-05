### Fixed

- **A boot keeps its slot for as long as it is booting.** A lease is renewed
  while a boot attempt runs and again when one fails, so a waiter finds neither
  a long attempt with no VM yet nor the moment between two attempts abandoned,
  and the next attempt is not refused with `no memory reservation owns this boot`.
