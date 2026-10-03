# shellcheck shell=bash
#
# tests/stubs/engine.sh — the engine interface (scripts/lib/engine.sh),
# answered from files under $FLTH_TEST_STUB so a test decides what the
# "VM" does. Every call is logged to $FLTH_TEST_STUB/calls.
#
#   state          what engine_state prints (running|stopped|absent|unknown)
#   up_failures    how many engine_up calls fail before one succeeds
#   after_up       state after a successful up (default running)
#   after_failed_up state after a failed up (default stopped)
#   after_down     state after engine_down (default stopped)
#   after_destroy  state after engine_destroy (default absent)
#   ps_unreadable  present: engine_alive answers 2
#
# THE DISK. The guest's setup-stamp directory is $STUB/guest-lib
# for the length of a boot, and $STUB/disk is what the machine's disk
# keeps. Every boot starts from a copy of the disk; a boot from `absent`
# starts from an empty one. When a boot made with `--persist` stops, what
# it wrote is kept; when any other boot stops, it is thrown away. That is
# the engine's promise (lib/engine.sh, engine_up), modelled so the
# orchestration can be held to using it.
#
# THE CACHE. A consumer that declares one ([cache] size) has $STUB/cache
# as its guest's /cache for every boot, persist or not: it is a disk of
# its own, outside the overlay. destroy deletes it with the machine.

STUB="${FLTH_TEST_STUB:?the stub engine needs FLTH_TEST_STUB}"

stub_log() { printf '%s\n' "$*" >> "$STUB/calls"; }
stub_read() { cat "$STUB/$1" 2>/dev/null || printf '%s\n' "$2"; }

engine_prepare() {
    stub_log prepare
    mkdir -p "$FLTH_MACHINE_DIR" "$FLTH_SHARE_HOST"
}

engine_identity() { printf '%s\n' "$FLTH_MACHINE_DIR/stub"; }

engine_state() {
    stub_log state
    cat "$STUB/state"
}

engine_up() {
    local n persist=0
    [ "${1:-}" = --persist ] && persist=1
    n="$(stub_read up_failures 0)"
    stub_log "up${1:+ $1}"
    if [ "$n" -gt 0 ]; then
        echo $((n - 1)) > "$STUB/up_failures"
        stub_read after_failed_up stopped > "$STUB/state"
        return 1
    fi
    [ "$(cat "$STUB/state")" = absent ] && rm -rf "$STUB/disk"
    mkdir -p "$STUB/disk"
    rm -rf "$STUB/guest-lib"
    cp -R "$STUB/disk" "$STUB/guest-lib"
    echo "$persist" > "$STUB/boot-persist"
    rm -f "$STUB/guest-cache"
    if [ -n "${CFG_cache_size:-}" ]; then
        mkdir -p "$STUB/cache"
        ln -s "$STUB/cache" "$STUB/guest-cache"
    fi
    stub_read after_up running > "$STUB/state"
}

# The boot has ended: keep what it wrote only if it was a --persist boot.
stub_boot_ended() {
    if [ "$(stub_read boot-persist 0)" = 1 ]; then
        rm -rf "$STUB/disk"
        cp -R "$STUB/guest-lib" "$STUB/disk"
    fi
    rm -rf "$STUB/boot-persist" "$STUB/guest-lib" "$STUB/guest-cache"
}

engine_down() {
    stub_log "down${1:+ $1}"
    stub_read after_down stopped > "$STUB/state"
    case "$(cat "$STUB/state")" in stopped | absent) stub_boot_ended ;; esac
}

engine_destroy() {
    stub_log destroy
    stub_read after_destroy absent > "$STUB/state"
    rm -rf "$STUB/disk" "$STUB/guest-lib" "$STUB/boot-persist" "$STUB/cache" "$STUB/guest-cache"
}

# Runs the script HERE, with the guest's fixed paths — the setup stamp,
# the hold marker, the repository mount, the cache — redirected into the stub
# directory, so the real logic executes against a tree a test can make.
engine_run() {
    stub_log run
    printf '%s\n' "$1" >> "$STUB/scripts"
    printf '%s\n' "$1" |
        sed -e "s|/var/lib/fs-linux-test-harness|$STUB/guest-lib|g" \
            -e "s|/run/fs-linux-test-harness-held|$STUB/guest-held|g" \
            -e "s|/run/fs-linux-test-harness-rearmed|$STUB/guest-rearmed|g" \
            -e "s|/repo|$STUB/guest-repo|g" \
            -e "s|/cache\\([/ ']\\)|$STUB/guest-cache\\1|g" -e "s|/cache\$|$STUB/guest-cache|" |
        bash -s
}

engine_copy() {
    cp "$1" "$FLTH_SHARE_HOST/"
    printf '/share/%s\n' "$(basename "$1")"
}

engine_alive() {
    [ -f "$STUB/ps_unreadable" ] && return 2
    [ "$(cat "$STUB/state")" = running ]
}
