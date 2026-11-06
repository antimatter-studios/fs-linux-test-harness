#!/usr/bin/env bash
#
# ci-setup-apt.sh — scripts/lib/apt.sh, the bounded apt-get that
# scripts/ci-setup-linux.sh installs QEMU and Vagrant through (#77). On
# 2026-10-22 the QEMU group's two silenced apt-get calls held hosted runners
# for up to 26 minutes, printing nothing, and cancelled fixture jobs. So
# every call carries apt's own retries and connection timeouts, bounds each
# attempt with `timeout` and tries again after a stall (configuring dpkg
# first, as a cut-off install leaves it interrupted), prints a line before
# each attempt and one when it ends, and fails naming what it was fetching,
# with the tail of apt's output, when the last attempt does.
#
# Run with `sudo`, `apt-get` and `dpkg` stubbed on PATH; `timeout` and
# `sleep` are the real ones.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

LIB="$REPO/scripts/lib/apt.sh"
SETUP="$REPO/scripts/ci-setup-linux.sh"
# No sources file until the mirror checks make one: nothing here may read or
# rewrite the machine's own /etc/apt.
export FLTH_APT_SOURCES="$SANDBOX/no-such.sources"

if ! command -v timeout >/dev/null 2>&1; then
    bad "timeout is required: install coreutils"
    finish ci-setup-apt
fi
if [ ! -f "$LIB" ]; then
    bad "scripts/lib/apt.sh exists"
    finish ci-setup-apt
fi

bin="$SANDBOX/bin"
mkdir -p "$bin"
# sudo runs its command, environment assignments first, as sudo does.
printf '#!/usr/bin/env bash\nexec env "$@"\n' > "$bin/sudo"
# apt-get logs its arguments and frontend; $SANDBOX/hang makes it stall,
# $SANDBOX/hang-once stall once, and $SANDBOX/fail fail, saying why. A
# mirror named in $SANDBOX/stalled-mirrors stalls whenever the sources file
# points at it: the stand-in for a stalled package mirror (#200).
cat > "$bin/apt-get" <<STUB
#!/usr/bin/env bash
echo "apt-get \$* frontend=\${DEBIAN_FRONTEND:-}" >> "$SANDBOX/calls"
if [ -f "$SANDBOX/stalled-mirrors" ] && [ -f "\$FLTH_APT_SOURCES" ]; then
    while read -r m; do
        grep -qF "URIs: \$m" "\$FLTH_APT_SOURCES" && exec sleep 30
    done < "$SANDBOX/stalled-mirrors"
fi
[ -f "$SANDBOX/hang" ] && exec sleep 30
if [ -f "$SANDBOX/hang-once" ]; then rm -f "$SANDBOX/hang-once"; exec sleep 30; fi
if [ -f "$SANDBOX/fail" ]; then echo "E: the stub mirror refused" >&2; exit 100; fi
exit 0
STUB
# dpkg logs what it was asked.
cat > "$bin/dpkg" <<STUB
#!/usr/bin/env bash
echo "dpkg \$*" >> "$SANDBOX/calls"
exit 0
STUB
# Under ci-setup-linux.sh's own shell options: a helper that ends on a
# failed test kills the setup step there, saying nothing (#204's first run).
cat > "$SANDBOX/run-apt" <<RUN
#!/usr/bin/env bash
set -euo pipefail
. "$LIB"
flth_apt "\$@"
RUN
chmod +x "$bin/"* "$SANDBOX/run-apt"

run_apt() {
    : > "$SANDBOX/calls"
    out="$(PATH="$bin:$PATH" "$SANDBOX/run-apt" "$@" 2>&1)"
    rc=$?
    calls="$(cat "$SANDBOX/calls")"
}

# A call that finishes.
run_apt "QEMU" install -y -qq qemu-system-x86 qemu-utils
check_eq "$rc" 0 "a finished install succeeds"
check_contains "$calls" "-o Acquire::Retries=3" "apt retries a failed fetch"
check_contains "$calls" "-o Acquire::http::Timeout=30" "apt gives up on a silent http connection"
check_contains "$calls" "-o Acquire::https::Timeout=30" "apt gives up on a silent https connection"
check_contains "$calls" "install -y -qq qemu-system-x86 qemu-utils" "the caller's arguments reach apt-get"
check_contains "$calls" "frontend=noninteractive" "apt-get runs noninteractive"
check_contains "$out" "QEMU" "a line names the call before it starts"
check_contains "$out" "attempt 1 of 3" "and which attempt it is, of how many"
check_contains "$out" "done in" "a line reports that it finished"
check_eq "$(grep -c '^apt-get ' <<<"$calls")" 1 "a call that finishes is made once"
check_lacks "$calls" "dpkg" "and configures nothing"

