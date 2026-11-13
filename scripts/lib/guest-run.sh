#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/guest-run.sh — runs in a shared guest, one per suite's run (#153). vm.sh sends
# this file to the guest when it boots, to /run, so it goes with the boot.
#
#   guest-run.sh prepare                            once per boot
#   guest-run.sh enter <id> <tag> <share> <cache> <consumer> <script>
#                                                   run a script in the run <id>
#   guest-run.sh tree <id> <tag> <share> <cache> <consumer> <share dir>
#                                                   give the run its own copy of its tree
#   guest-run.sh end <id>                           stop the run and delete its root
#   guest-run.sh setup <tag> <share> <cache> <consumer> <command...>
#                                                   run a consumer's setup with its tree
#
# A RUN IS A RANDOM ROOT ON THE GUEST'S OWN DISK AND A PRIVATE MOUNT NAMESPACE, in
# which that root's directories are mounted where a suite already looks: /tmp,
# /var/tmp and /mnt, with its own tree at /repo and its own share at /share. A suite's scripts name those paths and need no change, and no two runs can
# see each other's files there or overwrite them. What a suite mounts stays in its
# namespace too. The namespace is held by a file, not a process, so it lasts between
# the many calls of a run and costs nothing while none is running.
#
# The namespace also says what belongs to a run, whatever process group or parent a
# command has since moved to: `end` stops exactly the processes in it.
#
# <tag> is the virtiofs tag of the run's own tree, a device the host attached to the
# running guest for this run (#222), and <share> is where the share is in that tree.
# <cache> is the directory for /cache, or - for none. <consumer> is whose run this is.
#
# /VAR/CACHE IS THE CONSUMER'S, NOT THE RUN'S, because that is where a suite keeps its
# build directory, and a run should not build from nothing on a guest that stays up. It
# lasts as long as the guest and stays on the guest's own disk. One run of a consumer has
# it at a time. A second at once has a directory in its root instead: two runs cannot
# share a build directory, whose test programs one would rebuild under the other.
set -euo pipefail

STATE=/run/fs-linux-test-harness-runs
ROOTS=/var/lib/fs-linux-test-harness/runs
CONSUMERS=/var/lib/fs-linux-test-harness/consumers
SSH_SESSIONS=128
# How long, in ticks of 0.1 s, each signal has to stop a run's processes.
STOP_TICKS=50

# `unshare --mount=<file>` needs the file on a mount that does not propagate.
#
# EVERY SUITE'S CALLS SHARE ONE CONNECTION, and sshd's default of ten sessions on a
# connection is a limit two suites running calls in parallel can reach. Past it, a
# call fails with ssh's own status.
prepare() {
    mkdir -p "$STATE/ns" "$ROOTS"
    # Where a run mounts its tree and its share, in its own namespace.
    mkdir -p /repo /share 2>/dev/null || true
    if ! mountpoint -q "$STATE/ns"; then
        mount --bind "$STATE/ns" "$STATE/ns"
        mount --make-private "$STATE/ns"
    fi
    if [ -d /etc/ssh/sshd_config.d ]; then
        printf 'MaxSessions %s\n' "$SSH_SESSIONS" > /etc/ssh/sshd_config.d/fs-linux-test-harness.conf
        systemctl reload ssh
    fi
}

# Print the directory for this run's /var/cache, taking the consumer's if it is free. A
# call outside any session never takes it: nothing would give it back.
take_var_cache() {
    local id="$1" consumer="$2" owner="$STATE/owner.$2" holder
    case "$id" in
        *-worktree) printf '%s\n' "$ROOTS/$id/var-cache"; return 0 ;;
    esac
    exec 8> "$owner.lock"
    flock 8
    holder="$(cat "$owner" 2>/dev/null || true)"
    if [ -n "$holder" ] && [ -e "$STATE/ready.$holder" ]; then
        printf '%s\n' "$ROOTS/$id/var-cache"
    else
        printf '%s\n' "$id" > "$owner"
        printf '%s\n' "$CONSUMERS/$consumer/var-cache"
    fi
    exec 8>&-
}

# Inside a new namespace. The device has just been attached, and the guest's kernel
# probes it a moment later, so the mount is tried until it takes: 30 s at most.
bind_tree() {
    local tag="$1" share="$2" cache="$3" tries=0
    until mount -t virtiofs "$tag" /repo 2>/dev/null; do
        if [ "$tries" -ge 3000 ]; then
            echo "guest-run: the run's tree (virtiofs $tag) could not be mounted" >&2
            return 1
        fi
        sleep 0.01
        tries=$((tries + 1))
    done
    mkdir -p "/repo/$share"
    mount --bind "/repo/$share" /share
    [ "$cache" = - ] || mount --bind "$cache" /cache
}

