#!/usr/bin/env bash
#
# guest-scratch.sh — in the smoke consumer, no image tool works on a file
# on the share or the repository mount. It works on a copy on the guest's
# own disk, and only the finished artefact crosses back.
#
# THE SHARES ARE NOT A DISK. They are a host directory seen through a
# daemon (virtiofs on macOS) or QEMU's 9p server (Linux), and each refuses
# something a filesystem tool does to an image:
#
#   - On the macOS engine an O_DIRECT open of a shared file fails with
#     ENOTDIR (#26): the host's virtiofsd decodes an arm64 guest's open
#     flags with x86_64 values, and arm64's O_DIRECT is x86_64's
#     O_DIRECTORY (christhomas/virtiofsd#3). Every tool that opens an image
#     for direct I/O fails there, whatever the image holds, and the
#     failure reads as a verdict on the image.
#   - Over 9p, mmap is unreliable and ownership cannot be set, so a tool
#     that maps its image or restores a uid fails with a bare exit status.
#
# None of that shows on CI's x86_64 KVM guest, so a consumer modelled on
# a fixture that works on the share passes CI and fails on a Mac. The
# smoke consumer is that model ("shaped the way a real one uses the
# harness"), so it must not do it.
#
# The check is textual because the macOS engine cannot boot in CI (hosted
# arm64 macOS runners offer no nested virtualisation). tests/smoke.sh
# carries the end-to-end half: an O_DIRECT open on both shares, in a real
# guest.
#
# HOW IT READS A SCRIPT. A variable is "shared" when any assignment to it
# names the share's or the repository's guest mount point, the working
# directory (guest_command runs from the repository), or another shared
# variable. A line that invokes an image tool and names a shared path or
# variable is a finding. Comments are ignored; flow is not followed, so a
# variable assigned a shared path anywhere is shared everywhere.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

CONSUMER="$REPO/tests/smoke-consumer"
share_guest="$(sed -n 's/^FLTH_SHARE_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
repo_guest="$(sed -n 's/^FLTH_REPO_GUEST="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
check_true() { if eval "$1"; then ok "$2"; else bad "$3"; fi; }
check_true '[ -n "$share_guest" ] && [ -n "$repo_guest" ]' \
    "the share ($share_guest) and repository ($repo_guest) mount points are read from scripts/lib/common.sh" \
    "scripts/lib/common.sh no longer defines FLTH_SHARE_GUEST and FLTH_REPO_GUEST"

