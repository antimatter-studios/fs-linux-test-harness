# shellcheck shell=bash
#
# lib/engine-vagrant.sh — the engine interface (lib/engine.sh) on Vagrant
# and its QEMU provider.
#
# The Vagrantfile is the harness's own (vagrant/Vagrantfile) and reads
# only FLTH_* variables, which engine_prepare exports. Machine state goes
# to VAGRANT_DOTFILE_PATH under the consumer's machine directory, so the
# harness checkout is never written to and each consumer has its own
# disk. A boot writes that disk only when engine_up is given --persist;
# every other boot runs on a throwaway overlay (vagrant/Vagrantfile).
# A consumer that declares a cache also has a second disk beside it,
# which every boot writes (engine_vagrant_cache_disk).

ENGINE_VAGRANT_DIR="$FLTH_HARNESS/vagrant"

# Vagrant takes an exclusive lock on a machine for the length of ANY
# command, `status` included, and answers contention by failing at once
# with this sentence. Test suites call in here in parallel, so contention
# is ordinary; waiting it out is what the message asks for.
ENGINE_VAGRANT_LOCKED='Vagrant locks each machine'
ENGINE_VAGRANT_LOCK_TRIES=60
ENGINE_VAGRANT_LOCK_WAIT=2

engine_prepare() {
    export VAGRANT_CWD="$ENGINE_VAGRANT_DIR"
    # Nothing is shared at boot (#222): each run's tree is attached while the guest
    # runs, through QMP, to one of FLTH_VM_SLOTS free root ports (engine_attach_tree).
    export FLTH_VM_QMP
    FLTH_VM_QMP="$(engine_vagrant_qmp_socket)"
    export FLTH_VM_SLOTS="${FLTH_SHARED_SLOTS:-32}"
    export FLTH_VM_MEM_DIR="$FLTH_STATE_DIR/tmp"
    export VAGRANT_DOTFILE_PATH="$FLTH_MACHINE_DIR/vagrant"
    export FLTH_VM_NAME="$FLTH_MACHINE_NAME"
    export FLTH_VM_MEMORY="$CFG_vm_memory"
    export FLTH_VM_CPUS="$CFG_vm_cpus"
    export FLTH_VM_DISK="$CFG_vm_disk"
    export FLTH_VM_SSH_PORT="$CFG_vm_ssh_port"
    export FLTH_VM_DEADLINE_MINUTES="$CFG_vm_deadline_minutes"
    export FLTH_VM_GUEST="$CFG_vm_guest"
    # Every Vagrant command evaluates the Vagrantfile, which requires it;
    # only `up` acts on it, and engine_up --persist overrides it there.
    export FLTH_VM_DISPOSABLE=1
    # Set on every call, empty when no cache is declared, so the
    # Vagrantfile never sees one a previous consumer exported.
    export FLTH_VM_CACHE_DISK=""
    [ -n "$CFG_cache_size" ] && FLTH_VM_CACHE_DISK="$(engine_vagrant_cache_path)"
    export FLTH_VM_CONSOLE_LOG
    FLTH_VM_CONSOLE_LOG="$(engine_console_log)"
    mkdir -p "$FLTH_MACHINE_DIR" "$FLTH_SHARE_HOST" "$(dirname "$(engine_ssh_control)")" \
        "$(dirname "$FLTH_VM_QMP")" "$FLTH_VM_MEM_DIR" "$(engine_vagrant_attached_dir)"

    # UEFI firmware for an arm64 guest on a Linux host. The QEMU provider
    # copies `edk2-aarch64-code.fd` and `edk2-arm-vars.fd` out of its
    # qemu_dir; Homebrew's QEMU ships those names, Linux distributions
    # do not (Debian: /usr/share/AAVMF/AAVMF_{CODE,VARS}.fd). So the
    # names are provided as links, and where they point is host
    # configuration. An x86_64 guest boots SeaBIOS and needs none.
    if [ "$(uname -s)" = Linux ] && engine_vagrant_host_is_arm; then
        local code="${FLTH_FIRMWARE_CODE:-/usr/share/AAVMF/AAVMF_CODE.fd}"
        local vars="${FLTH_FIRMWARE_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}"
        local dir="$FLTH_CACHE_DIR/firmware"
        mkdir -p "$dir"
        ln -sfn "$code" "$dir/edk2-aarch64-code.fd"
        ln -sfn "$vars" "$dir/edk2-arm-vars.fd"
        export FLTH_QEMU_DIR="$dir"
    fi
}

# The guest's serial console, which the Vagrantfile has QEMU log here on
# every boot (#61).
engine_console_log() { printf '%s/console.log\n' "$FLTH_MACHINE_DIR"; }

engine_vagrant_host_is_arm() {
    case "$(uname -m)" in arm64 | aarch64) return 0 ;; esac
    return 1
}

engine_vagrant() {
    (
        cd "$ENGINE_VAGRANT_DIR" || exit 1
        case "${1:-}" in
            up | halt | destroy)
                # shellcheck disable=SC2153
                ruby "$FLTH_HARNESS/scripts/qemu-artifacts.rb" "$FLTH_STATE_DIR/tmp" vagrant "$@"
                ;;
            *) vagrant "$@" ;;
        esac
    )
}

engine_identity() {
    printf '%s\n' "$FLTH_MACHINE_DIR/vagrant"
}

engine_boot_identity() {
    local identity processes
    identity="$(engine_identity)"
    [ -n "$identity" ] || return 1
    processes="$(LC_ALL=C TZ=UTC ps -eo pid=,lstart=,args= 2>/dev/null)" || return 2
    [ -n "$processes" ] || return 2
    printf '%s\n' "$processes" | awk -v want="$identity/" '
        { count = split($7, parts, "/") }
        !found && parts[count] ~ /^qemu-system-/ && index($0, want) > 0 {
            print $1, $2, $3, $4, $5, $6
            found = 1
        }
        END { exit !found }'
}

# Run vagrant, waiting out another process's lock on the machine. Output
# goes to stdout; Vagrant's own stderr is shown only when the command
# finally fails.
engine_vagrant_retrying() {
    local tries=0 err rc out
    err="$(mktemp)"
    while :; do
        rc=0
        out="$(engine_vagrant "$@" 2>"$err")" || rc=$?
        if [ "$rc" -ne 0 ] && grep -qF "$ENGINE_VAGRANT_LOCKED" "$err" &&
            [ "$tries" -lt "$ENGINE_VAGRANT_LOCK_TRIES" ]; then
            tries=$((tries + 1))
            sleep "$ENGINE_VAGRANT_LOCK_WAIT"
            continue
        fi
        break
    done
    [ "$rc" -eq 0 ] || sed 's/^/[vagrant] /' "$err" >&2
    rm -f "$err"
    printf '%s\n' "$out"
    return "$rc"
}

