#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/guest-run.sh — runs in a shared guest, one per suite's run (#153). vm.sh sends
# this file to the guest when it boots, to /run, so it goes with the boot.
#
#   guest-run.sh prepare                            once per boot
#   guest-run.sh enter <id> <repo> <share> <cache> <consumer> <script>
#                                                   run a script in the run <id>
#   guest-run.sh tree <id> <repo> <share> <cache> <consumer> <share dir>
#                                                   give the run its own copy of its tree
#   guest-run.sh end <id>                           stop the run and delete its root
#   guest-run.sh setup <repo> <share> <cache> <consumer> <command...>
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
# <repo> and <share> are where this run's tree and share are in the guest, <cache> is
# the directory for /cache, or - for none. <consumer> is whose run this is.
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

# Inside a new namespace. The share first, because <repo> may be under /repo.
bind_tree() {
    local repo="$1" share="$2" cache="$3"
    [ "$share" = /share ] || mount --bind "$share" /share
    [ "$repo" = /repo ] || mount --bind "$repo" /repo
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
    tar -C "$repo" --exclude-caches-all --exclude=./tmp --exclude="./$share_dir" -cf - . |
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
        if [ -n "$(find "$root" -xdev -inum "$inode" -print 2>/dev/null | head -n 1)" ]; then
            losetup -d "$name" 2>/dev/null || true
        fi
    done < <(losetup -l -n -O NAME,BACK-INO 2>/dev/null || true)
}

end() {
    local id="$1" ns="$STATE/ns/$1" ident=""
    exec 9> "$STATE/lock.$id"
    flock 9
    if [ -e "$ns" ]; then
        ident="$(nsenter --mount="$ns" -- readlink /proc/self/ns/mnt 2>/dev/null || true)"
        if [ -n "$ident" ]; then
            signal_members "$ident" TERM || signal_members "$ident" KILL ||
                echo "guest-run: processes of run $id would not stop" >&2
        fi
        umount "$ns" 2>/dev/null || true
    fi
    detach_loops "$ROOTS/$id"
    # The run is over now, and the consumer's /var/cache is free once it is not ready:
    # take_var_cache reads that. Deleting a root can take minutes, and a suite restarted
    # meanwhile should not get an empty directory for it.
    rm -f "$ns" "$STATE/ready.$id" "$STATE/tree.$id"
    find "$ROOTS/$id" -xdev -delete 2>/dev/null || true
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
