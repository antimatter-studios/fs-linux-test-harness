# shellcheck shell=bash
#
# lib/config.sh — find and read a consumer's fs-linux-test-harness.toml.
#
# Sourced, never executed. It defines functions and sets no options, so
# it is safe to source from a script running with or without `set -e`.
#
# THE FORMAT IS A STRICT SUBSET OF TOML, parsed here in bash so the
# harness needs nothing on the host beyond what it already needs to boot
# a VM. Supported:
#
#   [section]                   one of the sections documented below
#   key = "string"              basic string, no escape sequences
#   key = 'string'              literal string
#   key = 123                   non-negative integer
#   # comment                   whole-line or trailing
#
# Anything else is an ERROR, not something to skip: an unknown section,
# an unknown key, a duplicate, a value of the wrong type. A typo in a
# config file that is silently ignored becomes a default nobody chose,
# and the first symptom is a VM that behaves differently from the one
# the file describes.
#
# Keys, their types and defaults (README.md documents each one):
#
#   [project] name              string, required
#   [vm]      memory            string, default "4G"
#   [vm]      cpus              integer, default 4
#   [vm]      disk              string, default "32G"
#   [vm]      ssh_port          integer, default 50122
#   [vm]      deadline_minutes  integer, default 480
#   [share]   dir               string, default ".vm-share"
#   [setup]   script            string, required
#   [test]    command           string, optional
#
# After `flth_config_load`, each is available as CFG_<section>_<key>,
# and FLTH_ROOT is the absolute path of the directory holding the file.

FLTH_CONFIG_NAME="fs-linux-test-harness.toml"

flth_config_error() {
    echo "fs-linux-test-harness: $*" >&2
    return 1
}

# Print the absolute path of the consumer's config file.
#
# FLTH_CONFIG names it explicitly; otherwise the working directory and
# each parent is searched, the way git finds a repository. A search that
# finds nothing is an error, never a default: a harness run with no
# consumer has nothing to boot a VM for.
flth_find_config() {
    local dir
    if [ -n "${FLTH_CONFIG:-}" ]; then
        [ -f "$FLTH_CONFIG" ] ||
            { flth_config_error "FLTH_CONFIG names $FLTH_CONFIG, which is not a file"; return 1; }
        dir="$(cd "$(dirname "$FLTH_CONFIG")" && pwd -P)" || return 1
        printf '%s/%s\n' "$dir" "$(basename "$FLTH_CONFIG")"
        return 0
    fi
    dir="$(pwd -P)"
    while :; do
        if [ -f "$dir/$FLTH_CONFIG_NAME" ]; then
            printf '%s/%s\n' "$dir" "$FLTH_CONFIG_NAME"
            return 0
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
    flth_config_error "no $FLTH_CONFIG_NAME in $(pwd -P) or any parent." \
        "Run from the consumer repository, or set FLTH_CONFIG."
}

# The type of a known key, or nothing for an unknown one.
flth_config_key_type() {
    case "$1" in
        project.name)        echo string ;;
        vm.memory)           echo string ;;
        vm.cpus)             echo integer ;;
        vm.disk)             echo string ;;
        vm.ssh_port)         echo integer ;;
        vm.deadline_minutes) echo integer ;;
        share.dir)           echo string ;;
        setup.script)        echo string ;;
        test.command)        echo string ;;
        test.guest_command)  echo string ;;
    esac
}

