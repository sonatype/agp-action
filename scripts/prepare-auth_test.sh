#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# prepare-auth_test.sh — unit tests for scripts/prepare-auth.sh. prepare-auth.sh runs top-level
# side effects on source (network calls, stdin reads, exit), so the classified-error parsing is
# copied into a helper here with a drift check, and the commit identity is tested through
# scripts/broker-identity.sh, which prepare-auth.sh sources.

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

# shellcheck source=scripts/broker-identity.sh
source "${SCRIPT_DIR}/broker-identity.sh"

# Runs the real identity resolution. Prints name|email|auth-source, then any annotations it printed.
identity_fixture() {
  local body="$1" GIT_NAME="${2:-}" GIT_EMAIL="${3:-}" api_url="${4:-${DEFAULT_BROKER_URL}}"
  local tmp annotations ACTOR_LOGIN ACTOR_ID AUTH_SOURCE
  tmp=$(mktemp)
  printf '%s' "${body}" >"${tmp}"
  annotations=$(resolve_broker_identity "${tmp}" "${api_url}")
  resolve_broker_identity "${tmp}" "${api_url}" >/dev/null
  rm -f "${tmp}"
  printf '%s|%s|%s\n' "${GIT_NAME}" "${GIT_EMAIL}" "${AUTH_SOURCE}"
  if [ -n "${annotations}" ]; then
    printf '%s\n' "${annotations}"
  fi
}

ACME='{"token":"ghs_x","actor":{"login":"acme-agentp[bot]","id":424242}}'
ACME_IDENTITY='acme-agentp[bot]|424242+acme-agentp[bot]@users.noreply.github.com|acme-agentp[bot] via OIDC broker'
GUIDE_IDENTITY='sonatype-guide[bot]|262430933+sonatype-guide[bot]@users.noreply.github.com|sonatype-guide[bot] via OIDC broker'
FALLBACK="; falling back to the sonatype-guide[bot] default identity."

check "another App's actor names that App's bot" \
  "${ACME_IDENTITY}" \
  "$(identity_fixture "${ACME}")"

check "a numeric-string actor id is accepted" \
  "${ACME_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]","id":"424242"}}')"

check "no actor keeps sonatype-guide[bot] without a warning" \
  "${GUIDE_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","expires_at":"2026-05-01T13:00:00Z"}')"

check "a null actor keeps sonatype-guide[bot] without a warning" \
  "${GUIDE_IDENTITY}" \
  "$(identity_fixture '{"token":"ghs_x","actor":null}')"

check "an actor without an id falls back and says the id is the problem" \
  "${GUIDE_IDENTITY}
::warning::Ignoring the broker's actor because its id is not numeric${FALLBACK}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]"}}')"

check "a non-numeric actor id falls back and says the id is the problem" \
  "${GUIDE_IDENTITY}
::warning::Ignoring the broker's actor because its id is not numeric${FALLBACK}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"acme-agentp[bot]","id":"12a"}}')"

check "an actor whose login is not a bot falls back and says the login is the problem" \
  "${GUIDE_IDENTITY}
::warning::Ignoring the broker's actor because its login is not a GitHub bot login${FALLBACK}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"octocat","id":1}}')"

check "an actor login with injected characters falls back" \
  "${GUIDE_IDENTITY}
::warning::Ignoring the broker's actor because its login is not a GitHub bot login${FALLBACK}" \
  "$(identity_fixture '{"token":"ghs_x","actor":{"login":"evil[bot]\nGIT_NAME=x","id":1}}')"

check "an actor that is not an object falls back with a warning" \
  "${GUIDE_IDENTITY}
::warning::Ignoring the broker's actor because it is not an object${FALLBACK}" \
  "$(identity_fixture '{"token":"ghs_x","actor":"acme-agentp[bot]"}')"

check "set inputs override the actor" \
  'MyCompany Bot|bot@mycompany.com|acme-agentp[bot] via OIDC broker' \
  "$(identity_fixture "${ACME}" 'MyCompany Bot' 'bot@mycompany.com')"

check "a set name alone keeps the actor's e-mail" \
  'MyCompany Bot|424242+acme-agentp[bot]@users.noreply.github.com|acme-agentp[bot] via OIDC broker' \
  "$(identity_fixture "${ACME}" 'MyCompany Bot')"

check "a set e-mail alone keeps the actor's name" \
  'acme-agentp[bot]|bot@mycompany.com|acme-agentp[bot] via OIDC broker' \
  "$(identity_fixture "${ACME}" '' 'bot@mycompany.com')"

check "set inputs override the fallback too" \
  'MyCompany Bot|bot@mycompany.com|sonatype-guide[bot] via OIDC broker' \
  "$(identity_fixture '{"token":"ghs_x"}' 'MyCompany Bot' 'bot@mycompany.com')"

check "a self-hosted broker without an actor gets a notice naming the inputs" \
  "${GUIDE_IDENTITY}
::notice::The broker at https://agp.example.com named no commit identity, so commits default to sonatype-guide[bot]. To credit your own App's bot, set the git-user-name and git-user-email inputs." \
  "$(identity_fixture '{"token":"ghs_x"}' '' '' 'https://agp.example.com')"

check "a self-hosted broker with both inputs set gets no notice" \
  'MyCompany Bot|bot@mycompany.com|sonatype-guide[bot] via OIDC broker' \
  "$(identity_fixture '{"token":"ghs_x"}' 'MyCompany Bot' 'bot@mycompany.com' 'https://agp.example.com')"

check "a self-hosted broker with a valid actor gets no notice" \
  "${ACME_IDENTITY}" \
  "$(identity_fixture "${ACME}" '' '' 'https://agp.example.com')"

# shellcheck disable=SC2016
check "prepare-auth.sh resolves the identity with the tested function" \
  "match" \
  "$(if grep -Fq 'resolve_broker_identity "$RESP_BODY" "$API_URL"' "${SCRIPT_DIR}/prepare-auth.sh"; then echo match; else echo drift; fi)"

if [ "${fail}" -ne 0 ]; then
  echo "prepare-auth_test: FAILURES"
  exit 1
fi
echo "prepare-auth_test: all passed"
