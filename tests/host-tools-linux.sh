#!/usr/bin/env bash
#
# host-tools-linux.sh — scripts/host-tools.sh on a Linux host, with `uname`,
# `vagrant`, QEMU and virtiofsd stubbed, so a Linux host's answers can be given
# anywhere.
#
# What is pinned: upstream virtiofsd before 1.14.0 panics in setxattr on an
# extended attribute name that is not UTF-8, and the guest's request is never
# answered, so the call hangs (#274). Ubuntu 24.04 packages 1.10.0. A Linux host
# whose virtiofsd is older than 1.14.0, or whose version cannot be read, is
# refused, naming the version it needs and where to get it; 1.14.0 and newer
# pass. The virtiofsd checked is the one the engine would start: FLTH_VIRTIOFSD
# first, then the one on PATH.
#
# The rest of the report (KVM, firmware) depends on the machine this runs on,
# so only the virtiofsd lines are held here.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

BIN="$SANDBOX/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' > "$BIN/uname"
printf '#!/bin/sh\necho "Vagrant 2.4.9"\n' > "$BIN/vagrant"
printf '#!/bin/sh\nexit 0\n' > "$BIN/qemu-system-x86_64"
printf '#!/bin/sh\nexit 0\n' > "$BIN/qemu-img"
# virtiofsd answers --version from a file, as `virtiofsd 1.10.0` and the like,
# and logs every call's arguments.
cat > "$BIN/virtiofsd" <<STUB
#!/bin/sh
echo "\$*" >> "$SANDBOX/virtiofsd-calls"
[ "\$1" = --version ] && cat "$SANDBOX/virtiofsd-version"
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
unset FLTH_VIRTIOFSD

host_tools() { bash "$REPO/scripts/host-tools.sh" 2>&1; }

for v in "virtiofsd 1.10.0" "virtiofsd 1.13.3" "virtiofsd 1.9.0" "virtiofsd 1.14.0-rc1" "virtiofsd" "" "garbled output"; do
    echo "$v" > "$SANDBOX/virtiofsd-version"
    out="$(host_tools)"
    check_contains "$out" "missing: virtiofsd 1.14.0 or newer" "a Linux host whose virtiofsd says '$v' is refused"
    check_contains "$out" "at $BIN/virtiofsd" "  naming the virtiofsd it checked"
    check_contains "$out" "panics in setxattr" "  and why"
    check_contains "$out" "install-virtiofsd" "  and the CI action that installs upstream's build"
    check_contains "$out" "built from upstream's v1.14.0 as README 'Host setup' shows" "  and where to read how to build it elsewhere"
done
check_contains "$(echo "virtiofsd 1.10.0" > "$SANDBOX/virtiofsd-version"; host_tools)" "(found '1.10.0' at" "the version found is named"
check_contains "$(echo "garbled output" > "$SANDBOX/virtiofsd-version"; host_tools)" "(found 'unreadable' at" "a version that cannot be read is called unreadable"

for v in "virtiofsd 1.14.0" "virtiofsd 1.14.1" "virtiofsd 1.15.0" "virtiofsd 2.0.0" "virtiofsd 1.14.0.1"; do
    echo "$v" > "$SANDBOX/virtiofsd-version"
    out="$(host_tools)"
    check_lacks "$out" "virtiofsd" "a Linux host whose virtiofsd says '$v' has nothing to fix about it"
done

# Upstream's build has no --port-version, which only the macOS port prints
# (#276): Linux reads --version alone, and is never asked it.
check_contains "$(cat "$SANDBOX/virtiofsd-calls")" "--version" "a Linux host's virtiofsd is asked its --version"
check_lacks "$(cat "$SANDBOX/virtiofsd-calls")" "--port-version" "and never its --port-version"

# FLTH_VIRTIOFSD names the virtiofsd the engine starts, so it is the one checked.
mkdir -p "$SANDBOX/other"
cat > "$SANDBOX/other/virtiofsd" <<STUB
#!/bin/sh
[ "\$1" = --version ] && echo "virtiofsd 1.10.0"
exit 0
STUB
chmod +x "$SANDBOX/other/virtiofsd"
echo "virtiofsd 1.14.0" > "$SANDBOX/virtiofsd-version"
out="$(FLTH_VIRTIOFSD="$SANDBOX/other/virtiofsd" host_tools)"
check_contains "$out" "(found '1.10.0' at $SANDBOX/other/virtiofsd)" "FLTH_VIRTIOFSD is checked before the one on PATH"
echo "virtiofsd 1.10.0" > "$SANDBOX/virtiofsd-version"
cat > "$SANDBOX/other/virtiofsd" <<STUB
#!/bin/sh
[ "\$1" = --version ] && echo "virtiofsd 1.14.0"
exit 0
STUB
out="$(FLTH_VIRTIOFSD="$SANDBOX/other/virtiofsd" host_tools)"
check_lacks "$out" "virtiofsd" "and a good one there passes while the one on PATH is old"
out="$(FLTH_ACCELERATOR=tcg FLTH_VIRTIOFSD="$SANDBOX/other/virtiofsd" host_tools)"
check_eq "$?" 0 "TCG accepts a Linux x86_64 host without requiring /dev/kvm"
check_lacks "$out" "/dev/kvm" "TCG does not report a KVM requirement"

# The order host-tools.sh checks is the engine's order of choice.
engine_order="$(sed -n '/^engine_vagrant_virtiofsd() {/,/^}/p' "$REPO/scripts/lib/engine-vagrant.sh" | tr -s ' \\\n' ' ')"
tools_order="$(sed -n '/^engine_virtiofsd() {/,/^}/p' "$REPO/scripts/host-tools.sh" | tr -s ' \\\n' ' ')"
check_contains "$engine_order" '"${FLTH_VIRTIOFSD:-}" "$(command -v virtiofsd 2>/dev/null || true)" /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd' "the engine's order of choice is FLTH_VIRTIOFSD, PATH, then the distribution's paths"
check_contains "$tools_order" '"${FLTH_VIRTIOFSD:-}" "$(command -v virtiofsd 2>/dev/null || true)" /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd' "and host-tools.sh checks the virtiofsd in that same order"

finish host-tools-linux
