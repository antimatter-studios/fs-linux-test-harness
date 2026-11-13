# shellcheck shell=bash
# shellcheck disable=SC2034  # check_true evaluates expressions; cleanup reads profile state
# Sourced by smoke.sh. Two prepared environments use the same box kernel and
# run at once. The guest boot IDs, process liveness and sysctl are the oracles.
step "run profiles: two environments run side by side without changing the kernel"
for profile_consumer in one two; do
    profile_limit=65536
    [ "$profile_consumer" != two ] || profile_limit=131072
    printf 'set -eu\nprintf "%%s\\n" %s > /etc/flth-profile-flavor\nprintf "fs.aio-max-nr = %s\\n" > /etc/sysctl.d/99-flth-profile.conf\n' \
        "$profile_consumer" "$profile_limit" > "$profile_catalog/tools-$profile_consumer.sh"
    profile_checksum="$(ruby -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$profile_catalog/tools-$profile_consumer.sh")"
    printf '[profile]\nguest = "debian-12"\nsetup = "tools-%s.sh"\nsetup_sha256 = "%s"\n' \
        "$profile_consumer" "$profile_checksum" > "$profile_catalog/tools-$profile_consumer.toml"
    printf '[project]\nname = "profile-%s"\n[setup]\nscript = "setup.sh"\n[vm]\nprofile = "tools-%s"\n' \
        "$profile_consumer" "$profile_consumer" > "$CONTENDER/profile-$profile_consumer/fs-linux-test-harness.toml"
done
profile_active=1
# Prepare serially, then run both guests together. Neither needs a kernel package.
if ! profile_vm one up || ! profile_vm two up; then
    bad "both preparation-only profiles must boot"
    verdict
    exit 1
fi
profile_boot_one="$(profile_vm one exec 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"
profile_boot_two="$(profile_vm two exec 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"
check_true '[ -n "$profile_boot_one" ] && [ -n "$profile_boot_two" ] && [ "$profile_boot_one" != "$profile_boot_two" ]' \
    "different preparations have different live VM boot IDs" "both environments did not get independent live guests"
check_eq "$(profile_vm one exec 'uname -r' 2>/dev/null)" "$(profile_vm two exec 'uname -r' 2>/dev/null)" \
    "separate environments retain the same box kernel"
check_eq "$(profile_vm one exec 'cat /etc/flth-profile-flavor; sysctl -n fs.aio-max-nr' 2>/dev/null | paste -sd, -)" one,65536 \
    "the first guest keeps its own persistent preparation and system setting"
check_eq "$(profile_vm two exec 'cat /etc/flth-profile-flavor; sysctl -n fs.aio-max-nr' 2>/dev/null | paste -sd, -)" two,131072 \
    "the second guest keeps a different preparation and system setting"
profile_suite='set -eu; test "$(cat /etc/flth-profile-flavor)" = "$(cat /repo/name)"; echo $$ > /share/ready; n=0; while [ ! -e /share/release ] && [ "$n" -lt 180 ]; do sleep 1; n=$((n + 1)); done; test -e /share/release'
profile_vm one session "$VM" exec "$profile_suite" > "$CONTENDER/profile-one.log" 2>&1 &
profile_pid_one=$!
profile_vm two session "$VM" exec "$profile_suite" > "$CONTENDER/profile-two.log" 2>&1 &
profile_pid_two=$!
profile_pids="$profile_pid_one $profile_pid_two"
profile_tries=0
until [ -s "$CONTENDER/profile-one/.vm-share/ready" ] && [ -s "$CONTENDER/profile-two/.vm-share/ready" ] || [ "$profile_tries" -ge 120 ]; do
    sleep 1
    profile_tries=$((profile_tries + 1))
done
check_true '[ -s "$CONTENDER/profile-one/.vm-share/ready" ] && [ -s "$CONTENDER/profile-two/.vm-share/ready" ] && kill -0 "$profile_pid_one" && kill -0 "$profile_pid_two"' \
    "both profile suites execute at the same time" "the two profile suites did not overlap"
: > "$CONTENDER/profile-one/.vm-share/release"
wait "$profile_pid_one"
check_eq "$?" 0 "the first profile's suite finishes successfully"
profile_pids="$profile_pid_two"
profile_vm one down
check_eq "$?" 0 "the first profile stops while the other suite is live"
check_eq "$(profile_vm two exec 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" "$profile_boot_two" \
    "stopping one profile keeps the other's boot ID"
check_eq "$(profile_vm two exec 'sysctl -n fs.aio-max-nr' 2>/dev/null)" 131072 \
    "stopping one profile leaves the other's system setting intact"
check_true 'kill -0 "$profile_pid_two"' "the second suite stays alive after the first VM stops" "the second suite was stopped with the first VM"
: > "$CONTENDER/profile-two/.vm-share/release"
wait "$profile_pid_two"
check_eq "$?" 0 "the second profile's suite finishes successfully"
profile_pids=""
for profile_consumer in one two; do
    profile_vm "$profile_consumer" destroy
    check_eq "$?" 0 "the $profile_consumer environment is destroyed independently"
done
profile_active=0
