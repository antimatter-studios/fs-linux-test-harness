# shellcheck shell=bash
#
# tests/stubs/engine.sh — the engine interface (scripts/lib/engine.sh),
# answered from files under $FLTH_TEST_STUB so a test decides what the
# "VM" does. Every call is logged to $FLTH_TEST_STUB/calls.
#
#   state          what engine_state prints (running|stopped|absent|unknown)
#   up_failures    how many engine_up calls fail before one succeeds
#   after_up       state after a successful up (default running)
#   up_delay       seconds a successful up takes before the VM is running
#   after_failed_up state after a failed up (default stopped)
#   after_down     state after engine_down (default stopped)
#   after_force_down state after engine_down --force (default: after_down's)
#   after_destroy  state after engine_destroy (default absent)
#   ps_unreadable  present: engine_alive answers 2
#   console        what every boot, failed or not, writes to its console log
#   vm_status      what engine_vm_status prints; absent: QEMU does not answer
#   guest_answers  present: engine_guest_answers says the guest answers
#   ends_on_probe  present: the VM stops when the guest is first probed, as one
#                  shutting down does just after it drops its connections
#   gate_up        present: a successful up writes gate_up.reached and waits for
#                  this file to go, with the VM not yet running
#   host-bin       made by the engine: a `sync` that logs, first on every guest
#                  script's PATH, so no test runs the host's own
#   gate_down      present: a down writes gate_down.reached and waits for this
#                  file to go, with the VM already stopped
#   on_failed_up   a script run as an up fails, for what an attempt's length does
#   on_force_down  a script run as a forced down begins, for what can happen
#                  between two attempts
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

# Holds a call at a known point, so a test can race it without guessing a delay.
stub_gate() {
    local tries=0
    [ -f "$STUB/$1" ] || return 0
    : > "$STUB/$1.reached"
    while [ -f "$STUB/$1" ] && [ "$tries" -lt 600 ]; do
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
}

engine_prepare() {
    stub_log prepare
    mkdir -p "$FLTH_MACHINE_DIR" "$FLTH_SHARE_HOST"
}

engine_identity() { printf '%s\n' "$FLTH_MACHINE_DIR/stub"; }

engine_boot_identity() {
    [ ! -f "$STUB/boot_identity_unreadable" ] || return 2
    stub_read boot_identity 0
}

engine_console_log() { printf '%s\n' "$STUB/console.log"; }

# The real engine's answers are held by tests/box-catalog.sh, which talks to a
# stand-in vagrant. A stubbed boot never fails for want of a box.
engine_box_failure() { return 1; }

engine_state() {
    stub_log state
    cat "$STUB/state"
}

engine_up() {
    local n persist=0
    [ "${1:-}" = --persist ] && persist=1
    n="$(stub_read up_failures 0)"
    stub_log "up${1:+ $1}"
    rm -f "$STUB/console.log"
    [ -f "$STUB/console" ] && cp "$STUB/console" "$STUB/console.log"
    if [ "$n" -gt 0 ]; then
        echo $((n - 1)) > "$STUB/up_failures"
        stub_read after_failed_up stopped > "$STUB/state"
        [ ! -f "$STUB/on_failed_up" ] || bash "$STUB/on_failed_up"
        return 1
    fi
    [ "$(cat "$STUB/state")" = absent ] && rm -rf "$STUB/disk"
    mkdir -p "$STUB/disk"
    rm -rf "$STUB/guest-lib" "$STUB/attached"
    cp -R "$STUB/disk" "$STUB/guest-lib"
    echo "$persist" > "$STUB/boot-persist"
    rm -f "$STUB/guest-cache"
    if [ -n "${CFG_cache_size:-}" ]; then
        mkdir -p "$STUB/cache"
        ln -s "$STUB/cache" "$STUB/guest-cache"
    fi
    stub_gate gate_up
    # A boot takes time, and until it ends the VM is not running.
    /bin/sleep "$(stub_read up_delay 0)"
    printf '%s\n' "$(( $(stub_read boot_identity 0) + 1 ))" > "$STUB/boot_identity"
    stub_read after_up running > "$STUB/state"
}

