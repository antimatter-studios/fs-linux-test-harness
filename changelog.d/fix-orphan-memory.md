### Fixed
- Unused QEMU shared-memory files and virtiofs socket pidfiles are reclaimed before and after VM start, halt, and destroy, including leftovers from an abrupt exit. Files in use or whose safety cannot be established are retained.
