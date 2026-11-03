### Fixed

- **On macOS, nothing in the guest writes to the shares (#84).** The forwarder
  plugin's guest receiver answered each host file event by opening the file
  read-write, writing its first byte back, and truncating a file it read as
  empty, so a file the host had just written could end up empty on the host. The
  plugin now gets a receiver that exits, on `/share` and `/repo` alike. `inotify`
  in a macOS guest no longer sees the host's changes to a share.
