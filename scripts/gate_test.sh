#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# gate_test.sh — unit tests for scripts/gate.sh. Sources gate.sh (which does NOT run main
# when sourced) and exercises the directive parsing/normalisation and the base-url /
# config-path validators — the safety-critical, network-free logic of the gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Behavioural guard check (the guard at the bottom of gate.sh is what stops main from
# running when we source it). Sourcing in a child shell must reach the sentinel — if the
# guard is removed/broken, main runs and aborts under `set -u` before the sentinel prints.
# This is robust to cosmetic refactors of the guard line (unlike a literal grep).
if [ "$(bash -c "source '${SCRIPT_DIR}/gate.sh'; echo GUARD_OK" 2>/dev/null)" != "GUARD_OK" ]; then
  echo "FAIL - sourcing gate.sh ran main() (the 'run only when executed directly' guard is missing/broken)" >&2
  exit 1
fi

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

# ok_status <fn> <arg...> — run a validator, swallowing its stderr, print accept/reject.
ok_status() { local fn="$1"; shift; if "${fn}" "$@" 2>/dev/null; then echo accept; else echo reject; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- directive parsing (parse_directive_file: extract + normalise from a headers file) ---
printf 'HTTP/2 200\r\nContent-Type: application/yaml\r\n\r\n'  > "${tmp}/none"
printf 'HTTP/2 200\r\nx-agp-directive: run\r\n\r\n'            > "${tmp}/run"
printf 'HTTP/2 200\r\nx-agp-directive: paused\r\n\r\n'         > "${tmp}/paused"
printf 'HTTP/2 200\r\nx-agp-directive:paused\r\n\r\n'          > "${tmp}/nospace"
printf 'HTTP/2 200\r\nx-agp-directive: paused \r\n\r\n'        > "${tmp}/trailing"
printf 'HTTP/2 200\r\nX-AGP-Directive: RUN\r\n\r\n'            > "${tmp}/upper"
printf 'HTTP/2 200\r\nx-agp-directive: maybe\r\n\r\n'          > "${tmp}/unknown"
printf 'HTTP/2 200\r\nx-agp-directive:\r\n\r\n'                > "${tmp}/empty"
printf 'HTTP/2 200\r\nx-agp-directive: run\r\nx-agp-directive: paused\r\n\r\n' > "${tmp}/dup"

check "absent header -> run (active default)" "run"    "$(parse_directive_file "${tmp}/none")"
check "explicit run -> run"                   "run"    "$(parse_directive_file "${tmp}/run")"
check "explicit paused -> paused"             "paused" "$(parse_directive_file "${tmp}/paused")"
check "paused without space after colon"      "paused" "$(parse_directive_file "${tmp}/nospace")"
check "paused with trailing whitespace"       "paused" "$(parse_directive_file "${tmp}/trailing")"
check "uppercase RUN -> run"                  "run"    "$(parse_directive_file "${tmp}/upper")"
check "unknown value -> paused (fail-closed)" "paused" "$(parse_directive_file "${tmp}/unknown")"
check "empty value -> paused (fail-closed)"   "paused" "$(parse_directive_file "${tmp}/empty")"
check "duplicate headers -> paused (ambig.)"  "paused" "$(parse_directive_file "${tmp}/dup")"

# parse_directive_file must fail-closed (non-zero) on a missing/unreadable headers file.
check "missing headers file rejected"         "reject" "$(if parse_directive_file "${tmp}/does-not-exist" >/dev/null 2>&1; then echo accept; else echo reject; fi)"

# normalize_directive decision logic (count-driven), independent of any file.
check "normalize count=0 -> run"              "run"    "$(normalize_directive 0 '')"
check "normalize count>1 -> paused"           "paused" "$(normalize_directive 2 'run')"
check "normalize single unknown -> paused"    "paused" "$(normalize_directive 1 'quarantine')"

# --- HTTPS-only / safe-host refusal (guards against leaking the OIDC bearer token) ---
check "https host accepted"                   "accept" "$(ok_status validate_base_url 'https://api.guide.sonatype.com')"
check "https host with port accepted"         "accept" "$(ok_status validate_base_url 'https://api.guide.sonatype.com:8443/x')"
check "http rejected"                         "reject" "$(ok_status validate_base_url 'http://api.guide.sonatype.com')"
check "non-http scheme rejected"              "reject" "$(ok_status validate_base_url 'ftp://evil.example')"
check "empty base url rejected"               "reject" "$(ok_status validate_base_url '')"
check "userinfo host rejected"                "reject" "$(ok_status validate_base_url 'https://user:pass@evil.example')"
check "empty-authority https:// rejected"     "reject" "$(ok_status validate_base_url 'https://')"
check "triple-slash empty host rejected"      "reject" "$(ok_status validate_base_url 'https:///some/path')"
check "whitespace in host rejected"           "reject" "$(ok_status validate_base_url 'https:// evil.example')"

# --- config-path traversal / absolute-path rejection (segment-based) ---
check "relative config-path accepted"         "accept" "$(ok_status validate_config_path 'agp.yml')"
check "nested relative path accepted"         "accept" "$(ok_status validate_config_path 'sub/dir/agp.yml')"
check "filename containing .. accepted"       "accept" "$(ok_status validate_config_path 'agp..yml')"
check "dotted dir name accepted"              "accept" "$(ok_status validate_config_path 'v1.0..draft/agp.yml')"
check "absolute config-path rejected"         "reject" "$(ok_status validate_config_path '/etc/passwd')"
check "leading parent traversal rejected"     "reject" "$(ok_status validate_config_path '../../escape.yml')"
check "embedded parent traversal rejected"    "reject" "$(ok_status validate_config_path 'foo/../etc/passwd')"
check "empty config-path rejected"            "reject" "$(ok_status validate_config_path '')"

# --- workspace-containment guard (is_inside_workspace: pure string containment) ---
check "path inside workspace accepted"        "accept" "$(ok_status is_inside_workspace '/w/repo/agp.yml' '/w/repo')"
check "workspace root itself accepted"        "accept" "$(ok_status is_inside_workspace '/w/repo' '/w/repo')"
check "trailing-slash root accepted"          "accept" "$(ok_status is_inside_workspace '/w/repo/x' '/w/repo/')"
check "sibling-prefix path rejected"          "reject" "$(ok_status is_inside_workspace '/w/repo-evil/x' '/w/repo')"
check "absolute escape rejected"              "reject" "$(ok_status is_inside_workspace '/etc/passwd' '/w/repo')"
check "empty workspace root rejected"         "reject" "$(ok_status is_inside_workspace '/w/repo/x' '')"
check "empty resolved path rejected"          "reject" "$(ok_status is_inside_workspace '' '/w/repo')"
check "root-of-/ rejected (no match-all)"     "reject" "$(ok_status is_inside_workspace '/etc/passwd' '/')"

# --- log sanitiser defangs control chars and '::' workflow-command markers ---
check "sanitize strips :: command marker"     "__set-output__" "$(printf '::set-output::' | sanitize_for_log)"
check "sanitize strips control chars"         "ab"             "$(printf 'a\tb\r' | sanitize_for_log)"

# --- audience default must not drift between the manifest and the mint helper ---
audience_in_sync() {
  grep -Fq 'default: "https://guide.sonatype.com"' "${SCRIPT_DIR}/../gate/action.yml" \
    && grep -Fq 'DEFAULT_GUIDE_AUDIENCE="https://guide.sonatype.com"' "${SCRIPT_DIR}/mint-oidc-token.sh"
}
check "audience default in sync"              "insync" "$(if audience_in_sync; then echo insync; else echo drift; fi)"

# NOTE: the fail-closed http_code != 200 branch, the curl 000 fallback, the realpath
# resolution, and the atomic stage->move in main() depend on a real (or mocked) HTTP
# round-trip / filesystem and are exercised end-to-end when the action runs, not here.
# is_inside_workspace (the decision the containment check turns on) is unit-tested above.

if [ "${fail}" -ne 0 ]; then
  echo "gate_test: FAILURES"
  exit 1
fi
echo "gate_test: all passed"
