#!/usr/bin/env bash
#
# setup-rearm.sh -- the setup call counts as a call into the guest (#150).
#
# The deadline is idle time, and a guest running a consumer's setup is not idle.
# A setup that ends just inside a short deadline must leave the harness the whole
# deadline to reach its first command, so the call re-arms as it starts and as it
# ends, as `run` and `exec` do. An aged stamp stands in for a minute passing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
make_stub_harness
VM="$STUB_HARNESS/scripts/vm.sh"

C="$SANDBOX/consumer"
make_consumer "$C" setup-rearm
# The shared guest's deadline is the host's to set, not a consumer's (#220).
export FLTH_SHARED_DEADLINE=5
export SETUP_LOG="$SANDBOX/setup.log"
STUB="$FLTH_TEST_STUB"

vm() { (cd "$C" && "$VM" "$@"); }
rearms() { grep -c '^shutdown --no-wall -h +5$' "$STUB/calls" | tr -d ' '; }

# --- the first boot ------------------------------------------------------

rm -f "$STUB/guest-rearmed"; stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "the first boot comes up"
check_contains "$(cat "$SETUP_LOG")" "setup ran for setup-rearm" "and its setup ran"
check_eq "$(rearms)" 1 "the setup call re-arms the guest's poweroff for the configured minutes"

# --- a setup that ran for longer than the window -------------------------

printf '#!/usr/bin/env bash\necho 1 > "%s/guest-rearmed"\n' "$STUB" > "$C/setup.sh"
rm -f "$STUB/guest-rearmed"; stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "a changed setup is applied to the running guest"
check_eq "$(rearms)" 2 "and the call re-arms as it ends as well as when it starts"

# --- the hold still wins -------------------------------------------------

printf '#!/usr/bin/env bash\ntrue # held\n' > "$C/setup.sh"
: > "$STUB/guest-held"; rm -f "$STUB/guest-rearmed"; stub_reset_calls
vm up 2>/dev/null
check_eq "$?" 0 "a changed setup is applied to a held guest"
check_eq "$(rearms)" 0 "and a held guest is not re-armed"
rm -f "$STUB/guest-held"

# --- what a failed setup reports stays as it was -------------------------

printf '#!/usr/bin/env bash\nexit 7\n' > "$C/setup.sh"
rc=0; err="$(vm up 2>&1 >/dev/null)" || rc=$?
check_eq "$rc" 1 "a failed setup fails the call"
check_contains "$err" "the setup script (setup.sh) failed inside the VM" "and says so"
check_lacks "$err" "exit 255" "with no talk of a lost connection"

printf '#!/usr/bin/env bash\nexit 255\n' > "$C/setup.sh"
rc=0; err="$(vm up 2>&1 >/dev/null)" || rc=$?
check_eq "$rc" 1 "a setup call that ends in 255 fails the call"
check_eq "$(printf '%s\n' "$err" | grep -c 'exit 255: ssh lost its connection')" 1 "and reports the lost connection once"
check_contains "$err" "the setup script (setup.sh) failed inside the VM" "then says the setup failed"

vm down 2>/dev/null
finish setup-rearm
