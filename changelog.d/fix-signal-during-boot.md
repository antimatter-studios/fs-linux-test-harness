### Fixed

- A session signalled during a boot no longer leaves a guest running without `/share` and `/repo`. `FLTH_KEEP_VM=1`, a hold, another live session and another worktree still keep a VM whose boot finished. If such a guest is left by a boot with no session, `vm.sh up` and `vm.sh run` replace it, `vm.sh exec` refuses it, `vm.sh status` says so and `vm.sh reap` stops it.
