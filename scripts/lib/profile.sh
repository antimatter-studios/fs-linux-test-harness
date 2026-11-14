# shellcheck shell=bash
# Named run environments. Host paths and aliases do not enter the identity:
# two suites with the same resolved profile use the same machine.

# shellcheck disable=SC2034  # read by vm.sh and common.sh
flth_profile_load() {
    FLTH_PROFILE_NAME="${FLTH_PROFILE:-$CFG_vm_profile}"
    FLTH_PROFILE_RELEASE="" FLTH_PROFILE_MODULES="" FLTH_PROFILE_PAYLOAD="" FLTH_PROFILE_ID=""
    [ -n "$FLTH_PROFILE_NAME" ] || return 0
    case "$FLTH_PROFILE_NAME" in
        *[!a-z0-9-]* | -* | *-)
            flth_config_error "profile must use lowercase letters, digits and inner hyphens"; return 1 ;;
    esac
    local arch records key value
    arch="$(uname -m)"
    case "$arch" in arm64) arch=aarch64 ;; esac
    FLTH_PROFILE_ARCH="$arch"
    records="$(ruby "$FLTH_HARNESS/scripts/run-profile.rb" resolve \
        "${FLTH_PROFILE_DIR:-$FLTH_ROOT/run-profiles}/$FLTH_PROFILE_NAME.toml" "$arch")" || return 1
    while IFS="$(printf '\t')" read -r key value; do
        case "$key" in
            guest) CFG_vm_guest="$value" ;;
            release) FLTH_PROFILE_RELEASE="$value" ;;
            modules) FLTH_PROFILE_MODULES="$value" ;;
            payload) FLTH_PROFILE_PAYLOAD="$value" ;;
            fingerprint) FLTH_PROFILE_ID="$value" ;;
        esac
    done <<EOF
$records
EOF
}

profile_seal() { ruby "$FLTH_HARNESS/scripts/run-profile.rb" seal "$FLTH_MACHINE_DIR/boot"; }

# Only called under the machine's up lock, with no running suites. An interrupted
# preparation has no ready record: its disk is rebuilt before another attempt.
profile_prepare() {
    [ -n "$FLTH_PROFILE_ID" ] || return 0
    local ready="$FLTH_MACHINE_DIR/profile-ready" seal state rc=0
    state="$(engine_state)" || return 1
    case "$state" in
        stopped | absent) ;;
        *) echo "vm: profile preparation requires a confirmed stopped guest, got $state." >&2; return 1 ;;
    esac
    if [ -f "$ready" ] && [ "$state" != absent ]; then
        if ! seal="$(profile_seal)" || [ "$(cat "$ready")" != "$FLTH_PROFILE_ID $seal" ]; then
            echo "vm: profile boot artifacts changed; run 'chore vm:destroy' for this profile, then retry." >&2
            return 1
        fi
        return 0
    fi
    echo "[vm] preparing run profile $FLTH_PROFILE_NAME (${FLTH_PROFILE_RELEASE:-box-default})..." >&2
    engine_destroy || return 1
    confirmed_stopped || return 1
    rm -f "$ready"
    : > "$(unfinished_boot_marker)" || return 1
    boot_engine --persist || return 1
    profile_install || rc=$?
    # Flush while SSH still answers. A forced stop must never certify a disk.
    if [ "$rc" = 0 ]; then engine_run sync >&2 || rc=$?; fi
    engine_down >&2 || rc=1
    if ! confirmed_stopped; then
        engine_down --force >&2 || true
        confirmed_stopped || true
        return 1
    fi
    [ "$rc" = 0 ] || return "$rc"
    seal="$(profile_seal)" || return 1
    printf '%s %s\n' "$FLTH_PROFILE_ID" "$seal" > "$ready.new" || return 1
    mv -f "$ready.new" "$ready"
}

