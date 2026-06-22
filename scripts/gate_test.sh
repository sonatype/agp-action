#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# gate_test.sh — unit tests for the gate directive parsing in scripts/gate.sh.
# Sources gate.sh (which does NOT run main when sourced) and exercises the
# header-extraction + normalisation logic that previously aborted under
# `set -euo pipefail` when the x-agp-directive header was absent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gate.sh
source "${SCRIPT_DIR}/gate.sh"

fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "ok   - ${desc} (=> ${actual})"
  else
    echo "FAIL - ${desc}: expected '${expected}', got '${actual}'"
    fail=1
  fi
}

# directive() runs the full extract + normalise path against a fixture headers file.
directive() { normalize_directive "$(extract_directive_header "$1")"; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

printf 'HTTP/2 200\r\nContent-Type: application/yaml\r\n\r\n' > "${tmp}/none"
printf 'HTTP/2 200\r\nx-agp-directive: paused\r\n\r\n'        > "${tmp}/paused"
printf 'HTTP/2 200\r\nx-agp-directive:paused\r\n\r\n'         > "${tmp}/nospace"
printf 'HTTP/2 200\r\nX-AGP-Directive: RUN\r\n\r\n'           > "${tmp}/upper"
printf 'HTTP/2 200\r\nx-agp-directive: maybe\r\n\r\n'         > "${tmp}/unknown"

check "absent header defaults to run"     "run"    "$(directive "${tmp}/none")"
check "explicit paused"                   "paused" "$(directive "${tmp}/paused")"
check "paused without space after colon"  "paused" "$(directive "${tmp}/nospace")"
check "uppercase RUN normalises to run"   "run"    "$(directive "${tmp}/upper")"
check "unknown value normalises to run"   "run"    "$(directive "${tmp}/unknown")"
check "empty input defaults to run"       "run"    "$(normalize_directive "")"

if [ "${fail}" -ne 0 ]; then
  echo "gate_test: FAILURES"
  exit 1
fi
echo "gate_test: all passed"
