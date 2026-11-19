#!/usr/bin/env bash
#
# resource-profile-slots.sh -- a resource profile bounds the guest's memory, CPUs
# and build jobs, never how many runs' trees it can hold (#264).
#
# A worktree's standing run holds its slot for as long as the guest is up, so
# `vm.sh up` and then `vm.sh session` already need two, and each further worktree
# one more. A profile that sized the slots refused that session on its own
# defaults. Here every profile's defaults take `up`, a session from the same
# worktree and one from another, and an explicit FLTH_SHARED_SLOTS still limits
# them.
#
# Real vm.sh, real engine and its slot accounting. Only the provider is a
# stand-in: `vagrant up` starts a QEMU stand-in and the stand-in QMP, which offers
# the root ports the engine asked for (FLTH_VM_SLOTS), and ssh reads a guest
# call's script to its end, powering off a slot it is told to, as the guest does.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMPDIR="${FLTH_TEST_SOCKET_ROOT:-/tmp}" new_sandbox

mkdir -p "$SANDBOX/harness"
cp -R "$REPO/scripts" "$REPO/vagrant" "$SANDBOX/harness/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/harness/scripts/host-tools.sh"
chmod +x "$SANDBOX/harness/scripts/host-tools.sh"
VM="$SANDBOX/harness/scripts/vm.sh"
export VM

BIN="$SANDBOX/bin"
export STUB="$SANDBOX/stub"
mkdir -p "$BIN" "$STUB"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$BIN/uname"
ln -s "$BASH" "$BIN/bash"
printf '#!/bin/sh\nexit 1\n' > "$BIN/pgrep"
cat > "$BIN/ssh" <<'STUB'
#!/bin/sh
while IFS= read -r line; do
    case "$line" in
        'echo 0 > /sys/bus/pci/slots/'*/power)
            slot="${line#echo 0 > /sys/bus/pci/slots/}"
            perl "$(dirname "$VM")/lib/qmp.pl" "$FLTH_VM_QMP" \
                "{\"execute\":\"x-flth-slot-off\",\"arguments\":{\"slot\":${slot%/power}}}" >/dev/null
            ;;
    esac
    [ "$line" != 'exit "$flth_status"' ] || break
done
exit 0
STUB
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    status) echo '1,default,state,stopped' ;;
    ssh-config) echo 'Host default' ;;
    up)
        mkdir -p "$VAGRANT_DOTFILE_PATH/machines/default/qemu"
        rm -f "$STUB/qemu.pid"
        perl -MPOSIX -e '
            exit 0 if fork;
            POSIX::setsid();
            exit 0 if fork;
            open STDIN, "<", "/dev/null";
            open STDOUT, ">", "/dev/null";
            open STDERR, ">", "/dev/null";
            open my $pid, ">", "$ENV{STUB}/qemu.pid" or exit 1;
            print {$pid} "$$\n";
            close $pid;
            exec { "/bin/sh" } "qemu-system-stub", "-c", q{n=0; while kill -0 "$FLTH_TEST_PID" 2>/dev/null && [ "$n" -lt 3600 ]; do sleep 1; n=$((n + 1)); done}, "$ARGV[0]/disk";
        ' "$VAGRANT_DOTFILE_PATH"
        until [ -s "$STUB/qemu.pid" ]; do sleep 0.05; done
        "$FLTH_TEST_QMP_START" "$(cat "$STUB/qemu.pid")"
        ;;
    halt)
        [ ! -s "$STUB/qemu.pid" ] || kill -KILL "$(cat "$STUB/qemu.pid")" 2>/dev/null
        rm -f "$STUB/qemu.pid"
        ;;
esac
exit 0
STUB
chmod +x "$BIN/uname" "$BIN/pgrep" "$BIN/ssh" "$BIN/vagrant"
export PATH="$BIN:$PATH"
export FLTH_TEST_VFS_LOG="$STUB/virtiofsd.log"

ONE="$SANDBOX/worktree-one"
TWO="$SANDBOX/worktree-two"
make_consumer "$ONE" resource-profile-slots
make_consumer "$TWO" resource-profile-slots
vm_in() { local dir="$1"; shift; (cd "$dir" && "$VM" "$@"); }

down() {
    vm_in "$ONE" down > /dev/null 2>&1
    [ ! -s "$STUB/qemu.pid" ] || kill -KILL "$(cat "$STUB/qemu.pid")" 2>/dev/null
    rm -f "$STUB/qemu.pid"
}

for profile in high medium low; do
    export FLTH_RESOURCE_PROFILE="$profile"
    check_contains "$(vm_in "$ONE" config)" "slots=32" "$profile: the guest boots with 32 slots, as every profile does"
    out="$(vm_in "$ONE" up 2>&1)"
    check_eq "$?" 0 "$profile: up attaches the worktree's standing run"
    out="$(vm_in "$ONE" session "$VM" run true 2>&1)"
    check_eq "$?" 0 "$profile: a session after up is attached beside it"
    check_lacks "$out" "slots for a run's tree are in use" "$profile: and no slot is refused"
    out="$(vm_in "$TWO" session "$VM" run true 2>&1)"
    check_eq "$?" 0 "$profile: and so is a session from another worktree"
    down
done

# The accounting above is real: one slot, held by the standing run, refuses the session.
export FLTH_RESOURCE_PROFILE=high FLTH_SHARED_SLOTS=1
check_contains "$(vm_in "$ONE" config)" "slots=1" "FLTH_SHARED_SLOTS still overrides the default"
vm_in "$ONE" up > /dev/null 2>&1
check_eq "$?" 0 "one slot: up attaches the standing run"
out="$(vm_in "$ONE" session "$VM" run true 2>&1)"
check_eq "$?" 1 "one slot: the session after it is refused"
check_contains "$out" "all 1 slots for a run's tree are in use" "one slot: naming the limit it met"
down
unset FLTH_SHARED_SLOTS

finish resource-profile-slots
