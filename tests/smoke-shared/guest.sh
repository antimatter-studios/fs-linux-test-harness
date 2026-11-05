# shellcheck shell=bash
#
# guest.sh — sourced by tests/smoke.sh: FLTH_SHARED_ROOT on a real guest (#153).
# Two consumers join one guest at once. The oracles are the guest's own: findmnt,
# losetup, and the process table the suites' commands are in.

dir="$(mktemp -d "${TMPDIR:-/tmp}/flth-shared.XXXXXX")"
dir="$(cd "$dir" && pwd -P)"
one="$dir/trees/one"
two="$dir/deep/trees/two"
make_tree() {
    # make_tree <path> <name> <package its setup installs>
    mkdir -p "$1/.vm-share"
    printf '[project]\nname = "%s"\n\n[setup]\nscript = "setup.sh"\n\n[vm]\nguest = "%s"\n' "$2" "$SMOKE_GUEST" > "$1/fs-linux-test-harness.toml"
    printf '%s\n' "$2" > "$1/name"
    printf '%s\n' "$2" > "$1/.vm-share/name"
    cat > "$1/setup.sh" <<SETUP
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq $3 >/dev/null
cat /repo/name > /usr/local/share/setup-saw-\$FLTH_PROJECT
SETUP
}
make_tree "$one" shared-one bc
make_tree "$two" shared-two jq
# Its own cache: this boots its own machine, not one a person on this host uses.
shared_vm() {
    local tree="$1"
    shift
    (cd "$tree" && FLTH_CONFIG='' FLTH_CACHE_DIR="$dir/cache" FLTH_SHARED_ROOT="$dir" \
        FLTH_SHARED_MEMORY=2G FLTH_SHARED_CPUS=2 FLTH_SHARED_DISK=16G "$VM" "$@")
}

step "shared guest: two consumers join at once (#153)"
t0=$(date +%s)
shared_vm "$one" up > "$dir/up-one.log" 2>&1 &
a_pid=$!
shared_vm "$two" up > "$dir/up-two.log" 2>&1 &
b_pid=$!
wait "$a_pid"
check_eq "$?" 0 "the first consumer's up succeeds"
wait "$b_pid"
rc=$?
check_eq "$rc" 0 "and so does the second's"
if [ "$rc" -ne 0 ]; then
    cut -c1-200 "$dir/up-two.log" | tail -n 20
fi
echo "  (one boot and both setups took $(( $(date +%s) - t0 ))s)"
check_eq "$(shared_vm "$one" exec 'command -v bc >/dev/null && command -v jq >/dev/null && echo both' 2>/dev/null)" both \
    "each setup installed its own tools, alongside each other"
check_eq "$(shared_vm "$one" exec 'cat /usr/local/share/setup-saw-shared-one /usr/local/share/setup-saw-shared-two' 2>/dev/null | paste -sd, -)" "shared-one,shared-two" \
    "each setup read its own tree"
check_eq "$(shared_vm "$one" exec 'cat /repo/name /share/name' 2>/dev/null | paste -sd, -)" "shared-one,shared-one" \
    "the first consumer's calls see its tree and share"
check_eq "$(shared_vm "$two" exec 'cat /repo/name /share/name' 2>/dev/null | paste -sd, -)" "shared-two,shared-two" \
    "the second's see its own, at the same paths"
printf 'from the host\n' > "$two/late"
check_eq "$(shared_vm "$two" exec 'cat /repo/late' 2>/dev/null)" "from the host" "a file the host writes under its tree is there"
shared_vm "$two" exec 'echo from the guest > /share/back' 2>/dev/null
check_eq "$(cat "$two/.vm-share/back" 2>/dev/null)" "from the guest" "and what the guest puts on the share reaches the host"
check_eq "$(shared_vm "$one" exec 'test -e /share/back && echo seen || echo private' 2>/dev/null)" private "and not the other consumer"

step "shared guest: each run has its own files and mounts"
shared_vm "$one" exec 'echo mine > /tmp/left; mkdir -p /mnt/t; mount -t tmpfs none /mnt/t' 2>/dev/null
check_eq "$(shared_vm "$one" exec 'cat /tmp/left; findmnt -n -o TARGET /mnt/t' 2>/dev/null | paste -sd, -)" "mine,/mnt/t" "a run's files and mounts last between its calls"
check_eq "$(shared_vm "$two" exec 'test -e /tmp/left && echo seen; findmnt -n -o TARGET /mnt/t; echo end' 2>/dev/null)" end "and another run sees neither"
check_eq "$(shared_vm "$one" exec 'findmnt -n -o FSTYPE -T /var/tmp >/dev/null; stat -c %d /var/tmp "$FLTH_RUN_ROOT/var-tmp" | uniq | wc -l' 2>/dev/null)" 1 \
    "its /var/tmp is in its root, on the guest's own disk"

