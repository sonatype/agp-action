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
# Inputs (supplied by gate/action.yml):
#   GUIDE_URL_INPUT   — inputs.guide-url (may be empty)
#   OIDC_AUDIENCE     — inputs.audience
#   CONFIG_PATH       — inputs.config-path
# Set by the Actions runtime:
#   GITHUB_OUTPUT, GITHUB_WORKSPACE, RUNNER_TEMP,
#   ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN (need id-token: write)
# Override (optional): AGP_API_URL

set -euo pipefail

# normalize_directive <header-count> <raw-value>
# Pure decision: map the parsed x-agp-directive header to the documented run|paused enum.
# The gate pauses by Guide *sending* an explicit directive, so the contract is:
#   - no header (count 0)       -> run    (active-repo default; a paused repo always
#                                          carries an explicit directive header — Guide
#                                          cannot pause a repo by *omitting* the header)
#   - exactly one "run"         -> run
#   - exactly one "paused"      -> paused
#   - one empty / unrecognised  -> paused (fail-closed: unknown or future directive such
#                                          as quarantine/maintenance must not run)
#   - more than one header      -> paused (fail-closed: ambiguous / possibly proxy-injected)
normalize_directive() {
  local count="${1:-0}" v
  v="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  if [ "${count}" -eq 0 ]; then
    printf 'run'
    return 0
  fi
  if [ "${count}" -gt 1 ]; then
    printf 'paused'
    return 0
  fi
  case "${v}" in
    run)    printf 'run' ;;
    paused) printf 'paused' ;;
    *)      printf 'paused' ;;
  esac
}

# parse_directive_file <headers-file>
# Read the response headers and print the run|paused directive. Fail-closed: a missing or
# unreadable headers file returns non-zero (the caller then exits). The header value is
# CR-stripped and leading/trailing whitespace is trimmed before matching, and every
# x-agp-directive occurrence is counted so duplicates can be treated as ambiguous.
#
# Implemented as a pure bash loop (no grep|tail|tr|sed pipeline) so there are no
# intermediate subprocess exit codes to suppress under `set -o pipefail` — an I/O error
# can no longer masquerade as an empty value.
parse_directive_file() {
  local file="$1" line name value count=0 last_value=""
  if [ ! -r "${file}" ]; then
    echo "::error::agp-gate: response headers file is missing or unreadable (fail-closed)." >&2
    return 1
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    name="${line%%:*}"
    case "$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')" in
      x-agp-directive)
        count=$((count + 1))
        value="${line#*:}"
        value="${value#"${value%%[![:space:]]*}"}"  # trim leading whitespace
        value="${value%"${value##*[![:space:]]}"}"  # trim trailing whitespace
        last_value="${value}"
        ;;
    esac
  done < "${file}"
  normalize_directive "${count}" "${last_value}"
}

# validate_base_url <url>
# The minted OIDC token is sent as a bearer credential to this URL, so refuse to send it
# anywhere but a plain HTTPS host (fail-closed). Beyond the scheme, this rejects embedded
# userinfo (user:pass@host — a token-exfiltration vector), empty hosts (https://,
# https:///path), and any whitespace or other unexpected characters in the authority.
# Returns 0 if acceptable; otherwise prints an ::error:: and returns 1.
validate_base_url() {
  local url="${1:-}" rest host
  case "${url}" in
    https://*) ;;
    *)
      echo "::error::agp-gate: refusing to send the OIDC token to a non-HTTPS URL '${url}' (fail-closed)." >&2
      return 1 ;;
  esac
  rest="${url#https://}"   # strip scheme
  host="${rest%%/*}"       # authority = everything up to the first '/'
  case "${host}" in
    "" | *@* | *[!A-Za-z0-9.:-]*)
      echo "::error::agp-gate: refusing to send the OIDC token to a URL with an invalid or unsafe host '${url}' (fail-closed)." >&2
      return 1 ;;
  esac
  return 0
}

# validate_config_path <path>
# config-path is written to (and, on failure, removed), so keep it inside the workspace.
# Reject empty values, absolute paths, and any '..' *path segment*. Matching '..' as a
# bare substring would wrongly reject legitimate names like 'agp..yml', so each
# '/'-separated segment is compared exactly. Symlink-based escape (an intermediate
# directory or the leaf being a symlink out of the workspace) is caught separately by the
# realpath containment check in main() after the file is written.
# Returns 0 if acceptable; otherwise prints an ::error:: and returns 1.
validate_config_path() {
  local path="${1:-}" rest seg
  if [ -z "${path}" ]; then
    echo "::error::agp-gate: config-path must not be empty (fail-closed)." >&2
    return 1
  fi
  case "${path}" in
    /*)
      echo "::error::agp-gate: config-path must be a relative path within the workspace (got '${path}')." >&2
      return 1 ;;
  esac
  rest="${path}"
  while :; do
    seg="${rest%%/*}"
    if [ "${seg}" = ".." ]; then
      echo "::error::agp-gate: config-path must not contain '..' path segments (got '${path}')." >&2
      return 1
    fi
    case "${rest}" in
      */*) rest="${rest#*/}" ;;
      *)   break ;;
    esac
  done
  return 0
}

