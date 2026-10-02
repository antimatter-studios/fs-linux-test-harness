#!/usr/bin/env bash
#
# apt-ready.sh — vagrant/guest/apt-ready.sh, which runs in the guest at
# every boot, before the consumer's setup script can: it disables the
# first-boot dialog service that waits for a keyboard and holds the dpkg
# lock, then waits for the package manager's locks to be free and fails,
# naming the holder, when they are not.
#
# Run here with `systemctl`, `stat` and `sleep` stubbed and /proc/locks
# and /var replaced by files under the sandbox. The real kernel's record
# of a real dpkg-style lock is checked by the smoke run, in a real guest.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

SCRIPT="$REPO/vagrant/guest/apt-ready.sh"

if [ ! -f "$SCRIPT" ]; then
    bad "vagrant/guest/apt-ready.sh exists"
    finish apt-ready
fi

# box <userconfig state|none> — a fake guest in $box
new_box() {
    box="$SANDBOX/box$RANDOM$RANDOM"
    mkdir -p "$box/bin" "$box/var/lib/dpkg" "$box/var/lib/apt/lists" "$box/var/cache/apt/archives"
    sed -e "s|/var/|$box/var/|g" -e "s|/proc/|$box/proc/|g" "$SCRIPT" > "$box/apt-ready.sh"
    mkdir -p "$box/proc/4242/fd" "$box/proc/999/fd"
    : > "$box/proc/locks"
    # pid 4242 has lock-frontend open; pid 999 has some other file open.
    ln -s "$box/var/lib/dpkg/lock-frontend" "$box/proc/4242/fd/3"
    ln -s "$box/elsewhere" "$box/proc/999/fd/3"
    : > "$box/calls"
    # Every lock file gets an inode; stat reads it back.
    local f n=100
    for f in var/lib/dpkg/lock-frontend var/lib/dpkg/lock var/lib/apt/lists/lock var/cache/apt/archives/lock; do
        : > "$box/$f"
        n=$((n + 1))
        printf '%s\n' "$n" > "$box/$f.ino"
    done
    cat > "$box/bin/stat" <<'STUB'
#!/bin/sh
# stat -c %i <file>
cat "$3.ino"
STUB
    printf '#!/bin/sh\necho "systemctl $*" >> "%s/calls"\ncase "$1" in is-enabled) cat "%s/userconfig" 2>/dev/null; exit 0 ;; esac\nexit 0\n' "$box" "$box" > "$box/bin/systemctl"
    # sleep: count the waits, and run a hook on the Nth (to release a lock).
    printf '#!/bin/sh\necho sleep >> "%s/sleeps"\nn=$(wc -l < "%s/sleeps")\n[ -f "%s/release-at" ] && [ "$n" -ge "$(cat "%s/release-at")" ] && : > "%s/proc/locks"\nexit 0\n' \
        "$box" "$box" "$box" "$box" "$box" > "$box/bin/sleep"
    printf '#!/bin/sh\n[ "$2" = 4242 ] && echo "/usr/bin/python3 /usr/bin/unattended-upgrade" && exit 0\nexit 1\n' > "$box/bin/ps"
    # dpkg: log the call, the frontend it was given, and whether a lock was
    # still held when it ran; answer with $box/dpkg-rc (default 0).
    printf '#!/bin/sh\necho "dpkg $* frontend=$DEBIAN_FRONTEND" >> "%s/calls"\n[ -s "%s/proc/locks" ] && echo "dpkg ran while a lock was held" >> "%s/calls"\nrc=$(cat "%s/dpkg-rc" 2>/dev/null || echo 0)\n[ "$rc" = 0 ] || echo "dpkg: error processing package half-done (--configure)" >&2\nexit "$rc"\n' \
        "$box" "$box" "$box" "$box" > "$box/bin/dpkg"
    chmod +x "$box/bin/"*
}
run_ready() {
    out="$(PATH="$box/bin:/usr/bin:/bin" bash "$box/apt-ready.sh" "$@" 2>&1 </dev/null)"
    rc=$?
}
calls() { cat "$box/calls"; }
sleeps() { { wc -l < "$box/sleeps" || echo 0; } 2>/dev/null | tr -d ' '; }

# --- userconfig.service ---------------------------------------------------