# shared_tool_lines <file>... — "<file>:<line>: <text>" for every image
# tool pointed at a shared path; silent when there is none.
shared_tool_lines() {
    local f
    for f in "$@"; do
        awk -v file="${f#"$REPO"/}" -v share="$share_guest" -v repo="$repo_guest" '
            function esc(s) { gsub(/[.]/, "[.]", s); return s }
            function shared(s,   v) {
                if (s ~ rootre) return 1
                for (v in taint) if (s ~ ("[$][{]?" v "([^A-Za-z0-9_]|$)")) return 1
                return 0
            }
            function tool(s) {
                if (s ~ toolre) return 1
                return s ~ /(^|[^A-Za-z0-9_.\/-])dd[ \t]/ && s ~ /(iflag|oflag)=[a-z,]*direct/
            }
            BEGIN {
                rootre = "(^|[^A-Za-z0-9_./-])(" esc(share) "|" esc(repo) ")([^A-Za-z0-9_.-]|$)"
                rootre = rootre "|[$][{]?PWD([^A-Za-z0-9_]|$)|[$][(]pwd[)]"
                toolre = "(^|[^A-Za-z0-9_./-])(mkfs([.][A-Za-z0-9]+)?|mke2fs|e2fsck|fsck([.][A-Za-z0-9]+)?|debugfs|dumpe2fs|tune2fs|resize2fs|e2image|xfs_[a-z_]+|losetup|mount|qemu-img)([^A-Za-z0-9_.-]|$)"
            }
            { line[NR] = $0 }
            END {
                do {
                    changed = 0
                    for (i = 1; i <= NR; i++) {
                        l = line[i]
                        if (l ~ /^[ \t]*#/) continue
                        if (!match(l, /^[ \t]*((local|export|readonly|declare)[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) continue
                        name = substr(l, RSTART, RLENGTH - 1)
                        sub(/^[ \t]*((local|export|readonly|declare)[ \t]+)?/, "", name)
                        if (!(name in taint) && shared(substr(l, RSTART + RLENGTH))) { taint[name] = 1; changed = 1 }
                    }
                } while (changed)
                for (i = 1; i <= NR; i++) {
                    l = line[i]
                    if (l ~ /^[ \t]*#/) continue
                    if (tool(l) && shared(l)) printf "%s:%d: %s\n", file, i, l
                }
            }' "$f"
    done
}

# THE GUARD CAN FAIL. Each of these points a tool at a shared file in a
# way the smoke consumer could drift into; a guard that passes them all is
# no guard.
fx="$SANDBOX/fixtures"
mkdir -p "$fx"
printf '#!/usr/bin/env bash\nxfs_repair -n %s/scratch/x.img\n' "$share_guest" > "$fx/literal.sh"
printf '#!/usr/bin/env bash\nshare=%s\nresults="$share/results"\nimg="${results}/fs.img"\nmkfs.ext4 -q -F "$img"\n' "$share_guest" > "$fx/chain.sh"
printf '#!/usr/bin/env bash\ndd if=%s/x.img of=/dev/null bs=4096 count=1 iflag=direct\n' "$repo_guest" > "$fx/dd-direct.sh"
printf '#!/usr/bin/env bash\nlocal_img="$PWD/fs.img"\nlosetup --direct-io=on -f "$local_img"\n' > "$fx/cwd.sh"
printf '#!/usr/bin/env bash\nexport src=%s/payload\nmkfs.ext4 -q -d "$src" /var/tmp/fs.img\n' "$share_guest" > "$fx/source.sh"
for f in literal chain dd-direct cwd source; do
    hits="$(shared_tool_lines "$fx/$f.sh")"
    check_true '[ -n "$hits" ]' "the guard refuses a tool pointed at a shared file ($f)" \
        "the guard passed $f.sh, which points a tool at a shared file"
done

printf '#!/usr/bin/env bash\n# xfs_repair -n %s/x.img would fail on a Mac\nshare=%s\nwork="$(mktemp -d /var/tmp/w.XXXXXX)"\nmkfs.ext4 -q -F "$work/fs.img"\ne2fsck -fn "$work/fs.img" > "$work/e2fsck.log"\ncp "$work/fs.img" "$work/e2fsck.log" "$share/results/"\ndd if=/dev/zero of="$share/x" bs=1 count=1\nmountpoint -q %s\n' \
    "$share_guest" "$share_guest" "$repo_guest" > "$fx/clean.sh"
check_eq "$(shared_tool_lines "$fx/clean.sh")" "" \
    "and passes tools on the guest's own disk, a copy across, a buffered dd, mountpoint, and comments"

# THE SMOKE CONSUMER, every script that runs in the guest: all of them but
# the [test] command, which runs on the host against the host's path.
host_cmd="$(sed -n 's/^command = "\.\/\(.*\)"$/\1/p' "$CONSUMER/fs-linux-test-harness.toml")"
guest_scripts=()
for f in "$CONSUMER"/*.sh; do
    [ "$(basename "$f")" = "$host_cmd" ] || guest_scripts+=("$f")
done
check_true '[ -n "$host_cmd" ] && [ -f "$CONSUMER/$host_cmd" ]' "the consumer's host-side [test] command ($host_cmd) is found and left out" \
    "the consumer's [test] command could not be read from its fs-linux-test-harness.toml"
check_true '[ -f "$CONSUMER/guest-suite.sh" ] && printf "%s\n" "${guest_scripts[@]}" | grep -q "/guest-suite.sh$"' \
    "the guest-side scripts (${#guest_scripts[@]}) include guest-suite.sh, which builds and checks the image" \
    "guest-suite.sh is not among the scanned scripts: the guard would pass having read nothing that matters"

hits="$(shared_tool_lines "${guest_scripts[@]}")"
check_eq "$hits" "" "the smoke consumer's guest scripts point no image tool at the share or the repository mount"

# And the real script, moved back onto the share, is refused: the guard
# reads this script's shape, not only the fixtures'.
sed 's|^img=.*|img="$results/fs.img"|' "$CONSUMER/guest-suite.sh" > "$SANDBOX/guest-suite-on-share.sh"
hits="$(shared_tool_lines "$SANDBOX/guest-suite-on-share.sh")"
check_true '[ -n "$hits" ]' "guest-suite.sh with its image moved onto the share is refused" \
    "guest-suite.sh with its image on the share passed the guard"

finish guest-scratch
