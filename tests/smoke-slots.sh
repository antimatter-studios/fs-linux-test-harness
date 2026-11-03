#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

export SMOKE_SLOT_TEST="$SANDBOX"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/slot" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    status) cat "$SMOKE_SLOT_TEST/status" ;;
    acquire)
        printf '%s:%s\n' "${FLTH_STATE_DIR:-}" "${FLTH_SLOT_COUNT:-}" > "$SMOKE_SLOT_TEST/acquire"
        ;;
esac
STUB
cat > "$SANDBOX/bin/vm" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    up)
        printf '%s:%s\n' "${FLTH_STATE_DIR:-}" "${FLTH_SLOT_COUNT:-}" > "$SMOKE_SLOT_TEST/contender-env"
        if [ "${FLTH_SLOT_COUNT:-}" = 1 ] && [ "${FLTH_STATE_DIR:-}" != "$SMOKE_SLOT_TEST/state" ]; then
            echo '[vm-slot] waiting for the VM slot — held by flth-smoke (1s)'
            echo 'not booting a second VM'
            exit 1
        fi
        touch "$SMOKE_SLOT_TEST/booted"
        ;;
    status) [ -e "$SMOKE_SLOT_TEST/booted" ] ;;
esac
STUB
chmod +x "$SANDBOX/bin/slot" "$SANDBOX/bin/vm"
export SLOT="$SANDBOX/bin/slot"
export VM="$SANDBOX/bin/vm"

extract_helper() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { copying = 1 }
        copying { print; if ($0 ~ /\}$/) exit }
    ' "$REPO/tests/smoke.sh"
}
eval "$(extract_helper slot_holder)"
eval "$(extract_helper slot_contender)"

printf 'held by other-consumer for 2m\n  identity: /other\nheld by flth-smoke for 1m\n  identity: /smoke\n' > "$SANDBOX/status"
check_eq "$(slot_holder)" flth-smoke "the smoke holder is found in the second slot"
printf 'held by flth-smoke for 1m\nheld by other-consumer for 2m\n' > "$SANDBOX/status"
check_eq "$(slot_holder)" flth-smoke "the smoke holder is found in the first of several slots"
printf 'held by other-consumer for 2m\nheld by flth-smoke-other for 1m\n' > "$SANDBOX/status"
check_eq "$(slot_holder)" '' "another holder and a name prefix do not count as smoke ownership"
printf 'the VM slot is free\nheld by flth-smoke for 1m\n' > "$SANDBOX/status"
check_eq "$(slot_holder)" flth-smoke "a free first slot does not hide smoke ownership"
printf 'the VM slot is free\n' > "$SANDBOX/status"
check_eq "$(slot_holder)" '' "no smoke holder is still a failed ownership assertion"

CONTENDER="$SANDBOX/contender"
mkdir "$CONTENDER"
export FLTH_SLOT_COUNT=2
printf 'held by flth-smoke for 1m\nheld by other-consumer for 2m\n' > "$SANDBOX/status"
# shellcheck disable=SC2329
step() { :; }
# shellcheck disable=SC2329
check_true() { if eval "$1"; then ok "$2"; else bad "$3"; fi; }
export -f step check_true
sed -n '/^step "slot: /,/^step "run and share"/p' "$REPO/tests/smoke.sh" | sed '$d' > "$SANDBOX/contender-step.sh"
eval "$(cat "$SANDBOX/contender-step.sh")"
check_eq "$([ -e "$SANDBOX/booted" ] && echo yes || echo no)" no "the denial check cannot boot into a spare host slot"
check_eq "$(cat "$SANDBOX/contender-env")" "$CONTENDER/slot-state:1" "the contender checks a controlled one-slot lock, not host capacity"
check_eq "$(cat "$SANDBOX/acquire" 2>/dev/null)" "$CONTENDER/slot-state:1" "the running smoke consumer holds the controlled slot first"
check_eq "$FLTH_SLOT_COUNT:$FLTH_STATE_DIR" "2:$SANDBOX/state" "the denial check leaves machine-wide slot settings unchanged"

finish smoke-slots