step "shared guest: a run's copy of its tree keeps its holes"
# An image is mostly holes, and a copy that fills them takes its full size on the guest's
# disk. The oracle is the guest's own du, on what guest-tree made.
truncate -s 256M "$one/sparse.img"
sparse="$(shared_vm "$one" session bash -c '"$1" guest-tree && "$1" exec "du -m /repo/sparse.img | cut -f1; stat -c %s /repo/sparse.img"' flth-session "$VM" 2>/dev/null | paste -sd, -)"
check_eq "$sparse" "0,268435456" "a 256 MiB image of holes takes no room there, and keeps its size"

step "shared guest: a signal to one suite leaves the other running"
# Each suite: a session whose one command prints its pid and a loop device it
# attached by hand, and sleeps.
suite='truncate -s 16M /var/tmp/img; losetup -f --show /var/tmp/img > /share/loop; echo $$ > /share/pid; exec sleep 600'
(cd "$one" && FLTH_CONFIG='' FLTH_CACHE_DIR="$dir/cache" FLTH_SHARED_ROOT="$dir" FLTH_SHARED_MEMORY=2G FLTH_SHARED_CPUS=2 FLTH_SHARED_DISK=16G \
    exec "$VM" session "$VM" exec "$suite") >/dev/null 2>&1 &
a_pid=$!
(cd "$two" && FLTH_CONFIG='' FLTH_CACHE_DIR="$dir/cache" FLTH_SHARED_ROOT="$dir" FLTH_SHARED_MEMORY=2G FLTH_SHARED_CPUS=2 FLTH_SHARED_DISK=16G \
    exec "$VM" session "$VM" exec "$suite") >/dev/null 2>&1 &
b_pid=$!
tries=0
until [ -s "$one/.vm-share/pid" ] && [ -s "$two/.vm-share/pid" ] || [ "$tries" -ge 120 ]; do
    sleep 1
    tries=$((tries + 1))
done
a_cmd="$(cat "$one/.vm-share/pid" 2>/dev/null)"
b_cmd="$(cat "$two/.vm-share/pid" 2>/dev/null)"
a_loop="$(cat "$one/.vm-share/loop" 2>/dev/null)"
b_loop="$(cat "$two/.vm-share/loop" 2>/dev/null)"
check_true '[ -n "$a_cmd" ] && [ -n "$b_cmd" ] && [ "$a_cmd" != "$b_cmd" ]' "both suites' commands run at once" "the suites did not both start: '$a_cmd' '$b_cmd'"
check_contains "$(shared_vm "$one" status 2>&1)" "shared-two (pid $b_pid)" "status lists them"
shared_vm "$one" down 2>/dev/null
check_eq "$?" 0 "a shutdown request while they run succeeds"
check_true 'shared_vm "$one" status >/dev/null 2>&1' "and leaves the guest up" "and stopped the guest"
kill -TERM "$a_pid"
wait "$a_pid"
check_eq "$?" 143 "the signalled suite stops with the signal's status"
check_eq "$(shared_vm "$two" exec "kill -0 $a_cmd 2>/dev/null && echo alive || echo gone" 2>/dev/null)" gone "its command in the guest stops"
check_eq "$(shared_vm "$two" exec "kill -0 $b_cmd 2>/dev/null && echo alive || echo gone" 2>/dev/null)" alive "the other suite's does not"
# The list of attached devices: naming a free device still prints its name.
attached="$(shared_vm "$two" exec 'losetup -l -n -O NAME' 2>/dev/null | tr -d ' ' | paste -sd, -)"
check_eq "$attached" "$b_loop" "the loop device the stopped run left is detached, and the other run's is not ($a_loop, $b_loop)"
check_eq "$(shared_vm "$two" exec 'ls /var/lib/fs-linux-test-harness/runs | wc -l' 2>/dev/null | tr -d ' ')" 3 \
    "and the stopped run's root is gone: the other suite's and two standing runs remain"

step "shared guest: a suite killed outright does not keep it up"
kill -KILL "$b_pid"
wait "$b_pid" 2>/dev/null
check_contains "$(shared_vm "$one" status 2>&1)" "in use by: " "status still answers"
shared_vm "$one" down 2>/dev/null
check_eq "$?" 0 "the shutdown request with only a dead suite listed succeeds"
check_true '! shared_vm "$one" status >/dev/null 2>&1' "and stops the guest" "and left the guest running"

step "shared guest: a later boot of the same machine"
# Nothing a boot writes reaches this machine's disk, Vagrant's own key included.
shared_vm "$one" up > "$dir/up-again.log" 2>&1
rc=$?
check_eq "$rc" 0 "the machine boots again"
if [ "$rc" -ne 0 ]; then
    grep -E 'Authentication failure|Timed out|refusing' "$dir/up-again.log" | sort -u | cut -c1-160
fi
check_eq "$(shared_vm "$one" exec 'cat /repo/name' 2>/dev/null)" shared-one "and its calls run"
shared_vm "$one" down >/dev/null 2>&1

step "shared guest: destroy"
shared_vm "$one" destroy >/dev/null 2>&1
check_eq "$?" 0 "the shared machine is destroyed"
rm -rf "$dir"
