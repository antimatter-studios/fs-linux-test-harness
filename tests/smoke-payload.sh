#!/usr/bin/env bash
#
# smoke-payload.sh — the smoke consumer refuses an empty or short payload, and
# says which file was wrong.
#
# The smoke consumer's corrupted run must fail, and it must fail because the
# flipped byte was found. An empty payload.bin gets past that. `debugfs bmap`
# has no data block to give, so the flip lands on byte 0 of the image rather
# than in file data, and two empty files compare equal. On a Mac that passed
# `vm.sh test corrupt` (#84), with dumped.bin at 0 bytes and a corruption.txt
# naming block 0.
#
# Both halves run here without a VM. suite.sh runs on the host against a stub
# vm.sh. guest-suite.sh runs with its guest paths rewritten into the sandbox and
# stand-ins for mkfs.ext4, debugfs and e2fsck, which keep the file's bytes in the
# image, so a flipped byte really is found. tests/smoke.sh runs the same scripts
# with the real tools in a real guest.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

CONSUMER="$REPO/tests/smoke-consumer"
SIZE=1048576
STUBS="$SANDBOX/stubs"
mkdir -p "$STUBS"

# --- suite.sh, on the host ---------------------------------------------------

# A stub vm.sh: `put` copies, and `run` runs the scenario in $FLTH_TEST_GUEST.
cat > "$STUBS/vm" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    put) cp "$2" "$FLTH_SHARE_HOST/"; echo "/share/$(basename "$2")" ;;
    run) echo run >> "$FLTH_TEST_CALLS"; bash "$FLTH_TEST_GUEST" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$STUBS/vm"

# What every guest scenario hands back: results with an ext4 magic at byte 1080.
cat > "$STUBS/results.sh" <<'STUB'
results="$FLTH_SHARE_HOST/results"
mkdir -p "$results"
dd if=/dev/zero of="$results/fs.img" bs=1024 count=2 status=none
printf '\123\357' | dd of="$results/fs.img" bs=1 seek=1080 conv=notrunc status=none
printf 'hello from the host\n' > "$results/hello.txt"
echo pass > "$results/verdict"
STUB

# run_suite <scenario body> — sets suite_rc, suite_out and suite_runs.
run_suite() {
    local share="$SANDBOX/host-share"
    mkdir -p "$share"
    { printf '. %q\n' "$STUBS/results.sh"; printf '%s\n' "$1"; } > "$STUBS/guest-scenario.sh"
    : > "$STUBS/calls"
    suite_rc=0
    suite_out="$(FLTH_SHARE_HOST="$share" FLTH_VM="$STUBS/vm" FLTH_TEST_GUEST="$STUBS/guest-scenario.sh" \
        FLTH_TEST_CALLS="$STUBS/calls" "$CONSUMER/suite.sh" pass 2>&1)" || suite_rc=$?
    suite_runs="$(wc -l < "$STUBS/calls" | tr -d ' ')"
}

# A control: without it, every refusal below could be the suite refusing everything.
run_suite 'cp "$FLTH_SHARE_HOST/payload/payload.bin" "$results/dumped.bin"'
check_eq "$suite_rc" 0 "suite.sh passes a payload that came back whole"
check_contains "$suite_out" "suite: pass" "  and says so"

# The run in #84: the payload is empty on the host by the time the guest has
# finished, the guest read it empty, and the two empty files compare equal.
run_suite ': > "$FLTH_SHARE_HOST/payload/payload.bin"; : > "$results/dumped.bin"'
check_eq "$([ "$suite_rc" -ne 0 ] && echo refused || echo passed)" refused \
    "suite.sh refuses a payload that is empty after the guest has run, though the empty copies compare equal"
check_contains "$suite_out" "payload.bin is 0 bytes" "  naming the file and its size"
check_contains "$suite_out" "expected $SIZE" "  and the size it staged"
check_lacks "$suite_out" "suite: pass" "  and does not call it a pass"

# The payload survived on the host, and what came back is empty.
run_suite ': > "$results/dumped.bin"'
check_eq "$([ "$suite_rc" -ne 0 ] && echo refused || echo passed)" refused "suite.sh refuses an empty read-back"
check_contains "$suite_out" "dumped.bin is 0 bytes" "  naming the file and its size"

# The file was already wrong when it was staged, so no guest is asked anything.
printf '#!/bin/sh\nexit 0\n' > "$STUBS/head"
chmod +x "$STUBS/head"
PATH="$STUBS:$PATH" run_suite 'cp "$FLTH_SHARE_HOST/payload/payload.bin" "$results/dumped.bin"'
rm -f "$STUBS/head"
check_eq "$([ "$suite_rc" -ne 0 ] && echo refused || echo passed)" refused "suite.sh refuses a payload that staged empty"
check_contains "$suite_out" "payload.bin is 0 bytes" "  naming the file and its size"
check_eq "$suite_runs" 0 "  before it asks the guest anything"

