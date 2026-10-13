### Added

- **A consumer chooses its guest: `[vm] guest = "debian-12"` or
  `"debian-13"`.** Debian 12 stays every consumer's default, so nothing
  changes for one that does not name it. Debian 13 boots kernel 6.12 with
  xfsprogs 6.13, for what 6.1 cannot do: mounting a volume with parent
  pointers or exchange-range. The harness pins both boxes and their
  versions in the Vagrantfile, and `ci-setup-linux.sh` keys its box cache
  on the consumer's guest (or `FLTH_VM_GUEST`), so a runner never restores
  one guest's box for another. A Mac has no Debian 13 box, and says so.
