### Changed

- `scripts/ci-setup-linux.sh` documents restoring the Vagrant box cache with `actions/cache/restore` and saving it only from `main`, since a merge queue run cannot restore an entry another queue run saved; the harness's own `.github/workflows/box-cache.yml` is the example (#148).
