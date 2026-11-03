#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
export FLTH_HARNESS="$REPO"
. "$REPO/scripts/lib/engine-vagrant.sh"
export ARTIFACT_RACE="$SANDBOX/race"
mkdir -p "$ARTIFACT_RACE/bin" "$FLTH_STATE_DIR/tmp"
export ARTIFACT_MEMORY="$FLTH_STATE_DIR/tmp/vagrant-qemu-vq_race-mem"
cat > "$ARTIFACT_RACE/bin/vagrant" <<'STUB'
#!/usr/bin/env bash
case "${ARTIFACT_MODE:-}" in
    blocking)
        exec 9<>"$ARTIFACT_MEMORY"
        touch "$ARTIFACT_RACE/ready"
        for iteration in 1 2 3 4 5 6 7 8 9 10; do
            [ ! -e "$ARTIFACT_RACE/release" ] || exit 0
            sleep 1
        done
        exit 17
        ;;
    second) touch "$ARTIFACT_RACE/second" ;;
    signal) kill -TERM "$$" ;;
esac
STUB
chmod +x "$ARTIFACT_RACE/bin/vagrant"
export PATH="$ARTIFACT_RACE/bin:$PATH"
ARTIFACT_MODE=blocking engine_vagrant up >"$SANDBOX/first.log" 2>&1 &
first=$!
count=0
while [ ! -e "$ARTIFACT_RACE/ready" ] && [ "$count" -lt 50 ]; do
    sleep 0.1
    count=$((count + 1))
done
check_eq "$([ -e "$ARTIFACT_RACE/ready" ] && echo ready)" ready "the first provider reaches its startup interval"
ARTIFACT_MODE=second engine_vagrant up >"$SANDBOX/second.log" 2>&1 &
second=$!
sleep 0.3
check_eq "$([ -e "$ARTIFACT_RACE/second" ] && echo started || echo waiting)" waiting "another start cannot clean during provider preparation"
check_eq "$([ -e "$ARTIFACT_MEMORY" ] && echo present)" present "memory created during startup remains present"
touch "$ARTIFACT_RACE/release"
wait "$first"
check_eq "$?" 0 "the first provider completes"
wait "$second"
check_eq "$?" 0 "the waiting provider completes after it"
check_eq "$([ -e "$ARTIFACT_RACE/second" ] && echo started)" started "the serialized second start is not lost"
check_eq "$([ -e "$ARTIFACT_MEMORY" ] && echo present || echo gone)" gone "unused memory is reclaimed after the startup interval"

rm "$ARTIFACT_RACE/ready" "$ARTIFACT_RACE/release" "$ARTIFACT_RACE/second"
export VAGRANT_DOTFILE_PATH="$SANDBOX/machine"
cat > "$ARTIFACT_RACE/bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ -e "$ARTIFACT_RACE/ready" ]; then
    printf 'qemu-system-aarch64 -drive file=%s/machines/default/linked-box.img\n' "$VAGRANT_DOTFILE_PATH"
else
    echo init
fi
STUB
chmod +x "$ARTIFACT_RACE/bin/ps"
ARTIFACT_MODE=blocking engine_vagrant up >"$SANDBOX/first.log" 2>&1 &
first=$!
count=0
while [ ! -e "$ARTIFACT_RACE/ready" ] && [ "$count" -lt 50 ]; do
    sleep 0.1
    count=$((count + 1))
done
ARTIFACT_MODE=second engine_vagrant up >"$SANDBOX/second.log" 2>&1 &
second=$!
count=0
while [ ! -e "$ARTIFACT_RACE/second" ] && [ "$count" -lt 50 ]; do
    sleep 0.1
    count=$((count + 1))
done
check_eq "$([ -e "$ARTIFACT_RACE/second" ] && echo started)" started "a visible QEMU releases startup serialization before provisioning ends"
check_eq "$([ -e "$ARTIFACT_MEMORY" ] && echo present)" present "concurrent startup still retains open memory"
touch "$ARTIFACT_RACE/release"
wait "$first"
check_eq "$?" 0 "the provisioning provider completes after releasing startup serialization"
wait "$second"
check_eq "$?" 0 "the concurrent provider completes without exhausting a pending slot's boot grace"
rm "$ARTIFACT_RACE/bin/ps"
unset VAGRANT_DOTFILE_PATH

cat > "$ARTIFACT_RACE/bin/lsof" <<'STUB'
#!/usr/bin/env bash
printf 'changed\n' >> "$ARTIFACT_MEMORY"
exit 1
STUB
chmod +x "$ARTIFACT_RACE/bin/lsof"
: > "$ARTIFACT_MEMORY"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$ARTIFACT_MEMORY" ] && echo present)" present "a file changed during inspection is not unlinked"
check_contains "$(cat "$ARTIFACT_MEMORY")" changed "the concurrent writer's data survives"
rm "$ARTIFACT_RACE/bin/lsof"
engine_vagrant halt >/dev/null 2>"$SANDBOX/err"
check_eq "$([ -e "$ARTIFACT_MEMORY" ] && echo present || echo gone)" gone "the changed file is reclaimed only by a later stable inspection"
ARTIFACT_MODE=signal engine_vagrant up >/dev/null 2>"$SANDBOX/err"
check_eq "$?" 143 "a provider stopped by a signal retains its signal status"

finish qemu-artifact-races