# The boot has ended: keep what it wrote only if it was a --persist boot.
stub_boot_ended() {
    if [ "$(stub_read boot-persist 0)" = 1 ]; then
        rm -rf "$STUB/disk"
        cp -R "$STUB/guest-lib" "$STUB/disk"
    fi
    rm -rf "$STUB/boot-persist" "$STUB/guest-lib" "$STUB/guest-cache" "$STUB/attached"
}

engine_down() {
    stub_log "down${1:+ $1}"
    if [ "${1:-}" = --force ]; then
        [ ! -f "$STUB/on_force_down" ] || bash "$STUB/on_force_down"
        stub_read after_force_down "$(stub_read after_down stopped)" > "$STUB/state"
    else
        stub_read after_down stopped > "$STUB/state"
    fi
    case "$(cat "$STUB/state")" in stopped | absent) stub_boot_ended ;; esac
    stub_gate gate_down
}

engine_destroy() {
    stub_log destroy
    stub_read after_destroy absent > "$STUB/state"
    rm -rf "$STUB/disk" "$STUB/guest-lib" "$STUB/boot-persist" "$STUB/cache" "$STUB/guest-cache" "$STUB/attached"
}

# A RUN'S TREE, ATTACHED WHILE THE GUEST RUNS (#222). Recorded here as a file naming
# the tree, and logged as `attach <run> <tree>` and `detach <run>`. The guest's side
# mounts it with the logging `mount`. A test makes a daemon die by creating
# daemon-dead.<run>, and an attach fail by creating attach_fails.
engine_attach_tree() {
    stub_log "attach $1 $2"
    [ ! -f "$STUB/attach_fails" ] || { echo "vm: stub: attach refused" >&2; return 1; }
    mkdir -p "$STUB/attached"
    printf '%s\n' "$2" > "$STUB/attached/$1"
}

engine_tree_attached() {
    [ -f "$STUB/attached/$1" ] || return 1
    [ ! -f "$STUB/daemon-dead.$1" ] || return 3
    return 0
}

engine_tree_slot() { printf '1\n'; }

engine_detach_tree() {
    stub_log "detach $1"
    rm -f "$STUB/attached/$1"
}

engine_attached_runs() {
    local record
    for record in "$STUB/attached"/*; do
        [ -f "$record" ] && printf '%s\n' "${record##*/}"
    done
    return 0
}

# Which kernel a boot runs is the real engine's business, and tests/boot-kernel.sh
# holds it to it. Here there is nothing to find out and nothing to keep.
engine_keep_kernel() { stub_log keep-kernel; }
engine_kernel_known() { return 0; }
engine_forget_kernel() { return 0; }

# Runs the script HERE, with the guest's fixed paths — the setup stamp,
# the hold marker, the repository mount, the cache — redirected into the stub
# directory, so the real logic executes against a tree a test can make.
stub_guest_paths() {
    printf '%s\n' "$1" |
        sed -e "s|/var/lib/fs-linux-test-harness|$STUB/guest-lib|g" \
            -e "s|FLTH_SHARE=\([^ ]*\)/share'|FLTH_SHARE=\1$FLTH_SHARE_HOST'|g" \
            -e "s|/run/fs-linux-test-harness-held|$STUB/guest-held|g" \
            -e "s|/run/fs-linux-test-harness-rearmed|$STUB/guest-rearmed|g" \
            -e "s|/run/fs-linux-test-harness-runs|$STUB/guest-runs|g" \
            -e "s|/proc/|$STUB/guest-proc/|g" \
            -e "s|/boot/|$STUB/guest-boot/|g" \
            -e "s|/lib/modules/|$STUB/guest-modules/|g" \
            -e "s|/etc/ssh/|$STUB/guest-etc-ssh/|g" \
            -e "s|/repo|$STUB/guest-repo|g" \
            -e "s|/cache\\([/ ']\\)|$STUB/guest-cache\\1|g" -e "s|/cache\$|$STUB/guest-cache|"
}

