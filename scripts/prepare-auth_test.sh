#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# prepare-auth_test.sh — unit tests for the classified-error parsing block in
# scripts/prepare-auth.sh. prepare-auth.sh runs top-level side effects on source (curl calls,
# stdin reads, exit), so instead of sourcing it we extract the classification block into a
# helper and drive it with fixtures. The helper's contract must stay in lock-step with the
# corresponding block in prepare-auth.sh — a drift check below asserts that.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "PASS - ${desc}"
  else
    echo "FAIL - ${desc}"
    echo "  expected: [${expected}]"
    echo "  actual:   [${actual}]"
    fail=1
  fi
}

# Emit the error text a broker-error response would produce, given a response body file.
# Mirrors the classified-error branch in prepare-auth.sh (lines that extract .message /
# .upstreamStatus and echo the ::error:: annotation or the fallback Response: line).
classify_broker_error() {
  local resp_body="$1"
  local classified_msg upstream_status
  classified_msg=$(jq -r '.message // empty' "${resp_body}" 2>/dev/null || true)
  upstream_status=$(jq -r '.upstreamStatus // empty' "${resp_body}" 2>/dev/null || true)
  if [ -n "${classified_msg}" ]; then
    printf '::error::%s%s\n' \
      "${classified_msg}" \
      "${upstream_status:+ (GitHub upstream status: ${upstream_status})}"
  else
    printf 'Response: %s\n' "$(cat "${resp_body}")"
  fi
}

run_fixture() {
  local body="$1"
  local tmp
  tmp=$(mktemp)
  printf '%s' "${body}" >"${tmp}"
  classify_broker_error "${tmp}"
  rm -f "${tmp}"
}

# --- Classified JSON with both fields -> single ::error:: with parenthesised status ---
check "full classified body renders one ::error:: with status" \
  "::error::GitHub rejected the token request: this repository is not included in the Sonatype Guide App installation. (GitHub upstream status: 404)" \
  "$(run_fixture '{"success":false,"code":"GITHUB_UPSTREAM_REPO_NOT_SELECTED","message":"GitHub rejected the token request: this repository is not included in the Sonatype Guide App installation.","upstreamStatus":404}')"

# --- Classified JSON without upstreamStatus (transport-error branch) ---
# Guards the reviewer-flagged bug where the `@tsv`/`cut` indirection printed the message
# text as the upstream status when `upstreamStatus` was absent.
check "classified body without upstreamStatus omits the status suffix" \
  "::error::The Sonatype Guide broker could not reach GitHub." \
  "$(run_fixture '{"success":false,"code":"GITHUB_UPSTREAM_TRANSPORT_ERROR","message":"The Sonatype Guide broker could not reach GitHub."}')"

# --- JSON with only .upstreamStatus (no .message) -> fall through to raw body ---
check "JSON with only upstreamStatus falls through to Response:" \
  "Response: {\"upstreamStatus\":500}" \
  "$(run_fixture '{"upstreamStatus":500}')"

# --- Legacy plain-text broker response -> fall through to raw body ---
check "plain-text body falls through to Response:" \
  "Response: Failed to mint scoped installation token: HTTP 404" \
  "$(run_fixture 'Failed to mint scoped installation token: HTTP 404')"

# --- HTML from an intermediate proxy -> fall through to raw body ---
check "non-JSON HTML falls through to Response:" \
  "Response: <html><body>502 Bad Gateway</body></html>" \
  "$(run_fixture '<html><body>502 Bad Gateway</body></html>')"

# --- Empty body -> fall through to Response: (empty) ---
check "empty body falls through" \
  "Response: " \
  "$(run_fixture '')"

# --- JSON with empty-string message -> `.message // empty` returns empty; falls through ---
check "empty string message falls through to Response:" \
  "Response: {\"message\":\"\",\"upstreamStatus\":500}" \
  "$(run_fixture '{"message":"","upstreamStatus":500}')"

# --- Drift guard: the extraction pattern in the helper above must match the one in
# prepare-auth.sh. If someone edits one and forgets the other, this fails loudly.
prepare_auth_extraction_present() {
  grep -Eq "jq -r '\.message // empty'" "${SCRIPT_DIR}/prepare-auth.sh" \
    && grep -Eq "jq -r '\.upstreamStatus // empty'" "${SCRIPT_DIR}/prepare-auth.sh"
}
check "prepare-auth.sh uses the tested extraction pattern" \
  "match" \
  "$(if prepare_auth_extraction_present; then echo match; else echo drift; fi)"

if [ "${fail}" -ne 0 ]; then
  echo "prepare-auth_test: FAILURES"
  exit 1
fi
echo "prepare-auth_test: all passed"