# --- guest-suite.sh, with its paths in the sandbox -----------------------------

BOX="$SANDBOX/box"
mkdir -p "$BOX/share" "$BOX/var/tmp" "$BOX/bin"
sed -e "s|/share|$BOX/share|g" -e "s|/var/tmp|$BOX/var/tmp|g" "$CONSUMER/guest-suite.sh" > "$BOX/guest-suite.sh"

# Stand-ins that keep the file's bytes in the image, at block 3, as ext4 keeps
# them in a data block. An empty file has no block: bmap answers 0, as debugfs does.
cat > "$BOX/bin/mkfs.ext4" <<'STUB'
#!/usr/bin/env bash
# mkfs.ext4 -q -F -b 4096 -d <dir> <image>
dir="$6"; img="$7"
dd if="$dir/payload.bin" of="$img" bs=4096 seek=3 conv=notrunc status=none
wc -c < "$dir/payload.bin" | tr -d ' ' > "$img.size"
cp "$dir/dir/hello.txt" "$img.hello"
STUB
cat > "$BOX/bin/debugfs" <<'STUB'
#!/usr/bin/env bash
# debugfs -R "<request>" <image>
set -- $2 "$3"
case "$1" in
    bmap)
        [ "$(cat "$4.size")" -gt 0 ] && echo 3 || echo 0
        ;;
    dump)
        img="$4"
        if [ -n "${FLTH_TEST_DUMP_EMPTY:-}" ]; then
            : > "$3"
        else
            dd if="$img" of="$3" bs=4096 skip=3 count=$(( ($(cat "$img.size") + 4095) / 4096 )) status=none
            truncate -s "$(cat "$img.size")" "$3"
        fi
        ;;
    cat)
        cat "$3.hello"
        ;;
esac
STUB
printf '#!/bin/sh\necho "Pass 5: Checking group summary information"\n' > "$BOX/bin/e2fsck"
chmod +x "$BOX/bin/"*

# run_guest <mode> <payload bytes> — sets guest_rc, guest_out and verdict.
run_guest() {
    local mode="$1" bytes="$2"
    rm -rf "${BOX:?}/share/payload" "${BOX:?}/share/results"
    mkdir -p "$BOX/share/payload/dir"
    if [ "$bytes" -gt 0 ]; then
        head -c "$bytes" /dev/urandom > "$BOX/share/payload/payload.bin"
    else
        : > "$BOX/share/payload/payload.bin"
    fi
    printf 'hello from the host\n' > "$BOX/share/payload/dir/hello.txt"
    guest_rc=0
    guest_out="$(PATH="$BOX/bin:$PATH" bash "$BOX/guest-suite.sh" "$mode" 2>&1)" || guest_rc=$?
    verdict="$(cat "$BOX/share/results/verdict" 2>/dev/null || echo none)"
}

# Controls: the stand-ins must let a good run pass and find a flipped byte.
run_guest pass "$SIZE"
check_eq "$guest_rc|$verdict" "0|pass" "guest-suite.sh passes a whole payload"
run_guest corrupt "$SIZE"
check_eq "$guest_rc|$verdict" "1|fail" "guest-suite.sh fails a corrupted image"
check_contains "$(cat "$BOX/share/results/cmp.log" 2>/dev/null)" differ "  because the content check found the flipped byte"

# The run in #84: a corrupted run over an empty payload.
run_guest corrupt 0
check_eq "$([ "$guest_rc" -ne 0 ] && echo refused || echo passed)" refused \
    "guest-suite.sh fails a corrupted run whose payload is empty"
check_eq "$verdict" fail "  with the verdict on the share saying so"
check_contains "$guest_out" "payload.bin is 0 bytes" "  naming the file and its size"
check_contains "$guest_out" "expected $SIZE" "  and the size it should have"
check_eq "$([ -e "$BOX/share/results/corruption.txt" ] && echo flipped || echo untouched)" untouched \
    "  before it flips a byte that is not in the file"

run_guest pass 0
check_eq "$guest_rc|$verdict" "1|fail" "guest-suite.sh fails a passing run whose payload is empty"
check_contains "$guest_out" "payload.bin is 0 bytes" "  naming the file and its size"

run_guest pass 4096
check_eq "$guest_rc|$verdict" "1|fail" "guest-suite.sh fails a payload that arrives short"
check_contains "$guest_out" "payload.bin is 4096 bytes" "  naming the file and its size"

FLTH_TEST_DUMP_EMPTY=1 run_guest pass "$SIZE"
check_eq "$guest_rc|$verdict" "1|fail" "guest-suite.sh fails an empty read-back"
check_contains "$guest_out" "dumped.bin is 0 bytes" "  naming the file and its size"

finish smoke-payload
