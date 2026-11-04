### Fixed

- **A box catalog outage is waited for and not blamed on the guest.** A box
  catalog or box download answering a 5xx, a 408, 425 or 429, or not answering
  at all, took the three boot attempts five seconds apart and ended saying the
  VM would not boot. `up` now waits for it over minutes, 30, 60 and then 120
  seconds between tries, for 15 minutes at most, and its failure names the
  catalog and what it answered. Any other boot failure keeps its retries.