bind() {
    local root="$1" var_cache="$5"
    bind_tree "$2" "$3" "$4"
    mount --bind "$root/tmp" /tmp
    mount --bind "$root/var-tmp" /var/tmp
    mount --bind "$var_cache" /var/cache
    mount --bind "$root/mnt" /mnt
}

# A CONSUMER'S SETUP SCRIPT reads its own tree at /repo, and what it installs belongs
# to the whole guest, so it has this consumer's /repo and /share and nothing else of a
# run's. Its namespace goes when it ends.
setup() {
    local repo="$1" share="$2" cache="$3"
    shift 4
    if [ "$cache" != - ]; then
        mkdir -p "$cache" /cache
    fi
    exec unshare --mount --propagation private bash "$0" setup-inner "$repo" "$share" "$cache" "$@"
}

setup_inner() {
    local repo="$1" share="$2" cache="$3"
    shift 3
    bind_tree "$repo" "$share" "$cache"
    exec "$@"
}

# The first call of a run makes it. A suite's first calls can arrive together.
begin() {
    local id="$1" repo="$2" share="$3" cache="$4" consumer="$5" root="$ROOTS/$1" ns="$STATE/ns/$1" var_cache
    exec 9> "$STATE/lock.$id"
    flock 9
    if [ ! -e "$STATE/ready.$id" ]; then
        var_cache="$(take_var_cache "$id" "$consumer")"
        mkdir -p "$root/tmp" "$root/var-tmp" "$var_cache" "$root/mnt"
        chmod 1777 "$root/tmp" "$root/var-tmp"
        if [ "$cache" != - ]; then
            mkdir -p "$cache" /cache
        fi
        : > "$ns"
        unshare --mount="$ns" --propagation private bash "$0" bind "$root" "$repo" "$share" "$cache" "$var_cache"
        : > "$STATE/ready.$id"
    fi
    exec 9>&-
}

enter() {
    local id="$1" repo="$2" share="$3" cache="$4" consumer="$5" script="$6"
    [ -e "$STATE/ready.$id" ] || begin "$id" "$repo" "$share" "$cache" "$consumer"
    export FLTH_RUN_ROOT="$ROOTS/$id"
    exec nsenter --mount="$STATE/ns/$id" --wd="$PWD" -- bash -c "$script"
}

# THE RUN'S OWN COPY OF ITS TREE, FOR A SUITE THAT RUNS ENTIRELY IN THE GUEST. Nothing
# on the host touches it while it runs, so two runs of one tree cannot overwrite each
# other, and a host editing its checkout does not change a run in progress. A suite
# on the host cannot use this: it writes files under its checkout and asks the guest
# to read them. What a directory marks as a cache and the scratch directory stay
# behind; the share stays where it is, reached through the same name.
tree() {
    local id="$1" repo="$2" share="$3" cache="$4" consumer="$5" share_dir="$6" root="$ROOTS/$1"
    [ -e "$STATE/ready.$id" ] || begin "$id" "$repo" "$share" "$cache" "$consumer"
    [ ! -e "$STATE/tree.$id" ] || return 0
    mkdir -p "$root/tree"
    # -S keeps holes: a suite's images are mostly holes, and filling them took one
    # consumer's 3.5 GiB of fixtures to 38 GiB of the guest's disk.
    nsenter --mount="$STATE/ns/$id" -- tar -S -C /repo --exclude-caches-all --exclude=./tmp --exclude="./$share_dir" -cf - . |
        tar -C "$root/tree" --no-same-owner -xf -
    mkdir -p "$root/tree/tmp" "$(dirname "$root/tree/$share_dir")"
    ln -s /share "$root/tree/$share_dir"
    nsenter --mount="$STATE/ns/$id" -- mount --bind "$root/tree" /repo
    : > "$STATE/tree.$id"
}

# The processes in the namespace named $1, as `readlink /proc/<pid>/ns/mnt` says it.
members() {
    local dir pid
    for dir in /proc/[0-9]*; do
        pid="${dir##*/}"
        if [ "$(readlink "$dir/ns/mnt" 2>/dev/null || true)" = "$1" ] && kill -0 "$pid" 2>/dev/null; then
            printf '%s ' "$pid"
        fi
    done
}

