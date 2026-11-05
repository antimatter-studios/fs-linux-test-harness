### Fixed

- **A call outside any session keeps a shared guest up.** A `vm.sh run` or `vm.sh exec`
  by hand was not on the list a shutdown request reads, so a `vm.sh down` stopped the
  guest under it. It is now listed for as long as it lasts.
