# examples/minimal

The smallest consumer of fs-linux-test-harness:

| File | What it is |
| --- | --- |
| `fs-linux-test-harness.toml` | The consumer config: a project name and a setup script. |
| `scripts/vm-setup.sh` | Runs as root inside the VM; installs the repository's own tooling. |
| `chores.yml` | Includes the harness's `vm.chores.yml` from the sibling checkout, installs the reaper, and tears the VM down after `test`. |

`myfs-progs` and `modprobe myfs` are placeholders. For a consumer that
really runs, see [`tests/smoke-consumer/`](../../tests/smoke-consumer/),
which CI boots on every pull request.
