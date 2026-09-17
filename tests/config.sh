#!/usr/bin/env bash
#
# config.sh — fs-linux-test-harness.toml: what is read, what is refused,
# and how the file is found.
#
# A refusal is only worth something if it says WHICH line and WHY, so
# every rejection below is checked for its message, not only its exit
# status.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
new_sandbox
. "$REPO/scripts/lib/config.sh"

# load <toml text> — write a consumer with that config; capture stderr in
# $err and the status in $rc.
load() {
    local dir="$SANDBOX/c$RANDOM$RANDOM"
    mkdir -p "$dir"
    printf '%s\n' "$1" > "$dir/fs-linux-test-harness.toml"
    printf 'true\n' > "$dir/setup.sh"
    err="$( (flth_config_load "$dir/fs-linux-test-harness.toml" && vm_dump) 2>&1 >"$SANDBOX/out")"
    rc=$?
    out="$(cat "$SANDBOX/out")"
}
vm_dump() {
    printf '%s|' "$CFG_project_name" "$CFG_vm_memory" "$CFG_vm_cpus" "$CFG_vm_disk" \
        "$CFG_vm_ssh_port" "$CFG_vm_deadline_minutes" "$CFG_share_dir" "$CFG_setup_script" "$CFG_test_command"
}

MIN='[project]
name = "rust-fs-demo"
[setup]
script = "setup.sh"'

# --- what is read -----------------------------------------------------

load "$MIN"
check_eq "$rc" 0 "a minimal config loads"
check_eq "$out" "rust-fs-demo|4G|4|32G|50122|480|.vm-share|setup.sh||" "and every optional key takes its documented default"

load '# a comment line
[project]   # trailing comment on a header
name = '"'"'lit-name'"'"'   # a literal string
[vm]
memory = "2048M"
cpus = 2
disk = "16G"
ssh_port = 50200
deadline_minutes = 90
[share]
dir = "build/share"
[setup]
script = "setup.sh"
[test]
command = "./suite.sh --fast"'
check_eq "$rc" 0 "every key, comments, a literal string and a bare integer load"
check_eq "$out" "lit-name|2048M|2|16G|50200|90|build/share|setup.sh|./suite.sh --fast|" "and each value lands where it should"

for example in "$REPO/examples/minimal" "$REPO/tests/smoke-consumer"; do
    err="$(flth_config_load "$example/fs-linux-test-harness.toml" 2>&1)"
    check_eq "$?" 0 "the shipped config in ${example#"$REPO/"} is valid"
done

# --- what is refused ----------------------------------------------------

refuse() {
    # refuse <what> <message fragment> <toml>
    load "$3"
    if [ "$rc" -eq 0 ]; then
        bad "$1 is refused (it loaded)"
    else
        check_contains "$err" "$2" "$1 is refused, saying why"
    fi
}

refuse "an unknown key" "unknown key 'memroy' in [vm]" "$MIN
[vm]
memroy = \"4G\""
refuse "an unknown section" "unknown section [vms]" "$MIN
[vms]"
refuse "a key outside any section" "'name' is outside any [section]" 'name = "x"'
refuse "a key set twice" "'project.name' is set twice" '[project]
name = "a"
name = "b"'

refuse "a section repeated" "section [setup] appears twice" "$MIN
[setup]"
refuse "a string where an integer belongs" "'vm.cpus' must be an integer, got a string" "$MIN
[vm]
cpus = \"4\""
refuse "an integer where a string belongs" "'vm.memory' must be a string, got an integer" "$MIN
[vm]
memory = 4"
refuse "a value this parser does not read (escapes)" "has a value this harness does not read" "$MIN
[test]
command = \"echo \\\"hi\\\"\""
refuse "a boolean" "has a value this harness does not read" "$MIN
[test]
command = true"
refuse "the line number is given" ":6:" "$MIN
[vm]
cpus = \"x\""
refuse "a missing project name" "[project] name is required" '[setup]
script = "setup.sh"'
refuse "a missing setup script" "[setup] script is required" '[project]
name = "x"'
refuse "a setup script that is not a file" "names nope.sh, which is not a file" '[project]
name = "x"
[setup]
script = "nope.sh"'
refuse "a project name that is not a hostname label" "[project] name must be lowercase" '[project]
name = "Rust_FS"
[setup]
script = "setup.sh"'
refuse "a malformed memory size" "[vm] memory must look like" "$MIN
[vm]
memory = \"4 GB\""
refuse "a malformed disk size" "[vm] disk must look like" "$MIN
[vm]
disk = \"32\""
refuse "zero cpus" "[vm] cpus must be between 1 and 64" "$MIN
[vm]
cpus = 0"
refuse "a privileged ssh port" "[vm] ssh_port must be between 1024 and 65535" "$MIN
[vm]
ssh_port = 22"
refuse "a zero deadline" "deadline_minutes must be a positive integer" "$MIN
[vm]
deadline_minutes = 0"
refuse "a share path escaping the repository" "[share] dir must stay inside the repository" "$MIN
[share]
dir = \"../elsewhere\""
refuse "an absolute share path" "[share] dir must be relative to the repository" "$MIN
[share]
dir = \"/tmp/share\""
refuse "a setup path escaping through a middle .." "must stay inside the repository" '[project]
name = "x"
[setup]
script = "scripts/../../setup.sh"'
refuse "a path with shell metacharacters" "may use only letters" "$MIN
[share]
dir = \"share;rm\""

# --- how the file is found ----------------------------------------------

make_consumer "$SANDBOX/repo" found-me
mkdir -p "$SANDBOX/repo/deep/er"
got="$(cd "$SANDBOX/repo/deep/er" && flth_find_config)"
check_eq "$got" "$(cd "$SANDBOX/repo" && pwd -P)/fs-linux-test-harness.toml" "found from a subdirectory by walking up"

got="$(cd / && FLTH_CONFIG="$SANDBOX/repo/fs-linux-test-harness.toml" flth_find_config)"
check_eq "$got" "$(cd "$SANDBOX/repo" && pwd -P)/fs-linux-test-harness.toml" "FLTH_CONFIG names it from anywhere"

mkdir -p "$SANDBOX/nowhere"
err="$(cd "$SANDBOX/nowhere" && flth_find_config 2>&1)"
check_eq "$?" 1 "no config anywhere is an error, not a default"
check_contains "$err" "no fs-linux-test-harness.toml in" "and says what it looked for"

err="$(FLTH_CONFIG="$SANDBOX/missing.toml" flth_find_config 2>&1)"
check_contains "$err" "which is not a file" "a FLTH_CONFIG naming nothing is refused"

finish config