# RUNNING IS ANSWERED BY THE PROCESS TABLE; ANYTHING ELSE BY VAGRANT.
#
# `vagrant status` costs seconds, and `run` asks on every call. A QEMU
# process naming this machine's disk is conclusive that it is up. Its
# absence is not conclusive of anything finer — stopped, never created,
# or a process table that could not be read — so that question still
# goes to Vagrant, and an answer Vagrant cannot give is `unknown`.
engine_state() {
    local out state rc=0
    engine_alive "$(engine_identity)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo running
        return 0
    fi
    out="$(engine_vagrant_retrying status --machine-readable || true)"
    state="$(printf '%s\n' "$out" | sed -n 's/^[^,]*,[^,]*,state,//p' | head -1)"
    case "$state" in
        # Vagrant saying `running` while the process table, read
        # successfully, shows no such process is a disagreement, not an
        # answer.
        running) [ "$rc" -eq 1 ] && echo unknown || echo running ;;
        not_created) echo absent ;;
        # Both providers say `stopped`: the macOS fork's driver, in every
        # published version (0.5.0 to 0.6.0), has only running, stopped
        # and not_created, the stock provider's states. `poweroff` was
        # carried over from older copies of this code and never observed;
        # it stays mapped because the cost of dropping it, if some build
        # does say it, is a halted VM read as `unknown`, which nothing stops.
        stopped | poweroff | shutoff) echo stopped ;;
        *) echo unknown ;;
    esac
}

# THE VIRTIOFS SOCKETS ARE THE HARNESS'S, NOT THE CALLER'S TMPDIR's.
# The macOS provider creates each shared folder's virtiofsd socket as
# $TMPDIR/vqemu-<machine id>-virtiofs<n>.sock, and a Unix socket path is
# limited to 104 bytes with its terminator. Inherited, TMPDIR is whatever
# the caller had — a consumer's scratch directory inside its checkout —
# and a path over the limit stops the VM booting with nothing naming the
# cause. So `vagrant up` gets a directory under FLTH_STATE_DIR, like the ssh
# control socket, and a boot is refused, naming the path and its length,
# if even that is too long.
#
# 36 is the longest socket name the provider makes here:
# "vqemu-" + "vq_" and eleven id characters + "-virtiofs<n>.sock", with a
# leading "/" and n a single digit (two folders are shared).
ENGINE_VAGRANT_SOCKET_MAX=103
ENGINE_VAGRANT_SOCKET_NAME=36

