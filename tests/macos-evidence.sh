#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for document in README.md AGENTS.md; do
    content="$(cat "$REPO/$document")"
    check_lacks "$content" "macOS row has never been booted" "$document no longer calls the macOS row unbooted"
    check_lacks "$content" "macOS path has never been" "$document no longer calls the macOS path unbooted"
    check_lacks "$content" "Nobody has yet run" "$document no longer says no Mac has run smoke"
    check_lacks "$content" "Treat the row as untested" "$document no longer calls the observed row untested"
    check_lacks "$content" "No Mac has yet confirmed" "$document no longer calls the direct-I/O fix unconfirmed"
    check_lacks "$content" "no Mac has yet run" "$document no longer says direct-I/O smoke is unrecorded"
    check_lacks "$content" "has not been yet" "$document no longer describes Mac smoke as future evidence"
    for fact in '2026-11-03' 'virtiofsd 1.14.0' 'vagrant-qemu-christhomas' '0.6.0' 'vagrant-notify-forwarder-christhomas' '0.7.5' 'two of three' '95 checks' 'O_DIRECT' '#83' '#84' '#86'; do
        check_contains "$content" "$fact" "$document records $fact"
    done
done

finish macos-evidence
