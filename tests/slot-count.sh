#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' > "$SANDBOX/bin/uname"
cat > "$SANDBOX/bin/vm_stat" <<'STUB'
#!/bin/sh
[ ! -f "$FLTH_STATE_DIR/unreadable" ] || exit 1
echo 'Mach Virtual Memory Statistics: (page size of 16384 bytes)'
printf 'Pages free: %s.\n' "$(cat "$FLTH_STATE_DIR/pages" 2>/dev/null || echo 2097152)"
echo 'Pages inactive: 0.'
echo 'Pages speculative: 0.'
STUB
chmod +x "$SANDBOX/bin/uname" "$SANDBOX/bin/vm_stat"
export PATH="$SANDBOX/bin:$PATH"
export FLTH_SLOT_COUNT=2 FLTH_SLOT_WAIT=0
make_consumer "$SANDBOX/one" slot-one '[vm]' 'memory = "4G"'
make_consumer "$SANDBOX/two" slot-two '[vm]' 'memory = "4G"'
make_consumer "$SANDBOX/three" slot-three '[vm]' 'memory = "4G"'
slot() { (cd "$SANDBOX/$1" && "$REPO/scripts/vm-slot.sh" "${@:2}"); }

slot one acquire 2>"$SANDBOX/one.log"
check_eq "$?" 0 "the first of two configured slots is acquired"
slot two acquire 2>"$SANDBOX/two.log"
check_eq "$?" 0 "a second consumer holds a slot at the same time"
out="$(slot three acquire 2>&1)"
check_eq "$?" 1 "a third consumer waits and times out without booting"
check_contains "$out" 'waiting' "contention is named as a wait"
check_contains "$out" 'slot-one' "the wait names the first holder"
check_contains "$out" 'slot-two' "the wait names the second holder"
slot one release
out="$(slot three status)"
check_contains "$out" 'slot-two' "releasing one slot leaves the other consumer alone"
slot three acquire 2>"$SANDBOX/three.log"
check_eq "$?" 0 "a waiting consumer can take the released slot"
slot two release
slot three release

mkdir -p "$FLTH_STATE_DIR"
echo 1024 > "$FLTH_STATE_DIR/pages"
out="$(slot one acquire 2>&1)"
check_eq "$?" 1 "low host memory refuses a VM before it starts"
check_contains "$out" 'slot-one' "the memory refusal names the consumer"
check_contains "$out" 'memory' "the refusal identifies host memory, not contention"
check_contains "$out" '4096 MiB' "the refusal reports the guest allocation"
echo 2097152 > "$FLTH_STATE_DIR/pages"
slot two acquire 2>"$SANDBOX/two.log"
check_eq "$?" 0 "memory refusal leaves no leaked reservation"
slot two release
touch "$FLTH_STATE_DIR/unreadable"
out="$(slot one acquire 2>&1)"
check_eq "$?" 1 "an unreadable host memory probe refuses rather than guessing"
check_contains "$out" 'memory' "an unreadable probe is reported by name"

out="$(FLTH_SLOT_COUNT=0 slot one acquire 2>&1)"
check_eq "$?" 1 "zero configured slots is rejected"
check_contains "$out" 'FLTH_SLOT_COUNT' "invalid slot configuration names its setting"
finish slot-count
