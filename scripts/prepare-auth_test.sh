#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# prepare-auth_test.sh — unit tests for the classified-error parsing and commit identity blocks in
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

# Mirrors Step 3 of the broker branch in prepare-auth.sh. Prints name|email|auth-source.
broker_identity() {
  local RESP_BODY="$1" GIT_NAME="$2" GIT_EMAIL="$3"
  local ACTOR_LOGIN ACTOR_ID AUTH_SOURCE
  ACTOR_LOGIN=$(jq -r '.actor.login // empty' "$RESP_BODY" 2>/dev/null || true)
  ACTOR_ID=$(jq -r '.actor.id // empty' "$RESP_BODY" 2>/dev/null || true)
  if [[ ! "$ACTOR_LOGIN" =~ ^[A-Za-z0-9-]+\[bot\]$ ]] || [[ ! "$ACTOR_ID" =~ ^[0-9]+$ ]]; then
    ACTOR_LOGIN="sonatype-guide[bot]"
    ACTOR_ID="262430933"
  fi
  AUTH_SOURCE="$ACTOR_LOGIN via OIDC broker"
  if [ -z "$GIT_NAME" ]; then
    GIT_NAME="$ACTOR_LOGIN"
  fi
  if [ -z "$GIT_EMAIL" ]; then
    GIT_EMAIL="${ACTOR_ID}+${ACTOR_LOGIN}@users.noreply.github.com"
  fi
  printf '%s|%s|%s\n' "$GIT_NAME" "$GIT_EMAIL" "$AUTH_SOURCE"
}

identity_fixture() {
  local body="$1" name="${2:-}" email="${3:-}"
  local tmp
  tmp=$(mktemp)
  printf '%s' "${body}" >"${tmp}"
  broker_identity "${tmp}" "${name}" "${email}"
  rm -f "${tmp}"
}

GUIDE_IDENTITY='sonatype-guide[bot]|262430933+sonatype-guide[bot]@users.noreply.github.com|sonatype-guide[bot] via OIDC broker'

check "another App's actor names that App's bot" \
  'acme-agentp[bot]|424242+acme-agentp[bot]@users.noreply.github.com|acme-agentp[bot] via OIDC broker' \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]","id":424242}}')"

check "no actor keeps sonatype-guide[bot]" \
  "${GUIDE_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","expires_at":"2026-05-01T13:00:00Z"}')"

check "actor without an id keeps sonatype-guide[bot]" \
  "${GUIDE_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]"}}')"

check "actor whose login is not a bot keeps sonatype-guide[bot]" \
  "${GUIDE_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"octocat","id":1}}')"

check "actor login with injected characters keeps sonatype-guide[bot]" \
  "${GUIDE_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"evil[bot]\nGIT_NAME=x","id":1}}')"

check "non-numeric actor id keeps sonatype-guide[bot]" \
  "${GUIDE_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]","id":"12a"}}')"

check "set inputs override the actor" \
  'MyCompany Bot|bot@mycompany.com|acme-agentp[bot] via OIDC broker' \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]","id":424242}}' 'MyCompany Bot' 'bot@mycompany.com')"

check "a set name alone keeps the actor's e-mail" \
  'MyCompany Bot|424242+acme-agentp[bot]@users.noreply.github.com|acme-agentp[bot] via OIDC broker' \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]","id":424242}}' 'MyCompany Bot')"

# shellcheck disable=SC2016
prepare_auth_identity_present() {
  local script="${SCRIPT_DIR}/prepare-auth.sh"
  grep -Fq "ACTOR_LOGIN=\$(jq -r '.actor.login // empty' \"\$RESP_BODY\" 2>/dev/null || true)" "${script}" \
    && grep -Fq "ACTOR_ID=\$(jq -r '.actor.id // empty' \"\$RESP_BODY\" 2>/dev/null || true)" "${script}" \
    && grep -Fq 'if [[ ! "$ACTOR_LOGIN" =~ ^[A-Za-z0-9-]+\[bot\]$ ]] || [[ ! "$ACTOR_ID" =~ ^[0-9]+$ ]]; then' "${script}" \
    && grep -Fq 'AUTH_SOURCE="$ACTOR_LOGIN via OIDC broker"' "${script}" \
    && grep -Fq 'GIT_NAME="$ACTOR_LOGIN"' "${script}" \
    && grep -Fq 'GIT_EMAIL="${ACTOR_ID}+${ACTOR_LOGIN}@users.noreply.github.com"' "${script}"
}
check "prepare-auth.sh uses the tested commit identity block" \
  "match" \
  "$(if prepare_auth_identity_present; then echo match; else echo drift; fi)"

if [ "${fail}" -ne 0 ]; then
  echo "prepare-auth_test: FAILURES"
  exit 1
fi
echo "prepare-auth_test: all passed"