# The length is only refused on macOS, the one host whose shares are
# virtiofs sockets; Linux shares over 9p and creates none.
engine_vagrant_tmpdir() {
    # shellcheck disable=SC2153  # FLTH_STATE_DIR, set in lib/common.sh
    local dir="$FLTH_STATE_DIR/tmp" longest
    longest=$(( ${#dir} + ENGINE_VAGRANT_SOCKET_NAME ))
    if [ "$(uname -s)" = Darwin ] && [ "$longest" -gt "$ENGINE_VAGRANT_SOCKET_MAX" ]; then
        echo "vm: the virtiofs sockets would be created under $dir, a path of" >&2
        echo "    $longest bytes; a Unix socket path must be at most $ENGINE_VAGRANT_SOCKET_MAX. Put FLTH_STATE_DIR" >&2
        echo "    (or XDG_STATE_HOME) on a shorter path, for every repository alike." >&2
        return 1
    fi
    mkdir -p "$dir" && chmod u=rwx,go= "$dir" || return 1
    printf '%s\n' "$dir"
}

# THE DECLARED CACHE IS A DISK OF ITS OWN (#39). Every boot that runs
# anything is disposable, so a build directory on the guest's own disk is
# rebuilt every time. A consumer that wants one kept says so ([cache]
# size), and gets this: a raw image in the machine directory, attached
# beside the machine's disk but never through the provider's drive list,
# whose snapshot=on would discard it with the run (vagrant/Vagrantfile).
# The guest gives it a filesystem on its first boot and mounts it at
# FLTH_CACHE_GUEST on every boot (vagrant/guest/mount-cache.sh).
#
# RAW AND SPARSE, made by `dd` seeking past its end, so it needs no image
# tool on the host and takes no space until the guest writes. A size that
# no longer matches the declaration gets a new, empty disk rather than a
# resize: growing it would mean growing the filesystem in it, which is
# filesystem knowledge, and a cache is something a run can rebuild.
#
# Made here and not in engine_prepare, which runs on every command: this
# runs only when the machine is about to boot, so the disk is never
# replaced under a running guest.
engine_vagrant_cache_path() { printf '%s/cache.img\n' "$FLTH_MACHINE_DIR"; }

engine_vagrant_cache_disk() {
    local disk want have
    [ -n "$CFG_cache_size" ] || return 0
    disk="$(engine_vagrant_cache_path)"
    want=$(( ${CFG_cache_size%G} * 1024 * 1024 * 1024 ))
    if [ -f "$disk" ]; then
        have="$(stat -c %s "$disk" 2>/dev/null || stat -f %z "$disk")"
        [ "$have" = "$want" ] && return 0
        echo "[vm] the cache disk is $have bytes and [cache] size says $CFG_cache_size:" \
            "replacing it with an empty one (a cache is rebuilt, never resized)" >&2
        rm -f "$disk"
    fi
    mkdir -p "$(dirname "$disk")"
    dd if=/dev/null of="$disk" bs=1 count=0 seek="$want" 2>/dev/null || {
        rm -f "$disk"
        echo "vm: could not create the cache disk $disk" >&2
        return 1
    }
}

# The disposable overlay is created under the TMPDIR QEMU inherits, which
# is this directory too: on disk under FLTH_STATE_DIR, never a RAM-backed /tmp
# that a long run's writes could fill.
# THE SSH FORWARD PORT IS CHOSEN AT EVERY BOOT (#49). QEMU cannot forward
# a port another socket holds, and the configured one ([vm] ssh_port,
# default 50122) sits inside Linux's ephemeral range, so any outgoing
# connection on the host may be holding it. A boot takes the configured
# port when it can bind it and any free port the kernel hands out when it
# cannot, so a retry routes around a busy port instead of failing on it
# again. Perl, because bash cannot bind a socket and perl is in every
# macOS and Debian base install.
engine_vagrant_ssh_port() {
    perl -MIO::Socket::INET -e '
        for my $p ($ARGV[0], 0) {
            my $s = IO::Socket::INET->new(LocalAddr => "0.0.0.0", LocalPort => $p,
                                          Proto => "tcp", Listen => 1) or next;
            print $s->sockport, "\n";
            exit 0;
        }
        exit 1;' "$1"
}

# THE macOS GUEST'S KERNEL IS NOT ON ITS DISK (#80). The box starts QEMU with
# -kernel and -initrd naming files beside the box, with no firmware and no
# bootloader, so a kernel a setup script installs in the guest is never run,
# and neither is anything that needs it. Measured on an Apple Silicon host with
# a setup that installs a 6.12 kernel: /boot held vmlinuz-6.12.95+deb12-arm64,
# and `uname -r` said 6.1.0-42-cloud-arm64. So when a provisioning boot ends its
# newest kernel is copied out beside the machine, and every later boot is told
# to run it (vagrant/Vagrantfile). A Linux guest boots through its own GRUB,
# which chooses for itself, and none of this applies there.
#
# The release file is written last and is what records the answer, which may
# be "none": a setup that installs no kernel stays on the box's.
engine_vagrant_kernel_dir() { printf '%s/boot\n' "$FLTH_MACHINE_DIR"; }
engine_vagrant_keeps_kernel() { [ "$(uname -s)" = Darwin ]; }

engine_keep_kernel() {
    engine_vagrant_keeps_kernel || return 0
    local dir release
    dir="$(engine_vagrant_kernel_dir)"
    release="$(engine_run "$(cat "$ENGINE_VAGRANT_DIR/guest/newest-kernel.sh")")" || return 1
    mkdir -p "$dir" || return 1
    rm -f "$dir/release"
    if [ -n "$release" ]; then
        if ! engine_run "cat '/boot/vmlinuz-$release'" > "$dir/vmlinuz.new" ||
            ! engine_run "cat '/boot/initrd.img-$release'" > "$dir/initrd.img.new"; then
            rm -f "$dir/vmlinuz.new" "$dir/initrd.img.new"
            return 1
        fi
        mv -f "$dir/vmlinuz.new" "$dir/vmlinuz" && mv -f "$dir/initrd.img.new" "$dir/initrd.img" || return 1
        echo "[vm] the next boot runs $release, the newest kernel on the disk" >&2
    else
        rm -f "$dir/vmlinuz" "$dir/initrd.img"
    fi
    printf '%s' "$release" > "$dir/release"
}

# Whether a provisioning boot has answered for this disk. A disk provisioned by
# a harness that kept no kernel has not, and takes one provisioning boot to.
engine_kernel_known() {
    engine_vagrant_keeps_kernel || return 0
    [ -f "$(engine_vagrant_kernel_dir)/release" ]
}

# A kept kernel belongs to the disk that holds its modules.
engine_forget_kernel() {
    local dir
    dir="$(engine_vagrant_kernel_dir)"
    rm -f "$dir/release" "$dir/vmlinuz" "$dir/initrd.img" "$dir/vmlinuz.new" "$dir/initrd.img.new"
    rmdir "$dir" 2>/dev/null || true
}

# WHAT A macOS BOOT LEAVES RUNNING MUST NOT HOLD THE CALLER'S OUTPUT (#80).
# The macOS forwarder plugin starts its `notify-forwarder watch` processes
# with no redirection, so they keep Vagrant's stdout and stderr, and they
# outlive the boot. Handed the caller's stderr, they hold it: a test process
# capturing `vm.sh up` waits for end-of-file on that pipe, and one consumer's
# kernel tests sat for 47 minutes on their first call with the guest up and
# idle. So Vagrant writes to a file, which is shown on stderr as it grows, and
# what it leaves running holds only the file. The stock provider on Linux starts
# nothing that keeps them, but the file is also how a failed boot is read
# afterwards (engine_box_failure), so every host takes this path.
#
# Vagrant is waited for here, and scripts/qemu-artifacts.rb passes it an
# interrupt: it runs in a process group of its own (#130). Stopping when this
# process is gone keeps the follower from outliving a killed `up`, which would
# be the same fault again.
engine_vagrant_up() {
    local log follower rc=0
    log="$(engine_vagrant_up_log)"
    # A file of its own: an earlier boot's processes still hold the last one.
    rm -f "$log" "$log.done"
    : > "$log"
    engine_vagrant_follow "$log" &
    follower=$!
    engine_vagrant up --provider qemu > "$log" 2>&1 || rc=$?
    : > "$log.done"
    wait "$follower" || true
    rm -f "$log.done"
    return "$rc"
}

engine_vagrant_follow() {
    local log="$1" shown=0 total
    while [ ! -e "$log.done" ] && kill -0 "$$" 2>/dev/null; do
        total="$(wc -l < "$log")"
        if [ "$total" -gt "$shown" ]; then
            sed -n "$((shown + 1)),${total}p" "$log" >&2
            shown="$total"
        fi
        sleep 1
    done
    sed -n "$((shown + 1)),\$p" "$log" >&2
}

engine_vagrant_up_log() { printf '%s/vagrant-up.log\n' "$FLTH_MACHINE_DIR"; }

# WHAT VAGRANT SAID WHEN IT COULD NOT FETCH THE BOX (#145). Vagrant's up ends with
# one of three messages and exit status 1, the same as any other failure, so the
# words are all there is. They are Vagrant 2.4.9's, from its locale file:
# box_add_short_not_found, for the catalog, and downloader_error and
# box_metadata_download_error, for the box's own URL. Its downloader passes on
# curl's message, which holds the HTTP status when there was one.
#
# A 4xx is an answer, not an outage, and nothing comes of waiting for it, except
# 408, 425 and 429, which ask for a later try. Anything else is an outage: a 5xx, or
# no answer at all from a host that cannot be reached. A wrong guess here costs
# minutes, within the bound boot_engine holds it to.
engine_box_failure() {
    local log what error status
    log="$(engine_vagrant_up_log)"
    [ -f "$log" ] || return 1
    if grep -q 'could not be accessed in the remote catalog' "$log"; then
        what="the box catalog $(sed -n 's/^URL: //p' "$log" | head -n 1 | tr -d '[]"')"
        error="$(sed -n 's/^Error: //p' "$log" | head -n 1)"
    elif grep -q -e 'An error occurred while downloading the remote file' \
        -e 'error while downloading the metadata for this box' "$log"; then
        what='the box download'
        # Its message, if any, is what follows the blank line.
        error="$(awk '
            /An error occurred while downloading|error while downloading the metadata/ { found = 1 }
            found && !NF { message = 1; next }
            message && NF { last = $0 }
            END { print last }' "$log")"
    else
        return 1
    fi
    status="$(printf '%s\n' "$error" | sed -n 's/.*returned error: \([0-9][0-9][0-9]\).*/\1/p')"
    case "$status" in
        408 | 425 | 429) ;;
        4??) return 1 ;;
    esac
    if [ -n "$status" ]; then
        echo "$what answered HTTP $status"
    else
        echo "$what failed: ${error:-Vagrant gave no reason}"
    fi
}

# shellcheck disable=SC2120
engine_up() {
    local tmp disposable=1 port dir kernel="" initrd=""
    [ "${1:-}" = --persist ] && disposable=0
    # What the last attempt said is not what this one says, if this one fails
    # before it gets to Vagrant.
    rm -f "$(engine_vagrant_up_log)"
    dir="$(engine_vagrant_kernel_dir)"
    if [ -s "$dir/release" ]; then
        kernel="$dir/vmlinuz"
        initrd="$dir/initrd.img"
    fi
    tmp="$(engine_vagrant_tmpdir)" || return 1
    engine_vagrant_cache_disk || return 1
    port="$(engine_vagrant_ssh_port "$CFG_vm_ssh_port")" || {
        echo "vm: no free host port for the SSH forward" >&2
        return 1
    }
    [ "$port" = "$CFG_vm_ssh_port" ] ||
        echo "[vm] SSH port $CFG_vm_ssh_port is held by another socket: forwarding $port" >&2
    # Exported, not passed to `up` alone: the ssh settings are read back
    # from Vagrant just below, and must name the port this boot forwards.
    export FLTH_VM_SSH_PORT="$port"
    engine_ssh_close
    rm -f "$FLTH_MACHINE_DIR/ssh-config"
    # THE SHARED GUEST'S DISK NEVER KEEPS VAGRANT'S KEY. Vagrant replaces the box's
    # key with one of its own on a machine's first boot and connects with it from then
    # on. The shared machine has no boot whose writes are kept, so the key went with
    # the overlay and every later boot failed with `Authentication failure` until its
    # timeout (measured on an Apple Silicon host, #153). Forgetting the machine's copy
    # makes each boot a first boot to Vagrant.
    rm -f "$VAGRANT_DOTFILE_PATH"/machines/*/*/private_key
    # A new guest has no device attached, whatever an earlier one left on record.
    engine_vagrant_forget_attached
    # QEMU starts the log afresh, but a boot that fails before QEMU starts
    # must not leave the last boot's console to be shown as its own.
    rm -f "$(engine_console_log)"
    FLTH_VM_BOOT_KERNEL="$kernel" FLTH_VM_BOOT_INITRD="$initrd" \
        FLTH_VM_DISPOSABLE="$disposable" TMPDIR="$tmp" engine_vagrant_up || return
    engine_ssh_config >/dev/null
}

# A HALT DOES NOT STOP THE FORWARDER'S WATCHERS, SO THIS DOES (#130). The macOS
# forwarder plugin records each process it starts in the machine's data directory.
# Before 0.7.7 it stops them from a hook before Vagrant's GracefulHalt, which the
# macOS provider's halt does not use: measured on an Apple Silicon host, every boot
# left its watchers running after `vagrant halt`. They were out of reach of a signal
# once a boot had its own process group, so nothing else stops them. From 0.7.7 its
# hook does run, and a watcher ends about 15 seconds after its guest stops answering;
# this still runs, because a host may hold either version.
#
# A line of the record is a pid, followed from 0.7.7 by what the plugin compares
# before it signals. This removes the record, so a line it could not read would be a
# watcher nothing can stop any more. A recorded pid can belong to something else by
# now, so only a process that says it is a forwarder is signalled; the process
# recorded from 0.7.7 is a supervisor that names the forwarder in its arguments, and
# stops it on TERM. The stock provider on Linux records none.
engine_vagrant_stop_forwarders() {
    local record pid
    for record in "$VAGRANT_DOTFILE_PATH"/machines/*/*/notify_watcher_host_pid; do
        [ -f "$record" ] || continue
        while read -r pid _; do
            case "$pid" in '' | *[!0-9]*) continue ;; esac
            case "$(ps -o args= -p "$pid" 2>/dev/null)" in
                *notify-forwarder*) kill -TERM "$pid" 2>/dev/null || true ;;
            esac
        done < "$record"
        rm -f "$record"
    done
}