# Load and validate a config file. Returns non-zero, having said why on
# stderr, when the file is not one this harness can act on.
flth_config_load() {
    local file="$1"
    local line lineno=0 section="" key value type seen_sections=" " seen_keys=" "
    local re_section='^\[([a-z_]+)\][[:space:]]*(#.*)?$'
    local re_pair='^([a-z_]+)[[:space:]]*=[[:space:]]*(.*)$'
    local re_basic='^"([^"\\]*)"[[:space:]]*(#.*)?$'
    local re_literal="^'([^']*)'[[:space:]]*(#.*)?\$"
    local re_integer='^(0|[1-9][0-9]*)[[:space:]]*(#.*)?$'

    [ -f "$file" ] || { flth_config_error "$file: no such file"; return 1; }

    # shellcheck disable=SC2034  # read by the scripts that source this
    CFG_project_name=""
    CFG_vm_memory="4G"
    CFG_vm_cpus="4"
    CFG_vm_disk="32G"
    CFG_vm_ssh_port="50122"
    CFG_vm_deadline_minutes="480"
    CFG_share_dir=".vm-share"
    CFG_setup_script=""
    # shellcheck disable=SC2034  # read by vm.sh
    CFG_test_command=""
    # shellcheck disable=SC2034  # read by vm.sh
    CFG_test_guest_command=""

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # Trim both ends. Parameter expansion rather than `sed` or
        # `xargs`: xargs interprets quotes, which are the one thing a
        # value here must keep.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in '' | '#'*) continue ;; esac

        if [[ "$line" =~ $re_section ]]; then
            section="${BASH_REMATCH[1]}"
            case "$section" in
                project | vm | share | setup | test) ;;
                *) flth_config_error "$file:$lineno: unknown section [$section]"; return 1 ;;
            esac
            case "$seen_sections" in
                *" $section "*)
                    flth_config_error "$file:$lineno: section [$section] appears twice"
                    return 1 ;;
            esac
            seen_sections="$seen_sections$section "
            continue
        fi

        if ! [[ "$line" =~ $re_pair ]]; then
            flth_config_error "$file:$lineno: not a section header or a key = value line"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [ -z "$section" ]; then
            flth_config_error "$file:$lineno: '$key' is outside any [section]"
            return 1
        fi
        type="$(flth_config_key_type "$section.$key")"
        if [ -z "$type" ]; then
            flth_config_error "$file:$lineno: unknown key '$key' in [$section]"
            return 1
        fi
        case "$seen_keys" in
            *" $section.$key "*)
                flth_config_error "$file:$lineno: '$section.$key' is set twice"
                return 1 ;;
        esac
        seen_keys="$seen_keys$section.$key "

        if [[ "$value" =~ $re_basic ]] || [[ "$value" =~ $re_literal ]]; then
            [ "$type" = string ] ||
                { flth_config_error "$file:$lineno: '$section.$key' must be an integer, got a string"; return 1; }
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ $re_integer ]]; then
            [ "$type" = integer ] ||
                { flth_config_error "$file:$lineno: '$section.$key' must be a string, got an integer"; return 1; }
            value="${BASH_REMATCH[1]}"
        else
            flth_config_error "$file:$lineno: '$section.$key' has a value this harness does not read" \
                "(quoted string without escapes, or a non-negative integer)"
            return 1
        fi
        printf -v "CFG_${section}_${key}" '%s' "$value"
    done < "$file"

    FLTH_ROOT="$(cd "$(dirname "$file")" && pwd -P)"
    flth_config_validate "$file"
}

flth_config_validate() {
    local file="$1"

    # A hostname label and a slot holder name, so it is held to the
    # stricter of the two.
    [ -n "$CFG_project_name" ] ||
        { flth_config_error "$file: [project] name is required"; return 1; }
    [[ "$CFG_project_name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        { flth_config_error "$file: [project] name must be lowercase letters, digits and inner hyphens, at most 63 characters"; return 1; }

    [[ "$CFG_vm_memory" =~ ^[1-9][0-9]{0,5}[MG]$ ]] ||
        { flth_config_error "$file: [vm] memory must look like 4G or 2048M, got '$CFG_vm_memory'"; return 1; }
    [[ "$CFG_vm_disk" =~ ^[1-9][0-9]{0,4}G$ ]] ||
        { flth_config_error "$file: [vm] disk must look like 32G, got '$CFG_vm_disk'"; return 1; }
    { [ "$CFG_vm_cpus" -ge 1 ] && [ "$CFG_vm_cpus" -le 64 ]; } ||
        { flth_config_error "$file: [vm] cpus must be between 1 and 64, got $CFG_vm_cpus"; return 1; }
    { [ "$CFG_vm_ssh_port" -ge 1024 ] && [ "$CFG_vm_ssh_port" -le 65535 ]; } ||
        { flth_config_error "$file: [vm] ssh_port must be between 1024 and 65535, got $CFG_vm_ssh_port"; return 1; }
    { [ "${#CFG_vm_deadline_minutes}" -le 6 ] && [ "$CFG_vm_deadline_minutes" -ge 1 ]; } ||
        { flth_config_error "$file: [vm] deadline_minutes must be a positive integer of at most six digits, got $CFG_vm_deadline_minutes"; return 1; }

    flth_config_relative_path "$file" "[share] dir" "$CFG_share_dir" || return 1

    [ -n "$CFG_setup_script" ] ||
        { flth_config_error "$file: [setup] script is required: it is how the VM gets the tooling your tests need"; return 1; }
    flth_config_relative_path "$file" "[setup] script" "$CFG_setup_script" || return 1
    [ -f "$FLTH_ROOT/$CFG_setup_script" ] ||
        { flth_config_error "$file: [setup] script names $CFG_setup_script, which is not a file"; return 1; }

    return 0
}

# Paths in the config are relative to the directory holding it, so a
# checkout can move without its config changing — and they stay inside
# it, because the share is created, written and cleaned by the harness.
flth_config_relative_path() {
    local file="$1" what="$2" path="$3"
    case "$path" in
        '')
            flth_config_error "$file: $what must not be empty"; return 1 ;;
        /*)
            flth_config_error "$file: $what must be relative to the repository, got $path"; return 1 ;;
        .. | ../* | */.. | */../*)
            flth_config_error "$file: $what must stay inside the repository, got $path"; return 1 ;;
        *[!A-Za-z0-9._/-]*)
            flth_config_error "$file: $what may use only letters, digits, '.', '_', '-' and '/', got $path"; return 1 ;;
    esac
    return 0
}
