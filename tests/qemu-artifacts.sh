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

# The helper keeps a file it cannot prove unused, and says nothing when the
# file is merely open. Each ps and lsof call therefore passes through a recorder
# that notes the answer, so a run whose first cleanup kept the fixture can say
# why after the sandbox has gone (#129). With every answer clear and nothing on
# stderr, the check that is left is the helper's stamp comparison.
export ARTIFACT_ANSWERS="$ARTIFACT_TEST/answers"
mkdir -p "$ARTIFACT_TEST/record"
cat > "$ARTIFACT_TEST/record/lsof" <<'STUB'
#!/usr/bin/env bash
name="${0##*/}"
PATH="${PATH#"$ARTIFACT_TEST/record:"}"
out="$ARTIFACT_TEST/out.$$"
err="$ARTIFACT_TEST/err.$$"
"$name" "$@" >"$out" 2>"$err"
status=$?
{
    printf '%s %s: status %s\n' "$name" "$*" "$status"
    cat "$err"
    if [ "$name" = lsof ] && [ -s "$out" ]; then
        cat "$out"
        sed -n 's/^p//p' "$out" | while read -r holder; do
            ps -o pid=,comm= -p "$holder"
        done
    fi
} >>"$ARTIFACT_ANSWERS" 2>&1
cat "$out"
cat "$err" >&2
rm "$out" "$err"
exit "$status"
STUB
cp "$ARTIFACT_TEST/record/lsof" "$ARTIFACT_TEST/record/ps"
chmod +x "$ARTIFACT_TEST/record/lsof" "$ARTIFACT_TEST/record/ps"
export PATH="$ARTIFACT_TEST/record:$ARTIFACT_TEST/bin:$PATH"
artifacts="$FLTH_STATE_DIR/tmp"
memory="$artifacts/vagrant-qemu-vq_abandoned-mem"
pidfile="$artifacts/vqemu-vq_abandoned-virtiofs0.sock.pid"
for action in halt destroy up; do
    : > "$memory"
    printf '99999999\n' > "$pidfile"
    if [ "$action" = up ]; then ln -s "$memory" "$ARTIFACT_TEST/stale"; fi
    : > "$ARTIFACT_ANSWERS"
    engine_vagrant "$action" >/dev/null 2>"$SANDBOX/err"
    status=$?
    check_eq "$status" 0 "$action succeeds after reclaiming abandoned artifacts"
    if [ "$status" != 0 ]; then
        printf 'the helper printed:\n'
        cat "$SANDBOX/err"
        printf 'ps and lsof answered:\n'
        cat "$ARTIFACT_ANSWERS"
    fi
    check_eq "$([ -e "$memory" ] && echo present || echo gone)" gone "$action removes unused shared memory"
    check_eq "$([ -e "$pidfile" ] && echo present || echo gone)" gone "$action removes the stale socket pidfile"
    if [ -L "$ARTIFACT_TEST/stale" ]; then rm "$ARTIFACT_TEST/stale"; fi
done

: > "$memory"
exec 9<>"$memory"
printf '99999999\n' > "$pidfile"
: > "$ARTIFACT_ANSWERS"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" present "an open memory file is never unlinked"
check_contains "$(cat "$ARTIFACT_ANSWERS")" "/${memory##*/}" "the record names the open memory file"
check_contains "$(cat "$ARTIFACT_ANSWERS")" "$$ " "the record names the process holding it"
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
: > "$ARTIFACT_ANSWERS"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" present "an open-file inspection error keeps the memory"
check_contains "$(cat "$ARTIFACT_ANSWERS")" "cannot inspect open files" "the record keeps lsof's own error"
rm "$ARTIFACT_TEST/bin/lsof"
engine_vagrant up >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$memory" ] && echo present || echo gone)" gone "a later start retries cleanup after inspection recovers"

finish qemu-artifacts