engine_stop_host_daemons() {
    engine_vagrant_stop_forwarders
    engine_alive "$(engine_identity)" || engine_vagrant_forget_attached
}

engine_down() {
    if [ "${1:-}" = "--force" ]; then
        engine_vagrant halt -f >&2
    else
        engine_vagrant halt >&2
    fi
    engine_vagrant_stop_forwarders
    engine_ssh_close
    # Only once QEMU has gone: a virtiofsd must outlive every guest that can use it.
    engine_alive "$(engine_identity)" || engine_vagrant_forget_attached
}

# The cache goes with the machine: destroy is the reset, and a cache is
# something a run can rebuild.
engine_destroy() {
    engine_vagrant_stop_forwarders
    engine_ssh_close
    rm -f "$FLTH_MACHINE_DIR/ssh-config"
    engine_vagrant destroy -f >&2 || return
    engine_vagrant_forget_attached
    rm -f "$(engine_vagrant_cache_path)"
    engine_forget_kernel
}

# Vagrant's ssh settings for the machine, cached beside it. Written after
# every boot (the forwarded port can be auto-corrected) and regenerated
# on demand.
engine_ssh_config() {
    local cache="$FLTH_MACHINE_DIR/ssh-config" out
    if [ ! -s "$cache" ] || [ "${1:-}" = "--refresh" ]; then
        out="$(engine_vagrant_retrying ssh-config)" || return 1
        printf '%s\n' "$out" > "$cache"
    fi
    printf '%s\n' "$cache"
}