# A GUEST SCRIPT RUN HERE GETS A SYNC THAT ONLY LOGS (#202). A `sync` sent to the
# guest, on the host, flushes every disk on the machine. A test that copies this
# engine sets up its own PATH, so the stand-in comes from the engine, first on the
# PATH of every script it runs, children included.
#
# AND MOUNT TOOLS THAT ONLY LOG (#220). Every boot prepares the shared guest
# (lib/guest-run.sh), which binds directories over /tmp, /repo and the rest and
# enters namespaces. On the host those would be this machine's mounts, or fail. So
# each tool gets a stand-in that logs to guest-tools, unless the test put one of its
# own in the stub's bin (tests/lib.sh, make_stub_guest_tools), which then stands.
stub_host_bin() {
    local tool
    mkdir -p "$STUB/host-bin"
    [ -x "$STUB/host-bin/sync" ] ||
        printf '#!/bin/sh\necho sync >> "%s/calls"\n' "$STUB" > "$STUB/host-bin/sync"
    chmod +x "$STUB/host-bin/sync"
    for tool in mount umount mountpoint systemctl flock losetup tar unshare nsenter; do
        [ ! -e "$STUB/bin/$tool" ] || continue
        [ ! -x "$STUB/host-bin/$tool" ] || continue
        case "$tool" in
            mountpoint) printf '#!/bin/sh\necho "mountpoint $*" >> "%s/guest-tools"\nexit 1\n' "$STUB" ;;
            unshare) printf '#!/bin/sh\necho "unshare $*" >> "%s/guest-tools"\ncase "$1" in --mount=*) : > "${1#--mount=}" ;; esac\nshift 3\nexec "$@"\n' "$STUB" ;;
            nsenter) printf '#!/bin/sh\necho "nsenter $*" >> "%s/guest-tools"\nwhile [ "$1" != -- ]; do shift; done\nshift\n[ "$1" != readlink ] || { echo "mnt:[stub]"; exit 0; }\nexec "$@"\n' "$STUB" ;;
            *) printf '#!/bin/sh\necho "%s $*" >> "%s/guest-tools"\n' "$tool" "$STUB" ;;
        esac > "$STUB/host-bin/$tool"
        chmod +x "$STUB/host-bin/$tool"
    done
}

stub_guest_script() {
    stub_host_bin
    printf 'export PATH=%q:"$PATH"\n' "$STUB/host-bin"
    stub_guest_paths "$1"
}

engine_run() {
    stub_log run
    printf '%s\n' "$1" >> "$STUB/scripts"
    stub_guest_script "$1" | "$FLTH_TEST_GUEST_BASH" -s
}

engine_run_held() {
    stub_log run
    printf '%s\n' "$1" >> "$STUB/scripts"
    flth_run_holding_stdin "$(stub_guest_script "$1")" "$FLTH_TEST_GUEST_BASH" -s
}

engine_copy() {
    cp "$1" "$FLTH_SHARE_HOST/"
    printf '/share/%s\n' "$(basename "$1")"
}

# What a lost guest is asked about (lib/engine.sh). The real engine's answers
# are held by tests/lost-guest-engine.sh, which talks to a stand-in monitor.
engine_vm_status() {
    stub_log vm-status
    [ -f "$STUB/vm_status" ] && cat "$STUB/vm_status"
}

# What the guest would report to the watchdog.
#   report         the report, as vagrant/guest/watchdog-probe.sh writes it
#   report_cmd     a script run for each report instead
#   report_silent  present: the guest does not answer
engine_guest_report() {
    [ ! -f "$STUB/report_silent" ] || return 1
    if [ -f "$STUB/report_cmd" ]; then
        env STUB="$STUB" bash "$STUB/report_cmd"
        return
    fi
    cat "$STUB/report" 2>/dev/null
}

engine_guest_answers() {
    stub_log guest-answers
    if [ -f "$STUB/ends_on_probe" ]; then
        rm -f "$STUB/ends_on_probe"
        echo stopped > "$STUB/state"
    fi
    [ -f "$STUB/guest_answers" ]
}

engine_overlay_dir() { printf '%s\n' "$STUB"; }

engine_stop_host_daemons() { return 0; }

engine_alive() {
    [ -f "$STUB/ps_unreadable" ] && return 2
    [ "$(cat "$STUB/state")" = running ]
}