main() {
  local script_dir base_url oidc_token headers_file http_code body_snippet raw_len directive
  local resolved_config workspace_root

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

  # Fetch the governed effective config as YAML. Bounded timeouts + a small retry/backoff
  # keep this a fast gate and ride out transient blips; worst case ≈ 3 attempts × 10s plus
  # backoff (~36s) before failing closed. No -L: the credentialed request must not follow
  # redirects to other hosts. Headers go to a RUNNER_TEMP file (never the workspace) and
  # are cleaned up on exit.
  mkdir -p "$(dirname "${CONFIG_PATH}")"
  if [ -e "${CONFIG_PATH}" ]; then
    echo "::warning::agp-gate: overwriting existing ${CONFIG_PATH} with the governed config from Guide (it is removed if the fetch fails)."
  fi

  # NOTE: this trap replaces any EXIT trap a caller may have installed. gate.sh is only
  # ever invoked as a top-level script (the action's run: step), never sourced into a shell
  # that owns its own EXIT trap, so a single unguarded trap is intentional here.
  headers_file="$(mktemp "${RUNNER_TEMP:-/tmp}/agp-gate-headers.XXXXXX")"
  trap 'rm -f "${headers_file}"' EXIT

  # The fallback is applied OUTSIDE the substitution. With -sS (no -f) curl exits zero on
  # HTTP 4xx/5xx and prints the real status via -w; only a transport-level failure (after
  # retries) makes curl print 000 to stdout AND exit non-zero, so `|| http_code="000"`
  # simply matches that, and the `!= "200"` check below fires uniformly for both.
  http_code="$(curl -sS -o "${CONFIG_PATH}" -D "${headers_file}" -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    --retry 2 --retry-delay 2 --retry-connrefused --retry-all-errors \
    -H "Authorization: Bearer ${oidc_token}" \
    -H "Accept: application/yaml" \
    "${base_url}/agp/effective-config?format=yaml")" || http_code="000"

  # Fail-closed on anything but 200. Capture a short, control-character-stripped snippet of
  # the response body for diagnostics FIRST, then remove any partial body so a stale
  # committed agp.yml is never trusted. (The OIDC token was already minted above, so a
  # missing id-token: write permission cannot be the cause here — that is surfaced earlier.)
  if [ "${http_code}" != "200" ]; then
    raw_len="$(wc -c < "${CONFIG_PATH}" 2>/dev/null || echo 0)"
    body_snippet="$(head -c 500 "${CONFIG_PATH}" 2>/dev/null | LC_ALL=C tr -d '[:cntrl:]' || true)"
    if [ "${raw_len:-0}" -gt 500 ]; then
      body_snippet="${body_snippet} [truncated]"
    fi
    rm -f "${CONFIG_PATH}"
    echo "::error::agp-gate: Guide returned HTTP ${http_code} from ${base_url}/agp/effective-config; skipping run (fail-closed)."
    if [ -n "${body_snippet}" ]; then
      echo "Response body (truncated): ${body_snippet}"
    fi
    echo "Common causes: the Sonatype Guide GitHub App is not installed on this repo, or the repo is not onboarded/paused."
    exit 1
  fi

  # Defence-in-depth against symlink escape: confirm the written file resolved to a path
  # inside the workspace before we trust/keep it.
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    resolved_config="$(realpath "${CONFIG_PATH}" 2>/dev/null || true)"
    workspace_root="$(realpath "${GITHUB_WORKSPACE}" 2>/dev/null || true)"
    case "${resolved_config}" in
      "${workspace_root}" | "${workspace_root}"/*) : ;;
      *)
        rm -f "${CONFIG_PATH}"
        echo "::error::agp-gate: ${CONFIG_PATH} resolved outside the workspace (possible symlink escape); refusing (fail-closed)." >&2
        exit 1 ;;
    esac
  fi

  # Read the run/pause directive from the response headers (fail-closed on I/O error).
  directive="$(parse_directive_file "${headers_file}")" || exit 1
  echo "directive=${directive}" >> "${GITHUB_OUTPUT}"
  echo "agp-gate: directive=${directive}; wrote ${CONFIG_PATH} from ${base_url}"
}

# Run main only when executed directly, not when sourced (scripts/gate_test.sh sources
# this file to unit-test the parsing/validation helpers without performing any network I/O).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