# ONE CONNECTION, REUSED BY EVERY CALL. A fresh ssh handshake to the
# guest costs about 0.7s; over a multiplexed connection the same command
# costs about 0.03s, and a test process that asks the guest a few hundred
# questions is the difference between a minute of handshakes and two
# seconds of them. So the first call opens a master that persists, and
# every later call rides it.
#
# The socket lives under FLTH_STATE_DIR rather than in the machine directory:
# a Unix socket path is limited to about 104 bytes, and a machine
# directory under a deep checkout can exceed that on its own. Hashed, so
# the length is fixed whatever the project is called.
ENGINE_SSH_PERSIST="${FLTH_SSH_PERSIST:-3600}"

# A GUEST THAT GOES AWAY MUST FAIL THE CALL, NOT HOLD IT. A VM that is
# halted — by its own poweroff deadline, by a `destroy`, by the machine
# running out of memory — leaves every command it was running with a
# connection nothing will ever answer on. Without these, ssh waits for
# ever: a test suite that ran for forty-eight minutes on two calls whose
# VM had powered off half an hour earlier is how this was found. With
# them the call fails in about two minutes and says the VM is gone.
ENGINE_SSH_ALIVE=(-o ServerAliveInterval=15 -o ServerAliveCountMax=8)

engine_ssh_control() {
    # shellcheck disable=SC2153  # FLTH_STATE_DIR, set in lib/common.sh
    printf '%s/ssh/%s\n' "$FLTH_STATE_DIR" "$(flth_hash8 "$FLTH_MACHINE_DIR")"
}

# Open the shared connection, if it is not open already.
#
# THE MASTER IS OPENED ON PURPOSE (-M -N -f), not as a side effect of the
# first command (ControlMaster=auto). A master that grew out of a command
# inherits that command's stdout and stderr and keeps them open for as
# long as it persists — so a caller capturing the output of a one-second
# call waits an hour for end-of-file. Opened this way it holds nothing of
# the caller's: stdin is /dev/null and both streams go nowhere.
#
# A socket file that exists is trusted rather than probed (`ssh -O check`
# is another process, on a path that has to cost milliseconds). When the
# VM stops, whatever stops it calls engine_ssh_close; a master whose VM
# died anyway leaves a socket ssh cannot connect to, and ssh then makes
# an ordinary connection — slower, never wrong.
engine_ssh_open() {
    local cfg="$1" control="$2"
    [ -S "$control" ] && return 0
    mkdir -p "$(dirname "$control")"
    ssh -F "$cfg" -o ControlMaster=yes -o "ControlPath=$control" \
        -o "ControlPersist=$ENGINE_SSH_PERSIST" "${ENGINE_SSH_ALIVE[@]}" -N -f default \
        </dev/null >/dev/null 2>&1 || true
}

# Close the master, if one is up. Called before a boot and after a stop:
# a socket pointing at a VM that no longer exists is one ssh has to
# discover the slow way.
engine_ssh_close() {
    local control
    control="$(engine_ssh_control)"
    [ -S "$control" ] || return 0
    ssh -o "ControlPath=$control" -O exit default >/dev/null 2>&1 || true
    rm -f "$control"
}

# Plain ssh with Vagrant's settings, not `vagrant ssh`: a second saved per
# call, and no Vagrant machine lock to contend for.
#
# The script travels on stdin — `ssh host cmd` and `vagrant ssh -c` both
# mangle quoting — and is passed in rather than piped from the caller so
# it can be sent again.
#
# SENT AGAIN ONLY WHEN THE CONNECTION WAS NOT THE SAME ONE. ssh exits 255
# for its own failures, but a script may exit 255 too, and re-running a
# script that already ran is not a retry. So a 255 refreshes the settings
# and retries only when they changed (a VM rebooted onto another port).
engine_run() { engine_run_through engine_ssh "$1"; }

engine_run_held() { engine_run_through engine_ssh_held "$1"; }

engine_run_through() {
    local send="$1" script="$2" cfg before rc=0
    cfg="$(engine_ssh_config)" || return 1
    "$send" "$cfg" "$script" || rc=$?
    if [ "$rc" -eq 255 ]; then
        before="$(cat "$cfg")"
        engine_ssh_config --refresh >/dev/null || return "$rc"
        if [ "$(cat "$cfg")" != "$before" ]; then
            rc=0
            engine_ssh_close
            "$send" "$cfg" "$script" || rc=$?
        fi
    fi
    return "$rc"
}

# FLTH_GUEST=1 IS PART OF THE CONTRACT. A program the harness runs in the
# guest can be the very program that, on a host, would ask the harness to
# run it in the guest — a test suite whose helpers shell out to `vm.sh`,
# say. Inside, there is no VM to ask and none needed: it IS the test
# environment. One exported variable is how it can tell, and it is set
# for every command the harness runs there.
engine_ssh() {
    local cfg="$1" script="$2" control
    control="$(engine_ssh_control)"
    engine_ssh_open "$cfg" "$control"
    printf 'export FLTH_GUEST=1\n%s\n' "$script" |
        ssh -F "$cfg" -o "ControlPath=$control" "${ENGINE_SSH_ALIVE[@]}" default -T 'sudo bash -s'
}

# The channel's stdin is the guest's one sign that the host side has gone. With no
# terminal sshd sends the guest no signal when a channel closes: it closes the
# pipes. A client that ends, and a caller that ends leaving the client alive, both
# end in end-of-file there.
engine_ssh_held() {
    local cfg="$1" script="$2" control
    control="$(engine_ssh_control)"
    engine_ssh_open "$cfg" "$control"
    flth_run_holding_stdin "$(printf 'export FLTH_GUEST=1\n%s' "$script")" \
        ssh -F "$cfg" -o "ControlPath=$control" "${ENGINE_SSH_ALIVE[@]}" default -T 'sudo bash -s'
}

# The share is a live mount in both directions (virtiofs on macOS, 9p on
# Linux), so copying in is a host-side copy.
engine_copy() {
    cp "$1" "$FLTH_SHARE_HOST/"
    printf '%s/%s\n' "$FLTH_SHARE_GUEST" "$(basename "$1")"
}

