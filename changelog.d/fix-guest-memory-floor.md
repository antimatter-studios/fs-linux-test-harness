### Fixed

- A suite joining a small shared guest is no longer told it is short of memory because of the guest's size: the `FLTH_SHARED_MIN_AVAILABLE` floor is now at most a quarter of the guest's total memory, so a 2G guest warns only when it is really nearly full.
