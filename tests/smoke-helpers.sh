#!/usr/bin/env bash
#
# smoke-helpers.sh — every command smoke.sh calls exists, without booting.
#
# smoke.sh runs without `set -e`, so a call to a helper it never defines
# prints "command not found" and moves on: the check it was meant to make
# neither passes nor fails, it simply does not count (#47). smoke.sh only
# runs where a VM can boot, so this reads it as text here instead: each word
# in command position must be a function smoke.sh defines, a shell keyword
# or builtin, or a program on PATH.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox

# undefined <script> — one line per command word nothing would answer.
undefined() {
    local script="$1" word kind
    sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)\([[:space:]].*\)\{0,1\}$/\1/p' "$script" \
        | sort -u \
        | while read -r word; do
            grep -Eq "^[[:space:]]*${word}[[:space:]]*\(\)" "$script" && continue
            # A clean shell, so the helpers lib.sh defines here cannot answer.
            kind="$(env -i PATH="$PATH" bash --norc --noprofile -c 'type -t "$1"' _ "$word" 2>/dev/null)"
            case "$kind" in keyword|builtin|file) continue ;; esac
            echo "$word"
        done
}

cat > "$SANDBOX/good.sh" <<'EOF'
check_eq() { :; }
check_eq "$x" y "a defined helper"
if true; then echo fine; fi
EOF
check_eq "$(undefined "$SANDBOX/good.sh")" "" \
    "a script calling only defined helpers, builtins and programs passes, so the refusal below is the call's"

cat > "$SANDBOX/bad.sh" <<'EOF'
check_eq() { :; }
check_eq "$x" y "a defined helper"
check_missing "$x" y "a helper nobody defined"
EOF
check_eq "$(undefined "$SANDBOX/bad.sh")" check_missing "a call to an undefined helper is named"

check_eq "$(undefined "$REPO/tests/smoke.sh")" "" "smoke.sh calls no command that is undefined"

finish smoke-helpers