# A running QEMU names its disk image on its command line, and the image
# lives under the machine's identity directory — so one `ps` answers
# "is this machine up" with no cooperation from anything.
#
# Matched on the PROCESS NAME and on the identity followed by `/`. The
# first keeps a shell whose own command line merely mentions the path
# from counting; the second keeps /x/myfs from matching /x/myfs-old.
#
# No `grep -q` on a pipeline here: under `pipefail`, grep -q exiting on
# the first match SIGPIPEs `ps`, and the pipeline then fails BECAUSE it
# matched — which read as "not running" precisely when it was.
engine_alive() {
    engine_vagrant_qemu_args "$1" >/dev/null
}

# The command line of this machine's QEMU, with engine_alive's statuses. awk reads
# to the end: stopping at the match would fail the printf under pipefail.
engine_vagrant_qemu_args() {
    local identity="$1" procs candidates=""
    [ -n "$identity" ] || return 1
    # 2 when the process table cannot be read: "could not look" is not
    # "nothing is running".
    if command -v pgrep >/dev/null 2>&1; then
        candidates="$(pgrep -x 'qemu-system-.*' 2>/dev/null)" || candidates=""
    fi
    if [ -n "$candidates" ]; then
        # A QEMU that exits between pgrep finding it and ps reading it (#205): ps
        # finds none of the pids and fails, which is a VM that has stopped, not a
        # table that could not be read. One that is still there reads again whole.
        if ! procs="$(ps -p "${candidates//$'\n'/,}" -o args= 2>/dev/null)" || [ -z "$procs" ]; then
            local pid gone=1
            # Another user's process answers EPERM, and is there all the same.
            for pid in $candidates; do
                if perl -e 'exit((kill(0, $ARGV[0]) || $!{EPERM}) ? 0 : 1)' "$pid"; then gone=0; fi
            done
            [ "$gone" = 0 ] || return 1
            procs="$(ps -eo args= 2>/dev/null)" || return 2
        fi
    else
        procs="$(ps -eo args= 2>/dev/null)" || return 2
    fi
    [ -n "$procs" ] || return 2
    printf '%s\n' "$procs" | awk -v want="$identity/" '
        { n = split($1, parts, "/") }
        !found && parts[n] ~ /^qemu-system-/ && index($0, want) > 0 { print; found = 1 }
        END { exit !found }'
}

# WHAT A LOST GUEST IS ASKED (#105). Both run under a call a consumer is waiting
# for, against a machine that may be in any state, so each has a limit of its own.
ENGINE_VAGRANT_MONITOR_LIMIT=5
ENGINE_VAGRANT_ANSWER_LIMIT=10

# QEMU's monitor: a readline monitor on a socket the provider names on QEMU's
# command line. Perl, as for the port above: macOS has no timeout(1), and netcat
# is not on every Linux host. The monitor redraws each typed character, so a
# prompt only ends an answer at the very end of what has arrived.
engine_vagrant_monitor() {
    local args socket
    args="$(engine_vagrant_qemu_args "$(engine_identity)")" || return 1
    socket="$(printf '%s\n' "$args" | sed -n 's/.*id=mon0,path=\([^, ]*\).*/\1/p')"
    [ -n "$socket" ] || return 1
    perl -MIO::Select -MIO::Socket::UNIX -e '
        my ($limit, $path, @commands) = @ARGV;
        $SIG{ALRM} = sub { exit 1 };
        alarm $limit;
        my $monitor = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path) or exit 1;
        $monitor->autoflush(1);
        my $ready = IO::Select->new($monitor);
        sub answer {
            my $text = "";
            until ($text =~ /\(qemu\) $/) {
                $ready->can_read(1) or next;
                sysread($monitor, my $chunk, 65536) or exit 1;
                $text .= $chunk;
            }
            return $text;
        }
        answer();
        foreach my $command (@commands) {
            print {$monitor} "$command\n";
            print answer();
        }' "$ENGINE_VAGRANT_MONITOR_LIMIT" "$socket" "$@"
}

# The overlay is the top of the machine's disk's chain, so the first `disk size`
# under disk0 is its size. Unlinked as it is, nothing else on the host can say.
engine_vm_status() {
    local answer
    answer="$(engine_vagrant_monitor 'info status' 'info block -v')" || return 1
    answer="$(printf '%s\n' "$answer" | tr -d '\r')"
    printf '%s\n' "$answer" | grep -q '^VM status: ' || return 1
    printf '%s\n' "$answer" | awk '/^VM status: / { print; exit }'
    printf '%s\n' "$answer" | awk '/^ *I\/O status: / && $3 != "ok" { print "I/O status: " $3; exit }'
    printf '%s\n' "$answer" | awk '
        /^disk0 / { disk = 1 }
        disk && /^disk size: / { sub(/^disk size: /, ""); print "overlay: " $0; exit }'
}

# A connection of its own, because the shared one is what was lost. alarm outlasts
# the exec, so ssh is killed at the limit wherever it has got to.
engine_guest_answers() {
    local cfg
    cfg="$(engine_ssh_config)" || return 1
    perl -e 'alarm shift; exec @ARGV or exit 127' "$ENGINE_VAGRANT_ANSWER_LIMIT" \
        ssh -F "$cfg" -o ControlPath=none -o ConnectTimeout="$ENGINE_VAGRANT_ANSWER_LIMIT" \
        -T default true </dev/null >/dev/null 2>&1
}

# The watchdog's question (#190). A connection of its own, as above, since the shared
# one can be what has gone wrong, and a limit, since a call into a stuck guest can sit
# for ever.
ENGINE_VAGRANT_REPORT_LIMIT=30
engine_guest_report() {
    local cfg
    cfg="$(engine_ssh_config)" || return 1
    perl -e 'alarm shift; exec @ARGV or exit 127' "$ENGINE_VAGRANT_REPORT_LIMIT" \
        ssh -F "$cfg" -o ControlPath=none -o ConnectTimeout="$ENGINE_VAGRANT_ANSWER_LIMIT" \
        -T default "sudo FLTH_GUEST_RUNS=$FLTH_GUEST_RUNS bash -s" \
        < "$FLTH_HARNESS/vagrant/guest/watchdog-probe.sh" 2>/dev/null
}

# Where engine_up points QEMU's TMPDIR.
engine_overlay_dir() {
    # shellcheck disable=SC2153  # FLTH_STATE_DIR, set in lib/common.sh
    printf '%s/tmp\n' "$FLTH_STATE_DIR"
}

