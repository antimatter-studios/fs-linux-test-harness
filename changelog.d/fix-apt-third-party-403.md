### Fixed

- `ci-setup-linux.sh` no longer fails when a source it installs nothing from, such as `packages.microsoft.com`, refuses its package index. It names the source it ignored. A failed Ubuntu or HashiCorp index still fails the setup and names the source (#307).