profile_install() {
    local dir="$FLTH_MACHINE_DIR/boot" release="$FLTH_PROFILE_RELEASE" file target expected
    engine_run "set -euo pipefail
export CARGO_BUILD_JOBS=$CFG_vm_build_jobs
payload='$FLTH_PROFILE_PAYLOAD'
if [ -n \"\$payload\" ]; then
    tmp=\"\$(mktemp)\"
    trap 'rm -f \"\$tmp\"' EXIT
    printf '%s' \"\$payload\" | base64 -d > \"\$tmp\"
    FLTH_GUEST=1 FLTH_KERNEL_RELEASE='$release' FLTH_KERNEL_ARCH='$FLTH_PROFILE_ARCH' bash \"\$tmp\" </dev/null >&2
fi
" >&2 || return 1
    mkdir -p "$dir" || return 1
    if [ -z "$release" ]; then
        release="$(engine_run 'uname -r')" || return 1
        case "$release" in
            '' | *[!a-zA-Z0-9._+-]*) echo 'vm: profile returned an invalid running kernel release.' >&2; return 1 ;;
        esac
        engine_run "set -euo pipefail
for module in $FLTH_PROFILE_MODULES; do
    modprobe \"\$module\" || exit 1
done" >&2 || return 1
        # Empty release keeps the engine on its pinned box's boot files.
        printf '%s\n' "$release" > "$dir/guest-release" || return 1
        : > "$dir/release"
        return
    fi
    engine_run "set -euo pipefail
[ -s '/boot/vmlinuz-$release' ] && [ -s '/boot/initrd.img-$release' ] && [ -d '/lib/modules/$release' ] || {
    echo 'vm: profile is missing kernel, initrd or matching modules for $release' >&2; exit 1;
}
for module in $FLTH_PROFILE_MODULES; do
    modprobe --set-version '$release' --show-depends \"\$module\" >/dev/null || {
        echo \"vm: profile cannot resolve module \$module for $release\" >&2; exit 1;
    }
done" >&2 || return 1
    for file in vmlinuz initrd.img; do
        target="/boot/$file-$release"
        expected="$(engine_run "sha256sum '$target'")" || return 1
        expected="${expected%% *}"
        engine_run "cat '$target'" > "$dir/$file.new" || return 1
        if [ "$(sha256_of "$dir/$file.new")" != "$expected" ]; then
            echo "vm: profile kernel transfer checksum mismatch for $file." >&2
            return 1
        fi
    done
    engine_run 'cat /proc/cmdline' | ruby "$FLTH_HARNESS/scripts/run-profile.rb" cmdline > "$dir/cmdline.new" || return 1
    [ -s "$dir/vmlinuz.new" ] && [ -s "$dir/initrd.img.new" ] || return 1
    mv -f "$dir/vmlinuz.new" "$dir/vmlinuz" && mv -f "$dir/initrd.img.new" "$dir/initrd.img" &&
        mv -f "$dir/cmdline.new" "$dir/cmdline" || return 1
    printf '%s\n' "$release" > "$dir/release"
}

profile_verify_guest() {
    [ -n "$FLTH_PROFILE_ID" ] || return 0
    local release="$FLTH_PROFILE_RELEASE"
    [ -n "$release" ] || release="$(cat "$FLTH_MACHINE_DIR/boot/guest-release")" || return 1
    case "$release" in
        '' | *[!a-zA-Z0-9._+-]*) echo 'vm: profile has an invalid expected kernel release.' >&2; return 1 ;;
    esac
    engine_run "set -euo pipefail
running=\"\$(uname -r)\"
[ \"\$running\" = '$release' ] || {
    echo \"vm: profile expected kernel $release, guest runs \$running\" >&2; exit 1;
}
[ -z '$FLTH_PROFILE_RELEASE' ] || [ -d '/lib/modules/$release' ] || {
    echo 'vm: profile has no matching module directory for $release' >&2; exit 1;
}
for module in $FLTH_PROFILE_MODULES; do
    modprobe \"\$module\" || {
        echo \"vm: profile cannot load module \$module on $release\" >&2; exit 1;
    }
done" >&2
}
