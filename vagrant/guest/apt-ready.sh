#!/usr/bin/env bash
#
# apt-ready.sh [seconds] — make sure nothing in the guest is holding the
# package manager before the consumer's setup script needs it. Runs as
# root in the guest on every boot, before anything else the harness does.
#
# WHY. A consumer's setup script installs its tooling with apt, and apt
# fails at once on a held dpkg lock. The macOS box
# (christhomas/vagrant-rpi-bookworm-arm64) ships Raspberry Pi OS's
# first-boot dialog, userconfig.service, which waits for a keyboard that
# a headless VM does not have and holds the lock for ever. So it is
# disabled, stopped and masked here. Anything else holding the lock — a
# first boot's unattended upgrade, say — is waited out for up to the
# given number of seconds (default 300), and past that the boot FAILS,
# naming the lock and the process holding it, instead of the setup script
# failing later on a lock nothing explains.
#
# Once the locks are free it finishes any dpkg transaction an earlier
# boot was stopped in the middle of (see the last section), so a consumer
# never meets "dpkg was interrupted" and never carries its own recovery.
#
# Who holds a lock is read from /proc/locks, the kernel's own list: dpkg
# takes POSIX (fcntl) locks, which `flock` cannot see, and this needs no
# tool beyond coreutils and awk to find them.
set -euo pipefail

WAIT="${1-300}"
POLL=2
LOCKS=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)

case "$WAIT" in
    '' | *[!0-9]* | 0*) echo "apt-ready: seconds must be a positive integer, got '$WAIT'" >&2; exit 1 ;;
esac
[ "${#WAIT}" -le 5 ] || { echo "apt-ready: at most five digits, got '$WAIT'" >&2; exit 1; }

# --- the first-boot dialog ------------------------------------------------

# is-enabled prints nothing (older systemd) or not-found for a unit that
# does not exist, and exits non-zero for several states that do; the
# printed state is the answer.
state="$(systemctl is-enabled userconfig.service 2>/dev/null || true)"
case "$state" in
    '' | not-found | masked | masked-runtime) ;;
    *)
        systemctl disable --now userconfig.service
        systemctl mask userconfig.service
        echo "apt-ready: userconfig.service ($state) disabled, stopped and masked: it waits for a keyboard and holds the dpkg lock"
        ;;
esac

# --- the package manager's locks ------------------------------------------

# Print "<lock> <pid>" for the first lock some process holds, or nothing.
#
# A lock in /proc/locks is named by device and inode, but the device is
# the filesystem's own, which is not always what stat reports (one with
# subvolumes gives each its own). So the inode picks the candidates and
# the holder is confirmed by having that very file open.
held() {
    local f ino pid fd
    for f in "${LOCKS[@]}"; do
        [ -e "$f" ] || continue
        ino="$(stat -c %i "$f")"
        # A line with "->" is a process WAITING for the lock, not holding it.
        while read -r pid; do
            for fd in /proc/"$pid"/fd/*; do
                if [ "$(readlink "$fd" 2>/dev/null)" = "$f" ]; then
                    printf '%s %s\n' "$f" "$pid"
                    return 0
                fi
            done
        done < <(awk -v ino="$ino" '
            /->/ { next }
            { for (i = 2; i <= NF; i++)
                if ($i ~ /^[0-9a-f]+:[0-9a-f]+:[0-9]+$/) {
                    split($i, id, ":"); if (id[3] == ino) print $(i - 1); next
                } }' /proc/locks)
    done
}

tries=$(( (WAIT + POLL - 1) / POLL ))
said=""
while :; do
    holder="$(held)"
    [ -n "$holder" ] || break
    lock="${holder% *}"
    pid="${holder##* }"
    what="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [ "$tries" -le 0 ]; then
        echo "apt-ready: $lock is still held by pid $pid (${what:-exited}) after ${WAIT}s." >&2
        echo "    The consumer's setup script could not install anything; see what that process is waiting for." >&2
        exit 1
    fi
    if [ "$said" != "$holder" ]; then
        echo "apt-ready: waiting for $lock, held by pid $pid (${what:-exited})"
        said="$holder"
    fi
    sleep "$POLL"
    tries=$((tries - 1))
done
[ -z "$said" ] || echo "apt-ready: the package manager's locks are free"

# --- a transaction an earlier boot left half done ---------------------------

# THE VM OUTLIVES `vm.sh down`, and so does the state of its package
# database. A setup script stopped part way through an install — by the
# reaper, a deadline, a cancelled CI job, a closed laptop — leaves dpkg in
# the middle of a transaction, and from then on every install refuses with
# "dpkg was interrupted, you must manually run 'dpkg --configure -a'", on
# every boot, because nothing in the guest ever finishes it. Finishing it
# here, once the locks are free and before the setup script runs, is the
# one place that covers every consumer; it costs nothing when there is
# nothing to finish. Noninteractive, because a headless guest has nobody
# to answer a configuration prompt.
if ! out="$(DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>&1 </dev/null)"; then
    echo "apt-ready: dpkg --configure -a could not finish the transaction an earlier boot left half done:" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    exit 1
fi
[ -z "$out" ] || echo "apt-ready: finished the dpkg transaction an earlier boot left half done"
