#!/usr/bin/env bash
#
# box-catalog.sh — a box that could not be fetched is not a guest that would
# not boot (#145).
#
# A first boot fetches its box. When the catalog answered 503, the harness
# spent its three boot attempts inside ten seconds and then blamed the guest,
# which never started: one short outage threw away a merge queue run that had
# taken hours. Here `vm.sh up` drives the real Vagrant engine with `vagrant`
# stood in for, answering with Vagrant's own words. The texts come from Vagrant
# 2.4.9's templates/locales/en.yml and from the run the issue names.
#
# `sleep` is stubbed and records what it was asked for, so the waits are read
# rather than waited out. One second is passed through a little: that is the
# boot output's follower polling, and it must not spin.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
require_guest_bash || exit 1

BIN="$SANDBOX/bin"
export STUBDIR="$SANDBOX/stubdir"
mkdir -p "$BIN" "$STUBDIR"

HARNESS="$SANDBOX/harness"
mkdir -p "$HARNESS"
cp -R "$REPO/scripts" "$REPO/vagrant" "$HARNESS/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HARNESS/scripts/host-tools.sh"
chmod +x "$HARNESS/scripts/host-tools.sh"
VM="$HARNESS/scripts/vm.sh"

cat > "$BIN/sleep" <<'STUB'
#!/bin/sh
if [ "$1" = 1 ]; then
    exec /bin/sleep 0.02
fi
echo "$1" >> "$STUBDIR/waits"
STUB
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' > "$BIN/uname"
# Nothing reaches a shell: a guest script names the guest's own fixed paths.
printf '#!/bin/sh\n[ -t 0 ] || cat > /dev/null\nexit 0\n' > "$BIN/ssh"

# `up` runs the answers in $STUBDIR/answers in turn, one line each, then boots.
# `slow` takes a few real seconds to give the next answer.
cat > "$BIN/vagrant" <<'STUB'
#!/usr/bin/env bash
echo "vagrant $*" >> "$STUBDIR/log"
catalog() {
    cat >&2 <<TEXT
The box 'cloud-image/debian-12' could not be found or could not be accessed in the remote catalog.
If this is a private box on the HashiCorp Vagrant Public Registry, please verify
you're logged in via \`vagrant cloud auth login\`. Also, please double-check the name.
The expanded URL and error message are shown below:

URL: ["https://vagrantcloud.com/cloud-image/debian-12"]
Error: $1
TEXT
}
case "$1" in
    status)
        echo "1700000000,default,metadata,provider,qemu"
        echo "1700000000,default,state,$(cat "$STUBDIR/status")"
        ;;
    ssh-config) printf 'Host default\n' ;;
    halt) echo stopped > "$STUBDIR/status" ;;
    up)
        answer="$(head -n 1 "$STUBDIR/answers")"
        tail -n +2 "$STUBDIR/answers" > "$STUBDIR/answers.next"
        mv "$STUBDIR/answers.next" "$STUBDIR/answers"
        if [ "$answer" = slow ]; then
            /bin/sleep 3
            answer=503
        fi
        case "$answer" in
            '') echo running > "$STUBDIR/status"; exit 0 ;;
            503 | 404) catalog "The requested URL returned error: $answer" ;;
            resolve) catalog "Could not resolve host: vagrantcloud.com" ;;
            download)
                cat >&2 <<'TEXT'
An error occurred while downloading the remote file. The error
message, if any, is reproduced below. Please fix this error and try
again.

The requested URL returned error: 502
TEXT
                ;;
            metadata)
                cat >&2 <<'TEXT'
There was an error while downloading the metadata for this box.
The error message is shown below:

The requested URL returned error: 504
TEXT
                ;;
            port) echo "Could not set up host forwarding rule 'tcp::50122-:22'" >&2 ;;
        esac
        exit 1
        ;;
esac
exit 0
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

CONSUMER="$SANDBOX/consumer"
make_consumer "$CONSUMER" box-test

# A machine that has never existed, on a host with no slot held.
SCENARIO=0
fresh() {
    SCENARIO=$((SCENARIO + 1))
    export FLTH_CACHE_DIR="$SANDBOX/$SCENARIO/cache" FLTH_STATE_DIR="$SANDBOX/$SCENARIO/state"
    echo not_created > "$STUBDIR/status"
    rm -f "$STUBDIR/waits" "$STUBDIR/log"
    : > "$STUBDIR/waits"
    : > "$STUBDIR/log"
    : > "$STUBDIR/answers"
    local answer
    for answer in "$@"; do
        printf '%s\n' "$answer" >> "$STUBDIR/answers"
    done
}
# Every answer has been given, and the next is a failure that would show.
outage() {
    local n=0
    fresh
    while [ "$n" -lt 100 ]; do
        printf '%s\n' "$1" >> "$STUBDIR/answers"
        n=$((n + 1))
    done
}

vm() { (cd "$CONSUMER" && "$VM" "$@"); }
ups() { grep -c '^vagrant up' "$STUBDIR/log"; }
forced_downs() { grep -c '^vagrant halt -f' "$STUBDIR/log"; }
waits() { tr '\n' ' ' < "$STUBDIR/waits" | sed 's/ $//'; }
waited_total() { awk '{ total += $1 } END { print total + 0 }' "$STUBDIR/waits"; }
longest_wait() { sort -n "$STUBDIR/waits" | tail -n 1; }
slot_state() { [ -d "$FLTH_STATE_DIR/slot.lock" ] && echo held || echo free; }
BOUND=900