new_box; echo enabled > "$box/userconfig"
run_ready 10
check_eq "$rc" 0 "a box with userconfig.service enabled is made ready"
check_contains "$(calls)" "systemctl disable --now userconfig.service" "by disabling and stopping the service"
check_contains "$(calls)" "systemctl mask userconfig.service" "and masking it, so nothing starts it again"
check_contains "$out" "userconfig.service" "and says so"

new_box; echo masked > "$box/userconfig"
run_ready 10
check_eq "$rc" 0 "an already-masked userconfig.service is fine"
check_lacks "$(calls)" "disable" "and left alone"

new_box   # no such unit: is-enabled prints nothing
run_ready 10
check_eq "$rc" 0 "a box without userconfig.service is fine"
check_lacks "$(calls)" "disable" "and nothing is disabled"

new_box; echo not-found > "$box/userconfig"
run_ready 10
check_lacks "$(calls)" "disable" "a unit systemd reports not-found is not touched"

# --- the package manager's locks ------------------------------------------

new_box
run_ready 10
check_eq "$rc" 0 "free locks: ready at once"
check_eq "$(sleeps)" 0 "without waiting"

# A POSIX lock on lock-frontend (inode 101), as dpkg takes it, by a
# process that has it open.
new_box
printf '1: POSIX  ADVISORY  WRITE 4242 08:03:101 0 EOF\n2: FLOCK  ADVISORY  WRITE 999 00:1a:102 0 EOF\n' > "$box/proc/locks"
run_ready 10
check_eq "$rc" 1 "a lock held throughout fails the boot"
check_contains "$out" "$box/var/lib/dpkg/lock-frontend" "naming the lock"
check_contains "$out" "pid 4242" "and the process holding it"
check_contains "$out" "unattended-upgrade" "and what that process is"
check_eq "$(sleeps)" 5 "after waiting the given time (10s at 2s a poll)"

new_box
printf '2: POSIX  ADVISORY  WRITE 999 00:1a:101 0 EOF\n' > "$box/proc/locks"
run_ready 10
check_eq "$rc" 0 "a lock on the same inode number of another file is not the package manager's"

new_box
printf '1: -> POSIX  ADVISORY  WRITE 4242 08:03:101 0 EOF\n' > "$box/proc/locks"
run_ready 10
check_eq "$rc" 0 "a process WAITING for a lock does not hold it"

new_box
printf '1: POSIX  ADVISORY  WRITE 4242 08:03:101 0 EOF\n' > "$box/proc/locks"
echo 2 > "$box/release-at"
run_ready 10
check_eq "$rc" 0 "a holder that finishes while we wait is waited out"
check_eq "$(sleeps)" 2 "and the wait ends when it does"
check_contains "$out" "waiting" "saying it waited"

for evil in "" 0 abc "10; reboot" -1; do
    new_box
    run_ready "$evil"
    check_eq "$rc" 1 "the guest refuses a wait of $(printf '%q' "$evil")"
done

# --- a transaction an earlier boot left half done -------------------------

# The VM outlives `vm down`, so a provision stopped part way through an
# install leaves dpkg mid-transaction, and every later install refuses
# with "dpkg was interrupted". The boot finishes it, once the locks are
# free, before the consumer's setup script needs the package manager.
new_box
run_ready 10
check_eq "$rc" 0 "free locks: the boot finishes any interrupted dpkg transaction"
check_contains "$(calls)" "dpkg --configure -a" "by running dpkg --configure -a"
check_contains "$(calls)" "frontend=noninteractive" "with no prompt a headless guest could wait on"
check_lacks "$(calls)" "while a lock was held" "and only once the locks are free"

new_box
printf '1: POSIX  ADVISORY  WRITE 4242 08:03:101 0 EOF\n' > "$box/proc/locks"
echo 2 > "$box/release-at"
run_ready 10
check_eq "$rc" 0 "a holder that is waited out"
check_contains "$(calls)" "dpkg --configure -a" "is followed by finishing the transaction"
check_lacks "$(calls)" "while a lock was held" "after the lock is released, not before"

new_box
printf '1: POSIX  ADVISORY  WRITE 4242 08:03:101 0 EOF\n' > "$box/proc/locks"
run_ready 10
check_lacks "$(calls)" "dpkg" "a lock held throughout fails the boot without running dpkg"

new_box; echo 1 > "$box/dpkg-rc"
run_ready 10
check_eq "$rc" 1 "a transaction dpkg cannot finish fails the boot"
check_contains "$out" "dpkg --configure -a" "naming the command"
check_contains "$out" "error processing package half-done" "and showing what dpkg said"

finish apt-ready
