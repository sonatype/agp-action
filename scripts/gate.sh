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
# Fail-closed: on anything other than HTTP 200 it leaves any committed config untouched
# and fails (the download is staged outside the workspace and only moved into place after
# a verified 200 + workspace-containment check, so a committed agp.yml is preserved on
# failure and replaced atomically on success).
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

# Temp-file paths used by main(); declared at script scope so the EXIT trap and the
# cleanup function can see them (a trap referencing function-local vars would find them
# out of scope once main returns).
_GATE_STAGING_TMP=""
_GATE_HEADERS_FILE=""
_GATE_DEST_TMP=""
_gate_cleanup() {
  rm -f "${_GATE_STAGING_TMP}" "${_GATE_HEADERS_FILE}" "${_GATE_DEST_TMP}" 2>/dev/null || true
}

# sanitize_for_log
# Filter stdin for safe inclusion in a workflow log line: strip control characters and
# replace ':' so a hostile or garbled response body cannot inject GitHub Actions workflow
# commands (which require the '::' marker) into the runner's stdout parser.
sanitize_for_log() {
  LC_ALL=C tr -d '[:cntrl:]' | tr ':' '_'
}

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
# unreadable headers file returns non-zero (the caller then exits). Only the FINAL HTTP
# response block is considered — curl's -D dump appends the headers of every retry attempt,
# so the state is reset at each `HTTP/...` status line; otherwise a retried 5xx-then-200
# could be miscounted as duplicate headers and forced to paused. The header value is
# CR-stripped and leading/trailing whitespace trimmed; duplicates *within the final block*
# are counted so they can be treated as ambiguous.
#
# Implemented as a pure bash loop (no grep|tail|tr|sed pipeline) so there are no
# intermediate subprocess exit codes to suppress under `set -o pipefail`.
parse_directive_file() {
  local file="$1" line name value count=0 last_value=""
  if [ ! -r "${file}" ]; then
    echo "::error::agp-gate: response headers file is missing or unreadable (fail-closed)." >&2
    return 1
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in
      [Hh][Tt][Tt][Pp]/*)
        # New response block (retry attempt / 1xx continue / redirect) — reset so only the
        # final response's headers are considered.
        count=0
        last_value=""
        continue
        ;;
    esac
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
# anywhere but a plain HTTPS host (fail-closed). Beyond the scheme, the authority must be a
# DNS/IPv4 name or a bracketed IPv6 literal with an optional :port — this rejects embedded
# userinfo (user:pass@host — a token-exfiltration vector), empty hosts (https://,
# https:///path), and whitespace. Returns 0 if acceptable, else prints ::error:: + returns 1.
validate_base_url() {
  local url="${1:-}" rest host
  local re='^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]+)?$'
  case "${url}" in
    https://*) ;;
    *)
      echo "::error::agp-gate: refusing to send the OIDC token to a non-HTTPS URL '${url}' (fail-closed)." >&2
      return 1 ;;
  esac
  rest="${url#https://}"   # strip scheme
  host="${rest%%/*}"       # authority = everything up to the first '/'
  if [[ ! "${host}" =~ $re ]]; then
    echo "::error::agp-gate: refusing to send the OIDC token to a URL with an invalid or unsafe host '${url}' (fail-closed)." >&2
    return 1
  fi
  return 0
}

# validate_config_path <path>
# config-path is written to, so keep it inside the workspace. Reject empty values,
# absolute paths, and any '..' *path segment*. Matching '..' as a bare substring would
# wrongly reject legitimate names like 'agp..yml', so each '/'-separated segment is
# compared exactly. Symlink-based escape (an intermediate directory or the leaf being a
# symlink out of the workspace) is caught separately by is_inside_workspace in main().
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

# is_inside_workspace <resolved-path> <resolved-workspace-root>
# Pure containment check. Fail-closed (return 1) if either argument is empty, or if
# resolved-path is neither the root itself nor a descendant of root/. Uses an exact path
# prefix on a slash-normalised root so a sibling like /w/repo-evil does not match /w/repo.
is_inside_workspace() {
  local path="${1:-}" root="${2:-}"
  if [ -z "${path}" ] || [ -z "${root}" ]; then
    return 1
  fi
  root="${root%/}"
  [ -z "${root}" ] && return 1   # root was "/" only — refuse rather than match everything
  if [ "${path}" = "${root}" ]; then
    return 0
  fi
  case "${path}" in
    "${root}"/*) return 0 ;;
    *)           return 1 ;;
  esac
}

main() {
  local script_dir base_url oidc_token http_code body_snippet raw_len directive
  local workspace_root config_resolved config_dir

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Base URL precedence: explicit input > AGP_API_URL env (set by the caller, same as
  # prepare-auth.sh) > the production Guide API host. Strip ALL trailing slashes so a
  # value like "https://host//" doesn't produce a "//agp/..." request path.
  base_url="${GUIDE_URL_INPUT:-${AGP_API_URL:-https://api.guide.sonatype.com}}"
  while [ "${base_url}" != "${base_url%/}" ]; do
    base_url="${base_url%/}"
  done

  validate_base_url "${base_url}" || exit 1
  validate_config_path "${CONFIG_PATH}" || exit 1

  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "::error::agp-gate requires 'permissions: id-token: write' for OIDC. Aborting (fail-closed)."
    exit 1
  fi

  # The workspace-containment guard below is the last line of defence before writing, so a
  # missing GITHUB_WORKSPACE must fail closed rather than skip the check.
  if [ -z "${GITHUB_WORKSPACE:-}" ]; then
    echo "::error::agp-gate: GITHUB_WORKSPACE is not set; cannot verify workspace containment (fail-closed)." >&2
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
  # redirects to other hosts. A tolerant Accept header copes with proxies that only know
  # the older YAML media types.
  #
  # The body is staged in RUNNER_TEMP (never written to the workspace) so a committed
  # CONFIG_PATH is only replaced after a verified 200 + containment check. Both temp files
  # are cleaned up on exit via _gate_cleanup.
  _GATE_STAGING_TMP="$(mktemp "${RUNNER_TEMP:-/tmp}/agp-gate-config.XXXXXX")"
  _GATE_HEADERS_FILE="$(mktemp "${RUNNER_TEMP:-/tmp}/agp-gate-headers.XXXXXX")"
  trap _gate_cleanup EXIT

  # The fallback is applied OUTSIDE the substitution. With -sS (no -f) curl exits zero on
  # HTTP 4xx/5xx and prints the real status via -w; only a transport-level failure (after
  # retries) makes curl print 000 to stdout AND exit non-zero, so `|| http_code="000"`
  # simply matches that, and the `!= "200"` check below fires uniformly for both.
  http_code="$(curl -sS -o "${_GATE_STAGING_TMP}" -D "${_GATE_HEADERS_FILE}" -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    --retry 2 --retry-delay 2 --retry-connrefused --retry-all-errors \
    -H "Authorization: Bearer ${oidc_token}" \
    -H "Accept: application/yaml, application/x-yaml;q=0.9, text/yaml;q=0.8, */*;q=0.1" \
    "${base_url}/agp/effective-config?format=yaml")" || http_code="000"

  # Fail-closed on anything but 200. The staged body is an error envelope here (the token
  # is never echoed), so log a short, sanitised snippet for diagnostics. The committed
  # CONFIG_PATH is untouched because we staged in RUNNER_TEMP.
  if [ "${http_code}" != "200" ]; then
    raw_len="$(wc -c < "${_GATE_STAGING_TMP}" 2>/dev/null || echo 0)"
    body_snippet="$(head -c 500 "${_GATE_STAGING_TMP}" 2>/dev/null | sanitize_for_log || true)"
    if [ "${raw_len:-0}" -gt 500 ]; then
      body_snippet="${body_snippet} [truncated]"
    fi
    echo "::error::agp-gate: Guide returned HTTP ${http_code} from ${base_url}/agp/effective-config; skipping run (fail-closed)."
    if [ -n "${body_snippet}" ]; then
      echo "Response body (truncated): ${body_snippet}"
    fi
    echo "Common causes: the Sonatype Guide GitHub App is not installed on this repo; the repo is not onboarded/paused; or the OIDC 'audience' input does not match the configured Guide audience."
    exit 1
  fi

  # Resolve the destination explicitly against the (resolved) workspace root rather than
  # the implicit cwd, so the containment guarantee holds regardless of where the script
  # runs from. realpath -m resolves existing symlink components while treating the
  # not-yet-created leaf logically, so a symlinked intermediate directory is caught here
  # BEFORE any directory is created or any byte is written into the workspace.
  workspace_root="$(realpath -m "${GITHUB_WORKSPACE}" 2>/dev/null || true)"
  config_resolved="$(realpath -m "${workspace_root}/${CONFIG_PATH}" 2>/dev/null || true)"
  if ! is_inside_workspace "${config_resolved}" "${workspace_root}"; then
    echo "::error::agp-gate: config-path '${CONFIG_PATH}' resolves outside the workspace (possible symlink escape); refusing (fail-closed)." >&2
    exit 1
  fi
  if [ -d "${config_resolved}" ]; then
    echo "::error::agp-gate: config-path '${CONFIG_PATH}' is an existing directory; refusing to write (fail-closed)." >&2
    exit 1
  fi

  # Materialise the governed config atomically. Stage inside the destination directory so
  # the final rename is a same-filesystem rename(2) (RUNNER_TEMP may be a different mount on
  # self-hosted runners). mv -fT treats the destination as a file, never moving into a dir.
  config_dir="$(dirname "${config_resolved}")"
  mkdir -p "${config_dir}"
  if [ -e "${config_resolved}" ]; then
    echo "agp-gate: replacing existing ${CONFIG_PATH} with the governed config from Guide."
  fi
  _GATE_DEST_TMP="$(mktemp "${config_dir}/.agp-gate-config.XXXXXX")"
  cp "${_GATE_STAGING_TMP}" "${_GATE_DEST_TMP}"
  mv -fT "${_GATE_DEST_TMP}" "${config_resolved}"
  _GATE_DEST_TMP=""   # consumed by the rename; nothing left for cleanup to remove

  # Read the run/pause directive from the response headers (fail-closed on I/O error).
  directive="$(parse_directive_file "${_GATE_HEADERS_FILE}")" || exit 1
  echo "directive=${directive}" >> "${GITHUB_OUTPUT}"
  echo "agp-gate: directive=${directive}; wrote ${CONFIG_PATH} from ${base_url}"
}

# Run main only when executed directly, not when sourced (scripts/gate_test.sh sources
# this file to unit-test the parsing/validation helpers without performing any network I/O).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
