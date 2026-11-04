#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMPDIR="${FLTH_TEST_SOCKET_ROOT:-/tmp}" new_sandbox

mkdir -p "$SANDBOX/harness" "$SANDBOX/bin" "$SANDBOX/stub"
cp -R "$REPO/scripts" "$REPO/vagrant" "$SANDBOX/harness/"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/harness/scripts/host-tools.sh"
chmod +x "$SANDBOX/harness/scripts/host-tools.sh"
VM="$SANDBOX/harness/scripts/vm.sh"
export STUB="$SANDBOX/stub"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$SANDBOX/bin/uname"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/pgrep"
printf '#!/bin/sh\ncat >/dev/null\n' > "$SANDBOX/bin/ssh"
ln -s "$BASH" "$SANDBOX/bin/bash"
cat > "$SANDBOX/bin/vagrant" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    status) echo '1,default,state,stopped' ;;
    ssh-config) echo 'Host default' ;;
    up)
        echo "$$" > "$STUB/vagrant.pid"
        trap 'exit 143' TERM
        trap 'exit 130' INT
        trap 'exit 129' HUP
        if [ ! -e "$STUB/before-qemu" ]; then
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
                exec { "/bin/sh" } "qemu-system-stub", "-c", "while :; do sleep 1; done", "$ARGV[0]/disk";
            ' "$VAGRANT_DOTFILE_PATH"
            until [ -s "$STUB/qemu.pid" ]; do sleep 0.05; done
        fi
        : > "$STUB/booting"
        while [ -e "$STUB/pause" ]; do sleep 0.05; done
        ;;
    halt)
        if [ -d "$(dirname "$VAGRANT_DOTFILE_PATH")/up.lock" ]; then
            : > "$STUB/halt-with-lock"
        fi
        : > "$STUB/halting"
        while [ -e "$STUB/pause-halt" ]; do sleep 0.05; done
        if [ -s "$STUB/qemu.pid" ]; then
            kill -KILL "$(cat "$STUB/qemu.pid")" 2>/dev/null || true
            rm -f "$STUB/qemu.pid"
        fi
        ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/uname" "$SANDBOX/bin/pgrep" "$SANDBOX/bin/ssh" "$SANDBOX/bin/vagrant"
export PATH="$SANDBOX/bin:$PATH"
make_consumer "$SANDBOX/consumer" up-signals
export FLTH_CONFIG="$SANDBOX/consumer/fs-linux-test-harness.toml"
MACHINE="$FLTH_CACHE_DIR/machines/up-signals"

alive() {
    local state
    [ -n "$1" ] || return 1
    state="$(ps -o stat= -p "$1" 2>/dev/null)"
    case "$state" in '' | *Z*) return 1 ;; esac
    return 0
}
wait_file() {
    local ticks=0
    until [ -e "$1" ]; do
        [ "$ticks" -lt 200 ] || return 1
        sleep 0.05
        ticks=$((ticks + 1))
    done
}
clean_case() {
    local process
    rm -f "$STUB/pause" "$STUB/pause-halt"
    for process in vagrant qemu; do
        if [ -s "$STUB/$process.pid" ]; then
            kill -TERM "$(cat "$STUB/$process.pid")" 2>/dev/null || true
        fi
    done
    "$VM" down >/dev/null 2>&1 || true
    rm -f "$STUB/vagrant.pid" "$STUB/qemu.pid" "$STUB/booting" "$STUB/halting" "$STUB/halt-with-lock" "$STUB/before-qemu"
}
signal_case() {
    local signal="$1" target="$2" expected="$3" phase="$4" up_pid vagrant_pid qemu_pid status ticks=0
    clean_case
    : > "$STUB/pause"
    [ "$phase" != before-qemu ] || : > "$STUB/before-qemu"
    set -m
    "$VM" up > "$SANDBOX/$signal-$target-$phase.log" 2>&1 &
    up_pid=$!
    set +m
    if ! wait_file "$STUB/booting"; then
        bad "$signal $target $phase: boot did not start"
        kill -KILL -- "-$up_pid" 2>/dev/null || true
        wait "$up_pid" 2>/dev/null || true
        return
    fi
    vagrant_pid="$(cat "$STUB/vagrant.pid")"
    qemu_pid="$(cat "$STUB/qemu.pid" 2>/dev/null || true)"
    check_eq "$(cat "$MACHINE/up.lock/pid")" "$up_pid" "$signal $target $phase: up holds its lock"
    if [ "$target" = group ]; then
        kill -"$signal" -- "-$up_pid"
    else
        kill -"$signal" "$up_pid"
    fi
    while alive "$up_pid" && [ "$ticks" -lt 300 ]; do
        sleep 0.05
        ticks=$((ticks + 1))
    done
    if alive "$up_pid"; then
        bad "$signal $target $phase: up did not stop"
        kill -KILL -- "-$up_pid" 2>/dev/null || true
    fi
    wait "$up_pid" 2>/dev/null
    status=$?
    check_eq "$status" "$expected" "$signal $target $phase: the signal status is preserved"
    if alive "$vagrant_pid"; then
        bad "$signal $target $phase: the boot outlived up"
    else
        ok "$signal $target $phase: the boot stopped before up exited"
    fi
    if alive "$qemu_pid"; then
        bad "$signal $target $phase: a guest was left without a poweroff deadline"
    else
        ok "$signal $target $phase: no guest was left without a poweroff deadline"
    fi
    if [ ! -d "$MACHINE/up.lock" ]; then
        ok "$signal $target $phase: the lock is released after cleanup"
    else
        bad "$signal $target $phase: the lock was not released"
    fi
    if [ "$phase" != before-qemu ]; then
        check_eq "$(test -e "$STUB/halt-with-lock" && echo yes)" yes "$signal $target $phase: guest cleanup holds the up lock"
    fi
}

signal_case TERM process 143 provisioning
signal_case TERM group 143 provisioning
signal_case INT process 130 provisioning
signal_case HUP process 129 provisioning
signal_case TERM process 143 before-qemu
clean_case
finish up-signals
