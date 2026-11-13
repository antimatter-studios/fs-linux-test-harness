#!/usr/bin/env bash
#
# kernel-oops.sh — a consumer joining, or a session ending on, a shared guest whose
# kernel has oopsed is told so, naming the first oops (#196).
#
# A kernel that has oopsed can keep answering, so its suites went on and reported
# what followed as their own result: a `tar` killed by the second oops showed only
# `tar: Unexpected EOF in archive`. The guest's console is on the host
# (engine_console_log), started afresh at each boot, so what it holds is this
# boot's. The text here is the console of the guest #196 was seen on.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"
make_consumer "$SANDBOX/one" oops-one
make_consumer "$SANDBOX/two" oops-two
mkdir -p "$FLTH_TEST_STUB/guest-repo"
one() { (cd "$SANDBOX/one" && "$VM" "$@"); }
two() { (cd "$SANDBOX/two" && "$VM" "$@"); }
CONSOLE="$FLTH_TEST_STUB/console.log"

one up >/dev/null 2>&1
check_eq "$?" 0 "a boot succeeds"
out="$(two up 2>&1)"
check_lacks "$out" "oops" "a join on a guest whose kernel is well says nothing of it"

cat >> "$CONSOLE" <<'CONSOLE'
[ 1783.112233] Unable to handle kernel NULL pointer dereference at virtual address 0000000000000000
[ 1783.112240] Internal error: Oops: 0000000096000004 [#1] SMP
[ 1783.112260] CPU: 2 PID: 73 Comm: kswapd0 Not tainted 6.1.0-42-cloud-arm64 #1  Debian 6.1.159-1
[ 1783.112270] pc : drop_buffers+0x3c/0x130
[ 2104.554100] Internal error: Oops: 0000000096000004 [#2] SMP
[ 2104.554120] CPU: 4 PID: 45236 Comm: tar Tainted: G      D            6.1.0-42-cloud-arm64 #1  Debian 6.1.159-1
CONSOLE

out="$(two up 2>&1)"
check_eq "$?" 0 "a join on a guest whose kernel has oopsed still runs"
check_contains "$out" "the shared guest's kernel has oopsed" "and is told the kernel has oopsed"
check_contains "$out" "Oops: 0000000096000004 [#1]" "naming the first oops"
check_contains "$out" "kswapd0" "and the process it hit"
check_lacks "$out" "[#2]" "not the later ones"
check_contains "$out" "$CONSOLE" "and where the console is"

/bin/sleep 300 >/dev/null 2>&1 &
suite=$!
(FLTH_RUN_ID="$(one run-id)" one session-begin "$suite") 2>/dev/null
out="$(one session-end "$suite" 2>&1)"
kill -KILL "$suite" 2>/dev/null; wait "$suite" 2>/dev/null
check_contains "$out" "the shared guest's kernel has oopsed" "a session that ends on it is told too"
check_contains "$out" "Oops: 0000000096000004 [#1]" "with the same oops"

out="$(one exec true 2>&1)"
check_lacks "$out" "oops" "a single call is not told each time: its suite is told when it joins and ends"
out="$(one run true 2>&1)"
check_lacks "$out" "oops" "nor a run, which boots only when it has to"

one down >/dev/null 2>&1
one up >/dev/null 2>&1
out="$(two up 2>&1)"
check_lacks "$out" "oops" "a new boot has a console of its own, and its kernel is well"

finish kernel-oops
