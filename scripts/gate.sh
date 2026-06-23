#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# gate.sh — implementation of the Sonatype Guide Agent P Gate composite action
# (gate/action.yml). The action's run: step just invokes this script so the logic
# is covered by `shellcheck scripts/*.sh` and unit-tested by scripts/gate_test.sh.
#
# It fetches the governed effective agp.yml from Sonatype Guide over GitHub OIDC,
# writes it to CONFIG_PATH, and emits a run|paused directive to GITHUB_OUTPUT.
# Fail-closed: on anything other than HTTP 200 it removes any partial config and fails.
#
# Required environment (supplied by gate/action.yml):
#   GUIDE_URL_INPUT   — inputs.guide-url (may be empty)
#   OIDC_AUDIENCE     — inputs.audience
#   CONFIG_PATH       — inputs.config-path
#   GITHUB_OUTPUT     — provided by the Actions runtime
#   ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN — OIDC (id-token: write)
# Optional: AGP_API_URL, RUNNER_TEMP

set -euo pipefail

# extract_directive_header <headers-file>
# Print the raw x-agp-directive value (may be empty). The trailing `|| true` keeps
# grep's no-match exit from aborting the caller under `set -o pipefail`.
extract_directive_header() {
  grep -i '^x-agp-directive:' "$1" | tail -n1 | tr -d '\r' | sed -E 's/^[^:]*:[[:space:]]*//' || true
}

# normalize_directive <raw>
# Map an arbitrary header value to the documented run|paused enum. A missing/empty
# value, or anything other than an explicit "paused", normalises to "run".
normalize_directive() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    paused) printf 'paused' ;;
    *)      printf 'run' ;;
  esac
}

# validate_base_url <url>
# The minted OIDC token is sent as a bearer credential to this URL, so refuse to
# transmit it over anything but HTTPS (fail-closed). guide-url / AGP_API_URL stay
# overridable for testing and GitHub Enterprise, but must be TLS-protected.
# Returns 0 if acceptable; otherwise prints an ::error:: and returns 1.
validate_base_url() {
  case "${1:-}" in
    https://*) return 0 ;;
    *)
      echo "::error::agp-gate: refusing to send the OIDC token to a non-HTTPS URL '${1:-}' (fail-closed)." >&2
      return 1 ;;
  esac
}

# validate_config_path <path>
# config-path is written to (and, on failure, removed), so keep it inside the
# workspace: reject absolute paths and parent-directory traversal.
# Returns 0 if acceptable; otherwise prints an ::error:: and returns 1.
validate_config_path() {
  case "${1:-}" in
    /*|*..*)
      echo "::error::agp-gate: config-path must be a relative path within the workspace (got '${1:-}')." >&2
      return 1 ;;
    *) return 0 ;;
  esac
}

main() {
  local script_dir base_url oidc_token headers_file http_code body_snippet directive_raw directive

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Base URL precedence: explicit input > AGP_API_URL env (set by the caller, same as
  # prepare-auth.sh) > the production Guide API host.
  base_url="${GUIDE_URL_INPUT:-${AGP_API_URL:-https://api.guide.sonatype.com}}"
  base_url="${base_url%/}"

  validate_base_url "${base_url}" || exit 1
  validate_config_path "${CONFIG_PATH}" || exit 1

  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "::error::agp-gate requires 'permissions: id-token: write' for OIDC. Aborting (fail-closed)."
    exit 1
  fi

  # Mint a GitHub Actions OIDC token for the Guide audience. Shared with
  # scripts/prepare-auth.sh via scripts/mint-oidc-token.sh (bounded timeouts +
  # retries live there). The helper exits non-zero with a diagnostic on failure,
  # which fails the gate closed.
  oidc_token="$(bash "${script_dir}/mint-oidc-token.sh" "${OIDC_AUDIENCE}")"
  echo "::add-mask::${oidc_token}"

  # Fetch the governed effective config as YAML. Bounded timeouts + retries keep this
  # a fast gate and ride out transient blips; a genuine failure falls through to the
  # fail-closed branch below. No -L: the credentialed request must not follow redirects
  # to other hosts. Headers go to a RUNNER_TEMP file (never the workspace) and are
  # cleaned up on every exit.
  #
  # The fallback is applied OUTSIDE the substitution: curl -w '%{http_code}' already
  # prints 000 on a transport failure, so `... || echo 000` would yield "000000".
  headers_file="$(mktemp "${RUNNER_TEMP:-/tmp}/agp-gate-headers.XXXXXX")"
  trap 'rm -f "${headers_file}"' EXIT
  http_code="$(curl -sS -o "${CONFIG_PATH}" -D "${headers_file}" -w '%{http_code}' \
    --connect-timeout 5 --max-time 30 \
    --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \
    -H "Authorization: Bearer ${oidc_token}" \
    -H "Accept: application/yaml" \
    "${base_url}/agp/effective-config?format=yaml")" || http_code="000"

  # Fail-closed on anything but 200. Capture a short snippet of the response body for
  # diagnostics FIRST, then remove any partial body so a stale committed agp.yml is never
  # trusted. (The OIDC token was already minted above, so a missing id-token: write
  # permission cannot be the cause here — that is surfaced by the guard above.)
  if [ "${http_code}" != "200" ]; then
    body_snippet="$(head -c 500 "${CONFIG_PATH}" 2>/dev/null | tr '\n' ' ' || true)"
    rm -f "${CONFIG_PATH}"
    echo "::error::agp-gate: Guide returned HTTP ${http_code} from ${base_url}/agp/effective-config; skipping run (fail-closed)."
    if [ -n "${body_snippet}" ]; then
      echo "Response body (truncated): ${body_snippet}"
    fi
    echo "Common causes: the Sonatype Guide GitHub App is not installed on this repo, or the repo is not onboarded/paused."
    exit 1
  fi

  # Read the run/pause directive from the response header and normalise it to run|paused.
  directive_raw="$(extract_directive_header "${headers_file}")"
  directive="$(normalize_directive "${directive_raw}")"
  echo "directive=${directive}" >> "${GITHUB_OUTPUT}"
  echo "agp-gate: directive=${directive}; wrote ${CONFIG_PATH} from ${base_url}"
}

# Run main only when executed directly, not when sourced (scripts/gate_test.sh sources
# this file to unit-test the parsing helpers without performing any network I/O).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
