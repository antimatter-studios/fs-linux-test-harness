#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

export FLTH_HARNESS="$REPO"
. "$REPO/scripts/lib/engine-vagrant.sh"
export ARTIFACT_TEST="$SANDBOX/provider"
mkdir -p "$ARTIFACT_TEST/bin" "$FLTH_STATE_DIR/tmp"
cat > "$ARTIFACT_TEST/bin/vagrant" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = up ]; then
    [ ! -e "$ARTIFACT_TEST/stale" ] || exit 19
fi
exit "$(cat "$ARTIFACT_TEST/exit" 2>/dev/null || echo 0)"
STUB
chmod +x "$ARTIFACT_TEST/bin/vagrant"
export PATH="$ARTIFACT_TEST/bin:$PATH"
artifacts="$FLTH_STATE_DIR/tmp"
memory="$artifacts/vagrant-qemu-vq_abandoned-mem"
pidfile="$artifacts/vqemu-vq_abandoned-virtiofs0.sock.pid"
for action in halt destroy up; do
    : > "$memory"
    printf '99999999\n' > "$pidfile"
    if [ "$action" = up ]; then ln -s "$memory" "$ARTIFACT_TEST/stale"; fi
    engine_vagrant "$action" >/dev/null 2>"$SANDBOX/err"
    check_eq "$?" 0 "$action succeeds after reclaiming abandoned artifacts"
    check_eq "$([ -e "$memory" ] && echo present || echo gone)" gone "$action removes unused shared memory"
    check_eq "$([ -e "$pidfile" ] && echo present || echo gone)" gone "$action removes the stale socket pidfile"
    if [ -L "$ARTIFACT_TEST/stale" ]; then rm "$ARTIFACT_TEST/stale"; fi
done

: > "$memory"
exec 9<>"$memory"
printf '99999999\n' > "$pidfile"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" present "an open memory file is never unlinked"
check_eq "$([ -e "$pidfile" ] && echo present || echo gone)" present "its related pidfile stays while the memory is open"
exec 9>&-
engine_vagrant up >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" gone "the next start reclaims memory after its last opener exits"

: > "$memory"
printf '23\n' > "$ARTIFACT_TEST/exit"
engine_vagrant destroy >/dev/null 2>"$SANDBOX/err"
check_eq "$?" 23 "cleanup preserves a failed provider command's status"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" gone "a failed destroy still reclaims unused memory"
rm "$ARTIFACT_TEST/exit"

printf 'keep\n' > "$artifacts/unrelated"
ln -s "$artifacts/unrelated" "$artifacts/vagrant-qemu-vq_symlink-mem"
mkdir "$artifacts/vagrant-qemu-vq_directory-mem"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$(cat "$artifacts/unrelated")" keep "cleanup leaves unrelated files untouched"
check_eq "$([ -L "$artifacts/vagrant-qemu-vq_symlink-mem" ] && echo link)" link "cleanup does not follow symlinks"
check_eq "$([ -d "$artifacts/vagrant-qemu-vq_directory-mem" ] && echo directory)" directory "cleanup does not remove directories"

cat > "$ARTIFACT_TEST/bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ -e "$ARTIFACT_TEST/ps-fails" ]; then exit 1; fi
cat "$ARTIFACT_TEST/processes"
STUB
chmod +x "$ARTIFACT_TEST/bin/ps"
printf 'qemu-system-aarch64 -object memory-backend-file,id=mem,mem-path=%s,share=on\n' "$memory" > "$ARTIFACT_TEST/processes"
: > "$memory"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" present "a running QEMU's named memory is protected before it opens it"
: > "$ARTIFACT_TEST/ps-fails"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" present "an unreadable process table never authorizes deletion"
rm "$ARTIFACT_TEST/ps-fails"
printf 'init\n' > "$ARTIFACT_TEST/processes"
cat > "$ARTIFACT_TEST/bin/lsof" <<'STUB'
#!/usr/bin/env bash
echo 'cannot inspect open files' >&2
exit 1
STUB
chmod +x "$ARTIFACT_TEST/bin/lsof"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" present "an open-file inspection error keeps the memory"
rm "$ARTIFACT_TEST/bin/lsof"
engine_vagrant up >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" gone "a later start retries cleanup after inspection recovers"

finish qemu-artifacts