# A RUN'S TREE, ATTACHED WHILE THE GUEST RUNS (#222). Each run has a virtiofsd of
# its own serving its tree, a vhost-user-fs device fs-<run> on a free root port
# flth_rp<N>, its chardev c-<run>, and the run id as the tag the guest mounts. The
# record of each attachment is a file in the machine directory, holding the slot,
# the daemon's pid and its start, the socket and the tree.
#
# THE ONE RULE (measured on two guests, see the pull request): a virtiofsd must
# never end while the guest can still use its mount. A request the guest sends after
# the daemon has gone never completes, and removing that device then wedges PCI
# hot-plug and every new virtiofs mount in the whole guest until it reboots. So the
# daemon is started in a session of its own, where no signal to a suite reaches it,
# and it is only ever stopped after its device has gone: it ends by itself when QEMU
# lets go of its socket, and is signalled only if it has not.
engine_vagrant_qmp_socket() { printf '%s/qmp/%s.sock\n' "$FLTH_STATE_DIR" "$(flth_hash8 "$FLTH_MACHINE_DIR")"; }
engine_vagrant_attached_dir() { printf '%s/attached\n' "$FLTH_MACHINE_DIR"; }
engine_vagrant_vfs_socket() { printf '%s/vfs/%s.sock\n' "$FLTH_STATE_DIR" "$(flth_hash8 "$FLTH_MACHINE_DIR/$1")"; }

engine_vagrant_qmp() { perl "$FLTH_HARNESS/scripts/lib/qmp.pl" "$FLTH_VM_QMP" "$@"; }

# The distribution's virtiofsd on Linux, the tap's on macOS (scripts/host-tools.sh).
engine_vagrant_virtiofsd() {
    local candidate
    for candidate in "${FLTH_VIRTIOFSD:-}" "$(command -v virtiofsd 2>/dev/null || true)" \
        /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

# The flags the macOS provider gave its own folders' virtiofsd, which this replaces:
# no sandbox (it runs as the host user), no file handles, extended attributes, and on
# macOS one thread, because the port switches credentials process-wide, and the box's
# vagrant user (1001) seen as the host user, where the build can translate ids.
engine_vagrant_virtiofsd_args() {
    local bin="$1"
    printf '%s\n' --sandbox=none --inode-file-handles=never --xattr
    if [ "$(uname -s)" = Darwin ]; then
        printf '%s\n' --thread-pool-size=1
        if "$bin" --help 2>&1 | grep -q -- --translate-uid; then
            printf '%s\n' --translate-uid "map:1001:$(id -u):1" --translate-gid "map:1001:$(id -g):1"
        fi
    fi
}

# Process start time, to tell a daemon from a pid reused since.
engine_vagrant_started() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'; }

# The devices QEMU has, one id a line.
engine_vagrant_devices() {
    engine_vagrant_qmp '{"execute":"qom-list","arguments":{"path":"/machine/peripheral"}}' |
        perl -MJSON::PP -ne 'print "$_->{name}\n" for @{decode_json($_)}'
}

# The root port a device sits on, from QOM, so a device with no record is still found.
engine_vagrant_device_slot() {
    engine_vagrant_qmp "{\"execute\":\"qom-get\",\"arguments\":{\"path\":\"/machine/peripheral/$1\",\"property\":\"parent_bus\"}}" |
        sed -n 's/.*flth_rp\([0-9][0-9]*\).*/\1/p'
}

# engine_attach_tree <run> <tree>: attach a tree as the run's device. Exit 1, saying
# why, when it could not; nothing is left behind then.
engine_attach_tree() {
    local run="$1" tree="$2" bin sock record log devices taken dev slot="" n pid start tries=0 err arg
    local -a args=()
    record="$(engine_vagrant_attached_dir)/$run"
    bin="$(engine_vagrant_virtiofsd)" || {
        echo "vm: no virtiofsd on this host, so $tree cannot be attached to the guest. 'chore vm:host:check' says what to install." >&2
        return 1
    }
    devices="$(engine_vagrant_devices)" || return 1
    # Taken: what the records say and what QEMU says, so a device nobody recorded is
    # not attached over.
    taken=" $(cat "$(engine_vagrant_attached_dir)"/* 2>/dev/null | sed -n 's/^slot //p' | tr '\n' ' ')"
    for dev in $(printf '%s\n' "$devices" | grep '^fs-' || true); do
        taken="$taken$(engine_vagrant_device_slot "$dev") "
    done
    for n in $(seq 1 "$FLTH_VM_SLOTS"); do
        printf '%s\n' "$devices" | grep -qx "flth_rp$n" || continue
        case "$taken" in *" $n "*) continue ;; esac
        slot="$n"
        break
    done
    if [ -z "$slot" ]; then
        echo "vm: all $FLTH_VM_SLOTS slots for a run's tree are in use; $tree is not attached. FLTH_SHARED_SLOTS reserves more at the next boot." >&2
        return 1
    fi
    sock="$(engine_vagrant_vfs_socket "$run")"
    if [ "${#sock}" -gt "$ENGINE_VAGRANT_SOCKET_MAX" ]; then
        echo "vm: virtiofsd's socket would be $sock, a path of ${#sock} bytes; a Unix socket path must be at" >&2
        echo "    most $ENGINE_VAGRANT_SOCKET_MAX. Put FLTH_STATE_DIR (or XDG_STATE_HOME) on a shorter path." >&2
        return 1
    fi
    mkdir -p "$(dirname "$sock")"
    rm -f "$sock"
    log="$record.log"
    while IFS= read -r arg; do args+=("$arg"); done < <(engine_vagrant_virtiofsd_args "$bin")
    # A session of its own, like the watchdog's: no signal to the run reaches it.
    perl -MPOSIX -e '
        my ($pidfile, $log) = splice(@ARGV, 0, 2);
        my $child = fork;
        exit 1 unless defined $child;
        if ($child) { open my $f, ">", $pidfile or exit 1; print {$f} "$child\n"; close $f; exit 0; }
        POSIX::setsid();
        open STDIN, "<", "/dev/null"; open STDOUT, ">", $log; open STDERR, ">&", \*STDOUT;
        exec @ARGV or exit 127;
    ' "$record.pid" "$log" "$bin" "--socket-path=$sock" "--shared-dir=$tree" "${args[@]}" </dev/null >/dev/null 2>&1 5<&- 6>&- 7<&- 8>&- 9>&- || {
        echo "vm: virtiofsd for $tree could not be started" >&2
        return 1
    }
    pid="$(cat "$record.pid" 2>/dev/null)"
    rm -f "$record.pid"
    until [ -S "$sock" ]; do
        if [ "$tries" -ge 100 ] || ! kill -0 "$pid" 2>/dev/null; then
            echo "vm: virtiofsd for $tree did not start: $(tail -n 3 "$log" 2>/dev/null | tr '\n' ' ')" >&2
            kill -TERM "$pid" 2>/dev/null || true
            return 1
        fi
        command -p sleep 0.05
        tries=$((tries + 1))
    done
    start="$(engine_vagrant_started "$pid")"
    printf 'slot %s\npid %s\nstart %s\nsocket %s\ntree %s\n' "$slot" "$pid" "$start" "$sock" "$tree" > "$record"
    if ! err="$(engine_vagrant_qmp \
        "{\"execute\":\"chardev-add\",\"arguments\":{\"id\":\"c-$run\",\"backend\":{\"type\":\"socket\",\"data\":{\"addr\":{\"type\":\"unix\",\"data\":{\"path\":\"$sock\"}},\"server\":false}}}}" \
        "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"vhost-user-fs-pci\",\"id\":\"fs-$run\",\"chardev\":\"c-$run\",\"tag\":\"$run\",\"bus\":\"flth_rp$slot\"}}" 2>&1 >/dev/null)"; then
        echo "vm: $tree could not be attached to the guest: $err" >&2
        # No device reached the guest, so nothing can be using the daemon.
        engine_vagrant_qmp "{\"execute\":\"chardev-remove\",\"arguments\":{\"id\":\"c-$run\"}}" >/dev/null 2>&1 || true
        kill -TERM "$pid" 2>/dev/null || true
        rm -f "$record"
        return 1
    fi
}