# A stall on one attempt is cut off and tried again, after dpkg is
# configured, and the next attempt finishes.
touch "$SANDBOX/hang-once"
export FLTH_APT_TIMEOUT=2
run_apt "QEMU" install -y -qq qemu-utils
check_eq "$rc" 0 "an install that stalls once succeeds on its next attempt"
check_eq "$(grep -c '^apt-get ' <<<"$calls")" 2 "the stalled attempt is made again"
check_contains "$calls" "dpkg --configure -a" "dpkg is configured before the next attempt"
check_contains "$out" "did not finish within 2 s" "the stalled attempt is reported with its bound"
check_contains "$out" "attempt 2 of 3" "and the next attempt is named"

# A call that stalls every time is cut off at each bound and names what
# stalled, after the attempts it was given.
touch "$SANDBOX/hang"
export FLTH_APT_ATTEMPTS=2
start=$SECONDS
run_apt "QEMU" install -y -qq qemu-utils
elapsed=$((SECONDS - start))
unset FLTH_APT_TIMEOUT FLTH_APT_ATTEMPTS
rm -f "$SANDBOX/hang"
if [ "$rc" -ne 0 ]; then ok "a stalled apt-get fails"; else bad "a stalled apt-get fails (it exited 0)"; fi
if [ "$elapsed" -lt 20 ]; then
    ok "a stalled apt-get is cut off at its bound"
else
    bad "a stalled apt-get is cut off at its bound (it took $elapsed s against two 2 s attempts)"
fi
check_eq "$(grep -c '^apt-get ' <<<"$calls")" 2 "it makes the attempts it was given and no more"
check_contains "$out" "did not finish within 2 s in 2 attempts" "the stall is reported with its bound and attempts"
check_contains "$out" "QEMU" "the stall names what was being fetched"

# A call that fails keeps apt-get's status, and shows what apt-get said.
touch "$SANDBOX/fail"
run_apt "QEMU" install -y -qq qemu-utils
rm -f "$SANDBOX/fail"
check_eq "$rc" 100 "a failed apt-get keeps its exit status"
check_contains "$out" "exit 100" "the failure names apt-get's status"
check_contains "$out" "E: the stub mirror refused" "and prints the tail of apt-get's output"

# A stalled mirror is left behind (#200). The runner's sources name one
# Ubuntu mirror, and security updates from another host. When an attempt
# stalls, the next one points the Ubuntu mirror at another, fetches the
# package index from it, and installs from there; security is untouched.
cat > "$SANDBOX/ubuntu.sources" <<'SOURCES'
Types: deb
URIs: http://azure.archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
export FLTH_APT_SOURCES="$SANDBOX/ubuntu.sources"
export FLTH_APT_MIRRORS="http://mirror-two.example/ubuntu/ http://mirror-three.example/ubuntu/"
export FLTH_APT_TIMEOUT=2
echo "http://azure.archive.ubuntu.com/ubuntu/" > "$SANDBOX/stalled-mirrors"
run_apt "QEMU" install -y -qq qemu-utils
sources="$(cat "$SANDBOX/ubuntu.sources")"
check_eq "$rc" 0 "an install whose mirror stalls succeeds from another mirror"
check_contains "$sources" "URIs: http://mirror-two.example/ubuntu/" "the sources now name the next mirror"
check_lacks "$sources" "azure.archive.ubuntu.com" "and no longer the one that stalled"
check_contains "$sources" "URIs: http://security.ubuntu.com/ubuntu/" "security updates keep their own host"
check_contains "$out" "azure.archive.ubuntu.com" "the stalled mirror is named"
check_contains "$out" "mirror-two.example" "and so is the one the next attempt uses"
check_eq "$(grep '^apt-get ' <<<"$calls" | sed -n 2,3p | sed 's/ -o [^ ]*//g')" "apt-get update -qq frontend=noninteractive
apt-get install -y -qq qemu-utils frontend=noninteractive" "the next mirror's package index is fetched before the install is tried again"

# A stall on every mirror fails naming each one it tried.
printf '%s\n' http://mirror-two.example/ubuntu/ http://mirror-three.example/ubuntu/ >> "$SANDBOX/stalled-mirrors"
sed -i.bak 's#mirror-two.example#azure.archive.ubuntu.com#' "$SANDBOX/ubuntu.sources"
run_apt "QEMU" install -y -qq qemu-utils
if [ "$rc" -ne 0 ]; then ok "a stall on every mirror fails"; else bad "a stall on every mirror fails (it exited 0)"; fi
check_contains "$out" "a package mirror stalled: http://azure.archive.ubuntu.com/ubuntu/, then http://mirror-two.example/ubuntu/, then http://mirror-three.example/ubuntu/" "the failure names every mirror that stalled, in order"

