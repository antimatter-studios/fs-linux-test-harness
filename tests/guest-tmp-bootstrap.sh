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
bash "$REPO/vagrant/guest/disk-tmp.sh"
check_eq "$?" 0 'provisioning succeeds'
check_eq "$(cat "$SANDBOX/mounts")" '--bind /var/lib/fs-linux-test-harness/boot-tmp /tmp' 'tmpfs is covered by disk-backed scratch'
bash "$REPO/vagrant/guest/disk-tmp.sh"
check_eq "$?" 0 'repeated provisioning succeeds'
check_eq "$(wc -l < "$SANDBOX/mounts" | tr -d ' ')" 1 'repeated provisioning does not stack mounts'
touch "$SANDBOX/bad-disk"
bash "$REPO/vagrant/guest/disk-tmp.sh" 2>/dev/null
check_eq "$?" 1 'RAM-backed scratch directory is refused'
finish guest-tmp-bootstrap
