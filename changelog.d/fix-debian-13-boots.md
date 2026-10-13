### Fixed

- **The Debian 13 guest boots (#70).** On a Linux x86_64 host the QEMU
  provider passes `-vga none`, and the Debian 13 box's GRUB then resets the
  machine before its kernel prints anything, over and over, until every
  boot attempt times out. The VM now gets a standard VGA (`-vga std`) it
  never displays; its console is still the serial port. The smoke job
  boots every pinned guest, Debian 12 and Debian 13, so a guest that
  cannot boot fails there before a release names it.
