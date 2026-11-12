#!/usr/bin/env bash
#
# guest-room.sh — a suite joining a shared guest that has little memory left is told
# before it starts, with the numbers and who is using it (#185).
#
# Six suites building at once ran a 10G guest out of memory: the kernel killed
# processes and a few `vm.sh exec` calls hung, and no suite was told why. The guest's
# own /proc/meminfo is the measure, read as a suite joins. Below
# FLTH_SHARED_MIN_AVAILABLE (2048 MiB by default) the join says so; it still runs,
# because whether the suite fits is the suite's to know.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
make_consumer "$SANDBOX/one" room-one
make_consumer "$SANDBOX/two" room-two
mkdir -p "$FLTH_TEST_STUB/guest-repo" "$FLTH_TEST_STUB/guest-proc"
one() { (cd "$SANDBOX/one" && "$VM" "$@"); }
two() { (cd "$SANDBOX/two" && "$VM" "$@"); }
meminfo() { printf 'MemTotal: %s kB\nMemFree: 1 kB\nMemAvailable: %s kB\n' "$(($1 * 1024))" "$(($2 * 1024))" > "$FLTH_TEST_STUB/guest-proc/meminfo"; }

meminfo 8192 6000
one up >/dev/null 2>&1
check_eq "$?" 0 "a boot succeeds"
/bin/sleep 300 >/dev/null 2>&1 &
suite=$!
(FLTH_RUN_ID="$(one run-id)" one session-begin "$suite") 2>/dev/null

out="$(two up 2>&1)"
check_lacks "$out" "MiB available" "a join on a guest with room says nothing of it"

meminfo 8192 600
out="$(two up 2>&1)"
check_eq "$?" 0 "a join on a guest with little room still runs"
check_contains "$out" "the shared guest has 600 MiB of 8192 MiB available" "and is told how much is left"
check_contains "$out" "room-one (pid $suite)" "and who is using it"
check_contains "$out" "FLTH_SHARED_MEMORY" "and what sizes the guest"

out="$(FLTH_SHARED_MIN_AVAILABLE=512 two up 2>&1)"
check_lacks "$out" "MiB available" "FLTH_SHARED_MIN_AVAILABLE sets where that starts"

kill -KILL "$suite" 2>/dev/null; wait "$suite" 2>/dev/null
finish guest-room