# A package index update that stalls moves to the next mirror as well, and
# needs no second update before it.
rm -f "$SANDBOX/stalled-mirrors"
printf 'http://mirror-three.example/ubuntu/\n' > "$SANDBOX/stalled-mirrors"
run_apt "the package index" update -qq
check_eq "$rc" 0 "an index update whose mirror stalls succeeds from another mirror"
check_eq "$(grep -c ' update -qq ' <<<"$calls")" 2 "and is fetched once per mirror"
rm -f "$SANDBOX/stalled-mirrors"
unset FLTH_APT_MIRRORS FLTH_APT_TIMEOUT
export FLTH_APT_SOURCES="$SANDBOX/no-such.sources"

# GitHub's ubuntu-24.04 image names its archive mirror through a mirror list
# (runner-images' configure-apt-sources.sh): `mirror+file:` a file of
# mirrors, Azure's first. Only the security stanza keeps a plain URI. Under
# ci-setup-linux.sh's shell options, a mirror search that found nothing
# ended the setup step at once, printing nothing (#204's first CI run).
printf 'http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\nhttps://archive.ubuntu.com/ubuntu/\tpriority:2\nhttps://security.ubuntu.com/ubuntu/\tpriority:3\n' > "$SANDBOX/apt-mirrors.txt"
cat > "$SANDBOX/runner.sources" <<SOURCES
Types: deb
URIs: mirror+file:$SANDBOX/apt-mirrors.txt
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
export FLTH_APT_SOURCES="$SANDBOX/runner.sources"
export FLTH_APT_MIRRORS="http://mirror-two.example/ubuntu/" FLTH_APT_TIMEOUT=2
run_apt "QEMU" install -y -qq qemu-utils
check_eq "$rc" 0 "a runner's mirror list does not stop an install that does not stall"
check_contains "$out" "from mirror+file:$SANDBOX/apt-mirrors.txt (http://azure.archive.ubuntu.com/ubuntu/ first)" "and the attempt names the list and the mirror it tries first"
printf 'mirror+file:%s\n' "$SANDBOX/apt-mirrors.txt" > "$SANDBOX/stalled-mirrors"
run_apt "QEMU" install -y -qq qemu-utils
sources="$(cat "$SANDBOX/runner.sources")"
check_eq "$rc" 0 "a runner's mirror list that stalls is left for the next mirror"
check_contains "$sources" "URIs: http://mirror-two.example/ubuntu/" "the sources now name the next mirror"
check_contains "$sources" "URIs: http://security.ubuntu.com/ubuntu/" "security updates keep their own host"
check_contains "$out" "the mirror mirror+file:$SANDBOX/apt-mirrors.txt (http://azure.archive.ubuntu.com/ubuntu/ first) stalled" "the stall names the list and its first mirror"
rm -f "$SANDBOX/stalled-mirrors"
# Sources that name only the security host leave nothing to switch, and the
# install still runs.
sed -n '/security/,$p' "$SANDBOX/runner.sources" > "$SANDBOX/security-only.sources"
FLTH_APT_SOURCES="$SANDBOX/security-only.sources" run_apt "QEMU" install -y -qq qemu-utils
check_eq "$rc" 0 "sources with no archive mirror still install"
unset FLTH_APT_MIRRORS FLTH_APT_TIMEOUT
export FLTH_APT_SOURCES="$SANDBOX/no-such.sources"

# An older runner names its mirror on a one-line `deb` entry instead.
printf '%s\n' '# deb http://commented.example/ubuntu/ jammy main' \
    'deb [arch=amd64] http://azure.archive.ubuntu.com/ubuntu/ jammy main' \
    'deb http://security.ubuntu.com/ubuntu/ jammy-security main' > "$SANDBOX/sources.list"
got="$(FLTH_APT_SOURCES="$SANDBOX/sources.list" bash -c '. "$1"; flth_apt_mirror' _ "$LIB")"
check_eq "$got" "http://azure.archive.ubuntu.com/ubuntu/" "a one-line deb entry's mirror is read, past comments and options"
got="$(bash -c '. "$1"; flth_apt_mirror' _ "$LIB")"
check_eq "$got" "" "no sources file names no mirror, so nothing switches"

# ci-setup-linux.sh calls apt-get only through the bounded call: the
# package index and QEMU, then HashiCorp's index and Vagrant.
direct="$(grep -nE '(^|[^-_[:alnum:]])apt-get ' "$SETUP" | grep -vE '^[0-9]+: *#' || true)"
check_eq "$direct" "" "ci-setup-linux.sh runs no apt-get of its own"
check_eq "$(grep -cE '^ *flth_apt ' "$SETUP" | tr -d ' ')" 4 "ci-setup-linux.sh bounds all four of its apt-get calls"

finish ci-setup-apt
