#!/usr/bin/env bash
#
# smoke-boot-failure.sh — a smoke VM that will not boot ends the smoke run
# with a verdict, at once, rather than booting again (#45).
#
# tests/smoke.sh keeps going after a failed check, which suits checks that
# stand alone. Every step after `up` needs a guest, though, and the
# disposable step boots again: each boot costs up to three attempts of the
# Vagrantfile's 600 s boot timeout, so two failed boots outlast the CI job's
# 60 minutes and the job ends CANCELLED, with no verdict and nothing for
# `Collect results` to upload.
#
# smoke.sh is run here unmodified, from a copy of the harness whose vm.sh,
# vm-slot.sh and host-tools.sh are stubs: `up` fails, every call is logged.
# No VM is involved.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

H="$SANDBOX/harness"
CALLS="$SANDBOX/calls"
mkdir -p "$H/tests/smoke-consumer" "$H/scripts/lib"
cp "$REPO/tests/smoke.sh" "$H/tests/smoke.sh"
cp "$REPO/scripts/lib/common.sh" "$H/scripts/lib/common.sh"
cp "$REPO/tests/smoke-consumer/"* "$H/tests/smoke-consumer/" 2>/dev/null
: > "$CALLS"

cat > "$H/scripts/vm.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1" in
    up)      echo "vm: the VM would not boot after 3 attempts." >&2; exit 1 ;;
    destroy) exit 0 ;;
    config)  echo "machine=$SANDBOX/machine" ;;
    share)   echo "$SANDBOX/share" ;;
    *)       exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho free\n' > "$H/scripts/vm-slot.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/scripts/host-tools.sh"
chmod +x "$H/scripts/vm.sh" "$H/scripts/vm-slot.sh" "$H/scripts/host-tools.sh" "$H/tests/smoke.sh"

out="$("$H/tests/smoke.sh" 2>&1)"
rc=$?

check_eq "$([ "$rc" -ne 0 ] && echo non-zero || echo zero)" non-zero "a smoke run whose VM will not boot fails (exit $rc)"
check_eq "$(grep -c '^up$' "$CALLS" | tr -d ' ')" 1 "it boots once, and does not pay the boot budget a second time"
after_up="$(sed -n '/^up$/,$p' "$CALLS" | sed 1d | grep -v '^destroy$' | paste -sd, -)"
check_eq "$after_up" "" "nothing asks the guest anything after the boot failed"
check_eq "$(tail -n 1 "$CALLS")" destroy "and the VM is destroyed on the way out"
check_true_re() { if printf '%s\n' "$1" | grep -Eq "$2"; then ok "$3"; else bad "$3 (no line matching /$2/ in: $1)"; fi; }
check_true_re "$out" 'smoke: [0-9]+ passed, [1-9][0-9]* failed' "the run still prints its verdict, naming the failure"
check_contains "$out" "vm.sh up succeeds (expected '0', got '1')" "and the failed check is the boot"

finish smoke-boot-failure
