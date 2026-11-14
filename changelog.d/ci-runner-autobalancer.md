### Fixed
- Concurrent callers reclaiming a dead boot lock cannot remove a live caller's replacement lock and boot the same guest twice.
