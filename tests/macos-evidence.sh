#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for document in README.md AGENTS.md; do
    # Lines joined, so a fact wrapped across two lines still reads as one.
    content="$(tr '\n' ' ' < "$REPO/$document")"
    check_lacks "$content" "macOS row has never been booted" "$document no longer calls the macOS row unbooted"
    check_lacks "$content" "macOS path has never been" "$document no longer calls the macOS path unbooted"
    check_lacks "$content" "Nobody has yet run" "$document no longer says no Mac has run smoke"
    check_lacks "$content" "Treat the row as untested" "$document no longer calls the observed row untested"
    check_lacks "$content" "No Mac has yet confirmed" "$document no longer calls the direct-I/O fix unconfirmed"
    check_lacks "$content" "no Mac has yet run" "$document no longer says direct-I/O smoke is unrecorded"
    check_lacks "$content" "has not been yet" "$document no longer describes Mac smoke as future evidence"
    # The latest recorded Mac smoke run (#276): 2026-11-20, 250 of 251, only #83 failing.
    for fact in '2026-11-20' 'port release 1.14.0.1' 'vagrant-qemu-christhomas' '0.6.0' 'vagrant-notify-forwarder-christhomas' '0.7.8' 'QEMU 10.2.2' '6.1.0-42-cloud-arm64' '250 of 251' 'O_DIRECT' '#162' '#83' '#83 still fails on some'; do
        check_contains "$content" "$fact" "$document records $fact"
    done
done

finish macos-evidence
