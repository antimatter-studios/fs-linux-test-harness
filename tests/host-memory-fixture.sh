#!/usr/bin/env bash
# Consumers can supply a memory fixture without the harness tests' awk shim.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
C="$SANDBOX/consumer"
make_consumer "$C" memory-fixture
export FLTH_CONFIG="$C/fs-linux-test-harness.toml"
mkdir -p "$SANDBOX/probe-bin"
cat > "$SANDBOX/probe-bin/uname" <<'STUB'
#!/bin/sh
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exec /usr/bin/uname "$@" ;; esac
STUB
# Refuse the real memory probe instead of depending on this machine's free RAM.
# Other awk calls still run normally, including actual parsing of the fixture.
cat > "$SANDBOX/probe-bin/awk" <<'STUB'
#!/bin/sh
if [ "$#" = 2 ] && [ "$2" = /proc/meminfo ]; then
    case "$1" in *'^MemAvailable:'*) echo real-probe >> "$FLTH_TEST_STUB/real-probes"; exit 19 ;; esac
fi
exec /usr/bin/awk "$@"
STUB
chmod +x "$SANDBOX/probe-bin/"*
export PATH="$SANDBOX/probe-bin:$PATH"
printf 'MemAvailable: 67108864 kB\n' > "$FLTH_TEST_MEMINFO"
out="$(cd "$C" && "$VM" up 2>&1)"; rc=$?
check_eq "$rc" 0 'a stub consumer boots using its explicit ample-memory fixture'
check_eq "$([ -f "$FLTH_TEST_STUB/real-probes" ] && echo read || echo untouched)" untouched 'admission never consults real host memory with an explicit fixture'
(cd "$C" && "$VM" down) > "$SANDBOX/down.log" 2>&1
for contents in 'MemAvailable: 0 kB' 'MemTotal: 67108864 kB'; do
    printf '%s\n' "$contents" > "$FLTH_TEST_MEMINFO"
    stub_state absent
    : > "$FLTH_TEST_STUB/calls"
    out="$(cd "$C" && "$VM" up 2>&1)"; rc=$?
    check_eq "$rc" 1 'insufficient or malformed fixture memory refuses a boot'
    check_eq "$(grep -c '^up' "$FLTH_TEST_STUB/calls" || true)" 0 'fixture refusal never asks the engine to boot'
    case "$contents" in
        *MemAvailable*) check_contains "$out" '0 MiB available' 'the low-memory fixture is measured exactly' ;;
        *) check_contains "$out" 'free memory could not be measured' 'a missing MemAvailable field refuses safely' ;;
    esac
done
out="$(FLTH_TEST_MEMINFO="$SANDBOX/missing" "$VM" up 2>&1)"; rc=$?
check_eq "$rc" 1 'an unreadable explicit fixture refuses rather than using real RAM'
check_contains "$out" 'free memory could not be measured' 'an unreadable fixture explains the failure'
finish host-memory-fixture