# What a process that would not stop is: its name, its state, and where in the kernel
# it waits (#187). A process in uninterruptible sleep (D) takes no signal at all,
# and only a reboot clears it.
describe() {
    local pid="$1" comm state wchan
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"
    state="$(sed -n 's/^.*) \([A-Za-z]\) .*/\1/p' "/proc/$pid/stat" 2>/dev/null || true)"
    wchan="$(cat "/proc/$pid/wchan" 2>/dev/null || true)"
    printf 'process %s (%s), state %s%s' "$pid" "$comm" "${state:-?}" "${wchan:+, waiting in $wchan}"
}

signal_members() {
    local ident="$1" signal="$2" pids ticks=0
    while [ "$ticks" -lt "$STOP_TICKS" ]; do
        pids="$(members "$ident")"
        [ -n "$pids" ] || return 0
        # shellcheck disable=SC2086  # the pids split into words
        kill "-$signal" $pids 2>/dev/null || true
        sleep 0.1
        ticks=$((ticks + 1))
    done
    return 1
}

# A LOOP DEVICE IS NOT IN A NAMESPACE. A mount that made one with autoclear lets it go
# when the namespace goes. One attached by hand and left behind stays, holding its
# image, until this detaches it. A device is the run's only if its backing file is in
# the run's root, so another run's is left alone.
detach_loops() {
    local root="$1" name inode
    while read -r name inode; do
        case "$inode" in '' | *[!0-9]*) continue ;; esac
        if [ -n "$(timeout 30 find "$root" -xdev -inum "$inode" -print 2>/dev/null | head -n 1)" ]; then
            timeout 30 losetup -d "$name" 2>/dev/null || true
        fi
    done < <(losetup -l -n -O NAME,BACK-INO 2>/dev/null || true)
}

# A LOOP DEVICE BACKED BY A FILE OF THE RUN'S TREE holds the tree's mount, and so its
# device, after the namespace has gone (#222). Which are the run's is told by the
# device of their backing file: the run's virtiofs mount is a filesystem of its own.
# Detached before the namespace goes; one still in use is detached when it is let go
# of, so the caller waits for them all to go.
tree_loops() {
    local ns="$1" devs name dev
    devs=" $(nsenter --mount="$ns" -- findmnt -rn -t virtiofs -o MAJ:MIN 2>/dev/null | tr '\n' ' ') "
    [ "$devs" != "  " ] || return 0
    while read -r name dev; do
        case "$devs" in *" $dev "*) printf '%s\n' "$name" ;; esac
    done < <(losetup -l -n -O NAME,BACK-MAJ:MIN 2>/dev/null || true)
}

end() {
    local id="$1" ns="$STATE/ns/$1" ident="" loops="" loop ticks=0
    exec 9> "$STATE/lock.$id"
    flock 9
    if [ -e "$ns" ]; then
        ident="$(nsenter --mount="$ns" -- readlink /proc/self/ns/mnt 2>/dev/null || true)"
        if [ -n "$ident" ] && ! signal_members "$ident" TERM && ! signal_members "$ident" KILL; then
            # Named, and left: the rest of the end does not wait on them (#187).
            local pid
            for pid in $(members "$ident"); do
                echo "guest-run: run $id: $(describe "$pid") would not stop; the run ends without it" >&2
            done
        fi
        loops="$(tree_loops "$ns")"
        for loop in $loops; do losetup -d "$loop" 2>/dev/null || true; done
        # Bounded: a process that will not die can hold a mount (#187).
        timeout 30 umount "$ns" 2>/dev/null || true
        while [ -n "$loops" ] && [ "$ticks" -lt 100 ]; do
            for loop in $loops; do
                losetup "$loop" >/dev/null 2>&1 && break
                loops="${loops/$loop/}"
            done
            loops="$(printf '%s' "$loops" | tr -s ' \n' ' ' | sed 's/^ *//; s/ *$//')"
            [ -z "$loops" ] || sleep 0.1
            ticks=$((ticks + 1))
        done
        [ -z "$loops" ] || echo "guest-run: loop devices of run $id are still attached: $loops" >&2
    fi
    detach_loops "$ROOTS/$id"
    # The run is over now, and the consumer's /var/cache is free once it is not ready:
    # take_var_cache reads that. Deleting a root can take minutes, and a suite restarted
    # meanwhile should not get an empty directory for it.
    rm -f "$ns" "$STATE/ready.$id" "$STATE/tree.$id"
    timeout 120 find "$ROOTS/$id" -xdev -delete 2>/dev/null || true
    rm -f "$STATE/lock.$id"
    exec 9>&-
}

command="$1"
shift
case "$command" in
    prepare | bind | enter | tree | end | setup) "$command" "$@" ;;
    setup-inner) setup_inner "$@" ;;
    *) echo "guest-run: unknown command $command" >&2; exit 2 ;;
esac
