#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
export SANDBOX
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
    /tmp) if [ -f "$SANDBOX/bound" ]; then echo ext4; else echo tmpfs; fi ;;
    *) if [ -f "$SANDBOX/bad-disk" ]; then echo tmpfs; else echo ext4; fi ;;
esac
EOF
cat > "$SANDBOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    'mask tmp.mount') touch "$SANDBOX/masked" ;;
    'is-enabled tmp.mount')
        if [ -n "${MASK_STATE:-}" ]; then
            echo "$MASK_STATE"
        elif [ -f "$SANDBOX/masked" ]; then
            echo masked
        else
            echo enabled
        fi
        exit 1
        ;;
    *) exit 2 ;;
esac
EOF
cat > "$SANDBOX/bin/mount" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/mounts"
touch "$SANDBOX/bound"
EOF
cat > "$SANDBOX/bin/mkdir" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$SANDBOX/bin/mkdir" "$SANDBOX/bin/chmod"
chmod +x "$SANDBOX/bin/"*
export PATH="$SANDBOX/bin:$PATH"
bash "$REPO/vagrant/guest/disk-tmp.sh" verify 2>/dev/null
check_eq "$?" 1 'a disposable boot refuses an unmasked tmp.mount'
touch "$SANDBOX/masked"
bash "$REPO/vagrant/guest/disk-tmp.sh" verify 2>/dev/null
check_eq "$?" 1 'a disposable boot refuses an already mounted tmpfs'
MASK_STATE=masked-runtime bash "$REPO/vagrant/guest/disk-tmp.sh" verify 2>/dev/null
check_eq "$?" 1 'a runtime mask does not allow RAM-backed /tmp'
check_eq "$(test -f "$SANDBOX/mounts" && echo mounted)" '' 'a disposable boot never covers up a RAM-backed mount'
mv "$SANDBOX/masked" "$SANDBOX/masked-before-preparation"
bash "$REPO/vagrant/guest/disk-tmp.sh"
check_eq "$?" 0 'provisioning succeeds'
check_eq "$(test -f "$SANDBOX/masked" && echo masked)" masked 'preparation masks tmp.mount on the base disk'
check_eq "$(cat "$SANDBOX/mounts")" '--bind /var/lib/fs-linux-test-harness/boot-tmp /tmp' 'tmpfs is covered by disk-backed scratch'
bash "$REPO/vagrant/guest/disk-tmp.sh"
check_eq "$?" 0 'repeated provisioning succeeds'
check_eq "$(wc -l < "$SANDBOX/mounts" | tr -d ' ')" 1 'repeated provisioning does not stack mounts'
bash "$REPO/vagrant/guest/disk-tmp.sh" verify
check_eq "$?" 0 'a disposable boot accepts an already masked, disk-backed /tmp'
MASK_STATE=masked-runtime bash "$REPO/vagrant/guest/disk-tmp.sh" verify
check_eq "$?" 0 'a direct profile boot accepts a runtime mask with disk-backed /tmp'
touch "$SANDBOX/bad-disk"
bash "$REPO/vagrant/guest/disk-tmp.sh" 2>/dev/null
check_eq "$?" 1 'RAM-backed scratch directory is refused'
finish guest-tmp-bootstrap
