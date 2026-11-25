#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

accel() { bash "$REPO/scripts/qemu-tcg-accel.sh" "$@"; }
evidence="$SANDBOX/evidence"
output="$(accel 2048 2> "$evidence")"
check_eq "$?" 0 "TCG admission accepts an unset host limit"
check_eq "$output" 'tcg,thread=multi,tb-size=128' "TCG emits only the capped QEMU accelerator argument on stdout"
check_contains "$(cat "$evidence")" 'ram_mib=2048 tb_mib=128 overhead_mib=384 total_mib=2560 limit_mib=unset' "TCG evidence itemizes the memory estimate"

output="$(FLTH_TCG_TB_SIZE_MIB=64 FLTH_HOST_MEMORY_LIMIT_MIB=2496 accel 2G 2> "$evidence")"
check_eq "$?" 0 "TCG admission accepts equality with the configured limit"
check_eq "$output" 'tcg,thread=multi,tb-size=64' "a valid environment override reaches QEMU"
check_contains "$(cat "$evidence")" 'ram_mib=2048 tb_mib=64 overhead_mib=384 total_mib=2496 limit_mib=2496' "the override changes the estimate and is reported"

output="$(FLTH_HOST_MEMORY_LIMIT_MIB=2559 accel 2048M 2> "$evidence")"
check_eq "$?" 1 "TCG refuses a limit even one MiB below the estimate"
check_eq "$output" '' "TCG refusal emits no accelerator argument"
check_contains "$(cat "$evidence")" '2560 MiB exceeds FLTH_HOST_MEMORY_LIMIT_MIB=2559' "the TCG refusal names the limit and the estimate"

for invalid in '' 0 064 1G -1 1025; do
    output="$(FLTH_TCG_TB_SIZE_MIB="$invalid" accel 2048 2>&1)"
    check_eq "$?" 1 "invalid TCG cap '$invalid' is refused"
    check_contains "$output" FLTH_TCG_TB_SIZE_MIB "invalid TCG cap '$invalid' names the setting"
done
for invalid in '' 0 02560 2G -1 1000000; do
    output="$(FLTH_HOST_MEMORY_LIMIT_MIB="$invalid" accel 2048 2>&1)"
    check_eq "$?" 1 "invalid host limit '$invalid' is refused"
    check_contains "$output" FLTH_HOST_MEMORY_LIMIT_MIB "invalid host limit '$invalid' names the setting"
done
for invalid in '' 0 02048 2T -1 1000000; do
    output="$(accel "$invalid" 2>&1)"
    check_eq "$?" 1 "invalid guest RAM '$invalid' is refused"
    check_contains "$output" 'guest RAM' "invalid guest RAM '$invalid' names what is wrong"
done
check_contains "$(accel 2048 extra 2>&1)" 'usage:' "the standalone helper refuses extra arguments"

make_stub_harness
consumer="$SANDBOX/consumer"
make_consumer "$consumer" budget
vm() { (cd "$consumer" && "$STUB_HARNESS/scripts/vm.sh" "$@"); }

output="$(FLTH_SHARED_MEMORY=2G FLTH_HOST_MEMORY_LIMIT_MIB=2431 vm up 2>&1)"
check_eq "$?" 1 "native boot refuses a budget below RAM plus overhead"
check_contains "$output" 'ram_mib=2048 tb_mib=0 overhead_mib=384 total_mib=2432 limit_mib=2431' "native boot evidence has no translation cache"
check_eq "$(grep -c '^up$' "$FLTH_TEST_STUB/calls")" 0 "native refusal never calls the engine boot"
output="$(FLTH_SHARED_MEMORY=2G FLTH_HOST_MEMORY_LIMIT_MIB=2432 FLTH_TCG_TB_SIZE_MIB=64 vm up 2>&1)"
check_eq "$?" 0 "native boot accepts equality and ignores TCG tuning"
check_contains "$output" 'ram_mib=2048 tb_mib=0 overhead_mib=384 total_mib=2432 limit_mib=2432' "native success emits the admission evidence"
check_eq "$(grep -c '^up$' "$FLTH_TEST_STUB/calls")" 1 "only the admitted native boot reaches the engine"
vm down > "$SANDBOX/down" 2>&1
check_eq "$?" 0 "the admitted native guest stops"

output="$(FLTH_ACCELERATOR=tcg FLTH_SHARED_MEMORY=2G FLTH_HOST_MEMORY_LIMIT_MIB=2432 vm up 2>&1)"
check_eq "$?" 1 "TCG guest refuses a budget that only covers native boot"
check_contains "$output" 'ram_mib=2048 tb_mib=128 overhead_mib=384 total_mib=2560 limit_mib=2432' "TCG guest includes the translation cache"
check_contains "$(FLTH_ACCELERATOR=tcg vm config)" 'machines/shared-debian-12-tcg' "TCG selects its own shared guest state"

finish qemu-memory