# engine_tree_attached <run>: 0 when its device is on record and its virtiofsd is
# alive, 1 when it is not attached, 3 when it is attached and its virtiofsd has gone.
engine_tree_attached() {
    local record pid start
    record="$(engine_vagrant_attached_dir)/$1"
    [ -f "$record" ] || return 1
    pid="$(sed -n 's/^pid //p' "$record")"
    start="$(sed -n 's/^start //p' "$record")"
    [ -n "$pid" ] && [ "$(engine_vagrant_started "$pid")" = "$start" ] || return 3
    return 0
}

# The runs with a device on record, one a line.
engine_attached_runs() {
    local record
    for record in "$(engine_vagrant_attached_dir)"/*; do
        [ -f "$record" ] || continue
        case "$record" in *.log | *.pid) continue ;; esac
        printf '%s\n' "${record##*/}"
    done
}

# The slot of a run's device, for the guest's side of a detach.
engine_tree_slot() { sed -n 's/^slot //p' "$(engine_vagrant_attached_dir)/$1" 2>/dev/null; }

# engine_detach_tree <run>: remove a run's device and then stop its virtiofsd. The
# guest must have let go of the mount already (lib/guest-run.sh, end), unless the
# daemon has died, when nothing may touch the mount and the device goes first.
#
# On macOS the guest's kernel has no ACPI, and a device_del waits five seconds after
# the attention button before the guest powers the slot off: the guest is asked to
# power it off itself, which QEMU takes as the unplug, about a second. On a Linux
# host the slot is ACPI hot-plug and device_del takes tens of milliseconds.
engine_detach_tree() {
    local run="$1" record slot pid start tries=0
    record="$(engine_vagrant_attached_dir)/$run"
    slot="$(engine_tree_slot "$run")"
    pid="$(sed -n 's/^pid //p' "$record" 2>/dev/null)"
    start="$(sed -n 's/^start //p' "$record" 2>/dev/null)"
    if engine_alive "$(engine_identity)" && engine_vagrant_devices 2>/dev/null | grep -qx "fs-$run"; then
        if [ "$(uname -s)" = Darwin ] && [ -n "$slot" ]; then
            engine_run "echo 0 > /sys/bus/pci/slots/$slot/power" >/dev/null 2>&1 || true
            # A second at most, measured; a guest that did not power it off by three
            # is asked the slower way.
            while engine_vagrant_devices 2>/dev/null | grep -qx "fs-$run" && [ "$tries" -lt 30 ]; do
                command -p sleep 0.1
                tries=$((tries + 1))
            done
            if engine_vagrant_devices 2>/dev/null | grep -qx "fs-$run"; then
                engine_vagrant_qmp "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"fs-$run\"}}" >/dev/null 2>&1 || true
            fi
        else
            engine_vagrant_qmp "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"fs-$run\"}}" >/dev/null 2>&1 || true
        fi
        while engine_vagrant_devices 2>/dev/null | grep -qx "fs-$run"; do
            if [ "$tries" -ge 300 ]; then
                echo "vm: the guest did not let go of run $run's device in 30s; its virtiofsd is left running, since stopping it now could wedge the guest." >&2
                return 1
            fi
            command -p sleep 0.1
            tries=$((tries + 1))
        done
        engine_vagrant_qmp "{\"execute\":\"chardev-remove\",\"arguments\":{\"id\":\"c-$run\"}}" >/dev/null 2>&1 || true
    fi
    # The device has gone, or the guest has: the daemon ends by itself, and is told to
    # if it has not.
    if [ -n "$pid" ] && [ "$(engine_vagrant_started "$pid")" = "$start" ]; then
        tries=0
        while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 50 ]; do command -p sleep 0.1; tries=$((tries + 1)); done
        kill -TERM "$pid" 2>/dev/null || true
    fi
    rm -f "$record" "$record.log" "$(engine_vagrant_vfs_socket "$run")"
}

# Every record and daemon, for a guest that has gone: nothing can use them now.
engine_vagrant_forget_attached() {
    local run pid start record
    for record in "$(engine_vagrant_attached_dir)"/*; do
        [ -f "$record" ] || continue
        case "$record" in *.log | *.pid) rm -f "$record"; continue ;; esac
        run="${record##*/}"
        pid="$(sed -n 's/^pid //p' "$record")"
        start="$(sed -n 's/^start //p' "$record")"
        if [ -n "$pid" ] && [ "$(engine_vagrant_started "$pid")" = "$start" ]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
        rm -f "$record" "$(engine_vagrant_vfs_socket "$run")"
    done
}