# --- an outage that ends ------------------------------------------------------

# More failures than the three attempts a boot gets, so the catalog has to be
# waited for: the provisioning boot then the disposable boot that follows.
fresh 503 503 503 503 '' ''
out="$(vm up 2>&1)"
check_eq "$?" 0 "a catalog that answers 503 and recovers is an up"
check_eq "$(ups)" 6 "the box is asked for until it comes, past the three boot attempts"
check_eq "$(waits)" "30 60 120 120" "the wait grows, then stays below the slot's boot grace"
check_eq "$(forced_downs)" 0 "no VM was started, so none is forced down"
check_contains "$out" "503" "each wait names the status"
check_contains "$out" "box catalog" "and the catalog"
check_contains "$out" "https://vagrantcloud.com/cloud-image/debian-12" "and where it is"
check_lacks "$out" "console" "the guest's console is not offered as the account of it"
check_lacks "$out" "boot failed" "and it is not called a failed boot"

# --- an outage that does not end ----------------------------------------------

outage 503
out="$(vm up 2>&1)"
check_eq "$?" 1 "a catalog that answers 503 throughout fails up"
check_contains "$out" "box catalog" "the failure names the catalog"
check_contains "$out" "503" "and the status"
check_contains "$out" "https://vagrantcloud.com/cloud-image/debian-12" "and where it is"
check_contains "$out" "No VM was started" "and says no guest was involved"
check_lacks "$out" "console" "it does not point at the guest's console"
check_lacks "$out" "would not boot" "or say the VM would not boot"
total="$(waited_total)"
check_eq "$([ "$total" -le "$BOUND" ] && echo within || echo over)" within \
    "the wait is bounded overall ($total s against $BOUND s)"
check_eq "$([ "$total" -ge 300 ] && echo minutes || echo seconds)" minutes \
    "and an outage is waited for over minutes ($total s)"
check_eq "$(slot_state)" free "a failure confirmed stopped gives the slot back"

# The slot's lease is renewed at each attempt, and a wait longer than the boot
# grace would let a waiter take it from a holder with no VM to show for it.
grace="$(sed -n 's/^BOOT_GRACE_SECS="${FLTH_SLOT_BOOT_GRACE:-\([0-9]*\)}"$/\1/p' "$REPO/scripts/vm-slot.sh")"
check_eq "$([ "$(longest_wait)" -lt "$grace" ] && echo below || echo over)" below \
    "no wait reaches the slot's boot grace ($(longest_wait) s against $grace s)"

# Time spent failing counts, or a catalog that fails slowly outlasts the bound.
outage 503
{ echo slow; cat "$STUBDIR/answers"; } > "$STUBDIR/answers.first"
mv "$STUBDIR/answers.first" "$STUBDIR/answers"
vm up >/dev/null 2>&1
total="$(waited_total)"
check_eq "$([ "$total" -le $((BOUND - 2)) ] && echo counted || echo ignored)" counted \
    "the time an attempt took comes out of the bound ($total s of waiting)"

# --- the other ways a box fails to arrive --------------------------------------

outage resolve
out="$(vm up 2>&1)"
check_eq "$?" 1 "a catalog that cannot be reached fails up"
check_contains "$out" "Could not resolve host: vagrantcloud.com" "naming what went wrong"
check_contains "$out" "box catalog" "and the catalog"
check_eq "$([ "$(ups)" -gt 3 ] && echo waited || echo not)" waited "after waiting for it like a 503"

outage download
out="$(vm up 2>&1)"
check_eq "$?" 1 "a box file that will not download fails up"
check_contains "$out" "502" "naming the status"
check_contains "$out" "box" "and the box"
check_lacks "$out" "would not boot" "not the boot"
check_eq "$([ "$(ups)" -gt 3 ] && echo waited || echo not)" waited "after waiting for it"

outage metadata
out="$(vm up 2>&1)"
check_eq "$?" 1 "box metadata that will not download fails up"
check_contains "$out" "504" "naming the status"
check_lacks "$out" "would not boot" "not the boot"
check_eq "$([ "$(ups)" -gt 3 ] && echo waited || echo not)" waited "after waiting for it"

# --- what is not an outage keeps the boot's retries ----------------------------

outage port
out="$(vm up 2>&1)"
check_eq "$?" 1 "a real boot failure fails up"
check_eq "$(ups)" 3 "after its three attempts"
check_eq "$(waits)" "5 5" "five seconds apart"
check_eq "$(forced_downs)" 2 "forcing the half-started VM down between them"
check_contains "$out" "would not boot after 3 attempts" "and it is reported as a boot failure"
check_contains "$out" "no console output" "with the guest's console"
check_lacks "$out" "box catalog" "and no word of a catalog"

# A box that is not there will not arrive however long it is waited for.
outage 404
out="$(vm up 2>&1)"
check_eq "$?" 1 "a catalog that answers 404 fails up"
check_eq "$(ups)" 3 "without waiting for it"
check_eq "$(waits)" "5 5" "on the boot's own retries"
check_contains "$out" "The requested URL returned error: 404" "with Vagrant's own account of it"

# What one attempt said is not what the next one says.
fresh 503 port port port
out="$(vm up 2>&1)"
check_eq "$?" 1 "a real failure after a catalog that recovered fails up"
check_eq "$(ups)" 4 "the wait for the box costs none of the boot's attempts"
check_eq "$(waits)" "30 5 5" "and a boot failure that follows is not read as the earlier outage"
check_contains "$out" "would not boot after 3 attempts" "and is reported as itself"

finish box-catalog
