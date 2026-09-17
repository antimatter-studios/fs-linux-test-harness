# shellcheck shell=bash
#
# lib/engine-vagrant.sh — the engine interface (lib/engine.sh) on Vagrant
# and its QEMU provider.
#
# The Vagrantfile is the harness's own (vagrant/Vagrantfile) and reads
# only FLTH_* variables, which engine_prepare exports. Machine state goes
# to VAGRANT_DOTFILE_PATH under the consumer's machine directory, so the
# harness checkout is never written to and each consumer has its own
# disk.

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
    export FLTH_REPO_DIR="$FLTH_ROOT"
    export VAGRANT_DOTFILE_PATH="$FLTH_MACHINE_DIR/vagrant"
    export FLTH_VM_NAME="$CFG_project_name"
    export FLTH_VM_MEMORY="$CFG_vm_memory"
    export FLTH_VM_CPUS="$CFG_vm_cpus"
    export FLTH_VM_DISK="$CFG_vm_disk"
    export FLTH_VM_SSH_PORT="$CFG_vm_ssh_port"
    export FLTH_VM_DEADLINE_MINUTES="$CFG_vm_deadline_minutes"
    export FLTH_SHARE_DIR="$FLTH_SHARE_HOST"
    mkdir -p "$FLTH_MACHINE_DIR" "$FLTH_SHARE_HOST" "$(dirname "$(engine_ssh_control)")"

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

engine_vagrant_host_is_arm() {
    case "$(uname -m)" in arm64 | aarch64) return 0 ;; esac
    return 1
}

engine_vagrant() {
    (cd "$ENGINE_VAGRANT_DIR" && vagrant "$@")
}

engine_identity() {
    printf '%s\n' "$FLTH_MACHINE_DIR/vagrant"
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
        # The stock provider says `stopped`; the macOS fork `poweroff`.
        stopped | poweroff | shutoff) echo stopped ;;
        *) echo unknown ;;
    esac
}

engine_up() {
    engine_ssh_close
    rm -f "$FLTH_MACHINE_DIR/ssh-config"
    engine_vagrant up --provider qemu >&2 || return
    engine_ssh_config >/dev/null
}

engine_down() {
    if [ "${1:-}" = "--force" ]; then
        engine_vagrant halt -f >&2
    else
        engine_vagrant halt >&2
    fi
    engine_ssh_close
}

engine_destroy() {
    engine_ssh_close
    rm -f "$FLTH_MACHINE_DIR/ssh-config"
    engine_vagrant destroy -f >&2
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
# The socket lives beside the slot rather than in the machine directory:
# a Unix socket path is limited to about 104 bytes, and a machine
# directory under a deep checkout can exceed that on its own. Hashed, so
# the length is fixed whatever the project is called.
ENGINE_SSH_PERSIST="${FLTH_SSH_PERSIST:-3600}"

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
        -o "ControlPersist=$ENGINE_SSH_PERSIST" -N -f default \
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
engine_run() {
    local script="$1" cfg before rc=0
    cfg="$(engine_ssh_config)" || return 1
    engine_ssh "$cfg" "$script" || rc=$?
    if [ "$rc" -eq 255 ]; then
        before="$(cat "$cfg")"
        engine_ssh_config --refresh >/dev/null || return "$rc"
        if [ "$(cat "$cfg")" != "$before" ]; then
            rc=0
            engine_ssh_close
            engine_ssh "$cfg" "$script" || rc=$?
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
        ssh -F "$cfg" -o "ControlPath=$control" default -T 'sudo bash -s'
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
    local identity="$1" procs
    [ -n "$identity" ] || return 1
    # 2 when the process table cannot be read: "could not look" is not
    # "nothing is running".
    procs="$(ps -eo args= 2>/dev/null)" || return 2
    [ -n "$procs" ] || return 2
    printf '%s\n' "$procs" | awk -v want="$identity/" '
        { n = split($1, parts, "/") }
        parts[n] ~ /^qemu-system-/ && index($0, want) > 0 { found = 1 }
        END { exit !found }'
}
