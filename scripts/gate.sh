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
# The written file is also marked git-excluded locally (.git/info/exclude) so it never shows up
# as a pending change and cannot trip the AGP CLI's clean-worktree pre-flight guard (GUIDE-3347).
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
# config-path is written to, so keep it inside the workspace. Reject empty values, control
# characters, absolute paths, and any '..' *path segment*. Matching '..' as a bare substring
# would wrongly reject legitimate names like 'agp..yml', so each '/'-separated segment is
# compared exactly. Symlink-based escape (an intermediate directory or the leaf being a
# symlink out of the workspace) is caught separately by is_inside_workspace in main().
# Returns 0 if acceptable; otherwise prints an ::error:: and returns 1.
validate_config_path() {
  local path="${1:-}" rest seg
  if [ -z "${path}" ]; then
    echo "::error::agp-gate: config-path must not be empty (fail-closed)." >&2
    return 1
  fi
  # A newline (legal inside a YAML input value) would let one config-path smuggle EXTRA gitignore
  # patterns into the .git/info/exclude entry the gate writes: 'agp.yml\nsrc/' appends both
  # '/agp.yml' and 'src/', so real customer changes under src/ would vanish from
  # `git status --porcelain` and the AGP CLI's dirty-worktree pre-flight check would pass on a
  # genuinely dirty tree. Reject every control character, fail-closed (GUIDE-3347). The value is
  # sanitised before it is logged because it is untrusted input printed into a workflow command.
  case "${path}" in
    *[[:cntrl:]]*)
      echo "::error::agp-gate: config-path must not contain control characters (got '$(printf '%s' "${path}" | sanitize_for_log)')." >&2
      return 1 ;;
  esac
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

# exclude_config_from_git <config-dir-real> <config-basename>
# Make the governed config invisible to git by adding an anchored pattern for it to the
# repo-local .git/info/exclude (GUIDE-3347).
#
# Why: configuration is governed centrally in the Sonatype Guide dashboard, so the effective
# agp.yml is fetched fresh on every run and is NOT meant to live in the customer's repo. Left
# alone it shows up as `?? agp.yml`, and the AGP CLI's pre-flight guard (`git status --porcelain`)
# then aborts the run with "Uncommitted changes in working directory". info/exclude is the right
# place: it is repo-local, never versioned, and not part of the customer's tree (unlike
# .gitignore, which would itself become a pending change). Consumers previously tried
# `git update-index --assume-unchanged`, which exits 128 for a file that is not already tracked
# — i.e. for every new customer.
#
# Best-effort by design: this is bookkeeping, not the gate's contract (directive + config). Any
# git problem (no repository, git not installed, unwritable exclude file) only warns and returns
# 0, so the gate keeps working where this cannot be done. The script runs under
# `set -euo pipefail`, so every git call is guarded with `|| { warn; return 0; }`.
exclude_config_from_git() {
  local dir="${1:-}" name="${2:-}"
  local git_common_dir gitdir show_prefix in_repo_path pattern line exclude_file
  local dir_log name_log path_log file_log
  # One-line provenance note so a human reading .git/info/exclude knows where the entry came from.
  local marker="# Sonatype Guide (agp-action gate): the config below is governed centrally in Guide and re-fetched every run — kept out of git on purpose (GUIDE-3347)."

  if [ -z "${dir}" ] || [ -z "${name}" ]; then
    echo "::warning::agp-gate: internal error: exclude_config_from_git needs a directory and a filename; skipping git-exclude bookkeeping." >&2
    return 0
  fi
  # Defence in depth (GUIDE-3347): validate_config_path already rejects control characters, but
  # this function APPENDS a line to info/exclude, so a newline here would append a second,
  # caller-chosen pattern (e.g. 'src/') that could hide real customer changes from the AGP CLI's
  # dirty-worktree check. Escaping does not help — '/', '!' and directory patterns are not
  # escaped — so refuse to write anything at all if we are ever reached from a code path that
  # skipped validation.
  case "${dir}${name}" in
    *$'\n'*|*$'\r'*)
      echo "::warning::agp-gate: refusing to write a git-exclude entry for a path containing control characters; the config may appear as an uncommitted change." >&2
      return 0 ;;
  esac
  # Untrusted input (derived from the config-path action input) is sanitised before it appears in
  # any ::warning:: below, so it cannot inject its own GitHub workflow commands into the log.
  dir_log="$(printf '%s' "${dir}" | sanitize_for_log)"
  name_log="$(printf '%s' "${name}" | sanitize_for_log)"
  if ! command -v git >/dev/null 2>&1; then
    echo "::warning::agp-gate: git is not on PATH; could not mark '${name_log}' as git-excluded, so it may appear as an uncommitted change." >&2
    return 0
  fi

  # Locate the exclude file through git rather than assuming "<root>/.git/" is a directory: in a
  # linked worktree or a submodule, .git is a FILE pointing elsewhere. --git-common-dir (not
  # --git-dir) yields the SHARED git directory, which is where info/exclude lives — a per-worktree
  # git dir has no effective info/exclude. The answer may be relative to git's cwd, which is the
  # directory passed to -C, so resolve it against that.
  git_common_dir="$(git -C "${dir}" rev-parse --git-common-dir 2>/dev/null)" || git_common_dir=""
  if [ -z "${git_common_dir}" ]; then
    echo "::warning::agp-gate: '${dir_log}' is not inside a readable git repository; skipping git-exclude bookkeeping for '${name_log}'." >&2
    return 0
  fi
  case "${git_common_dir}" in
    /*) gitdir="${git_common_dir}" ;;
    *)  gitdir="${dir}/${git_common_dir}" ;;
  esac
  # Resolving a relative answer against the -C directory is right on modern git (which returns
  # e.g. '../../.git' from a subdirectory) but NOT on older git, which returned a bare '.git' from
  # a subdirectory — there '<config-dir>/.git' would be a path that does not exist, so mkdir -p
  # below would create a stray '.git' directory inside the customer's tree while the exclude stayed
  # silently ineffective. Verify we really found a git directory before creating anything
  # (GUIDE-3347); best-effort, so an unrecognised layout only warns.
  if ! { [ -d "${gitdir}" ] && [ -e "${gitdir}/HEAD" ]; }; then
    echo "::warning::agp-gate: could not locate the git directory for '${dir_log}' (this git reports a git-common-dir the gate cannot resolve); skipping git-exclude bookkeeping for '${name_log}'." >&2
    return 0
  fi

  # The pattern must be relative to the REPOSITORY ROOT, not to GITHUB_WORKSPACE (usually the same
  # directory, but not guaranteed). --show-prefix gives the config directory's path relative to the
  # toplevel, either empty or with a trailing slash, so appending the basename yields the in-repo
  # path. An empty result is legitimate (config at the repo root), so failure is detected by git's
  # exit status, not by emptiness.
  show_prefix="$(git -C "${dir}" rev-parse --show-prefix 2>/dev/null)" || {
    echo "::warning::agp-gate: could not determine the repository-relative path of '${name_log}'; skipping git-exclude bookkeeping." >&2
    return 0
  }
  in_repo_path="${show_prefix}${name}"
  path_log="$(printf '%s' "${in_repo_path}" | sanitize_for_log)"

  # Escape gitignore metacharacters so a legal-but-odd filename cannot turn into a glob. Backslash
  # FIRST, otherwise the backslashes added by the later substitutions would be escaped too.
  pattern="${in_repo_path//\\/\\\\}"
  pattern="${pattern//\*/\\*}"
  pattern="${pattern//\?/\\?}"
  pattern="${pattern//\[/\\[}"
  pattern="${pattern//\]/\\]}"
  # gitignore strips unescaped trailing spaces; escaping the last one preserves the whole run.
  case "${pattern}" in
    *' ') pattern="${pattern% }\\ " ;;
  esac
  # The leading '/' anchors the pattern to the repository root, so it matches exactly this one path
  # and not a same-named file elsewhere in the tree. It also means '#' (comment) and '!' (negation)
  # can never be the first character, so neither needs escaping.
  line="/${pattern}"

  # A file that is already TRACKED is not hidden by info/exclude — it would still show up as
  # " M agp.yml" and keep tripping the CLI's pre-flight guard. Say so plainly rather than leaving a
  # silently ineffective exclude entry. The exclude line is still written (harmless now, correct
  # once untracked). Never mutate the customer's index or history from here.
  if git -C "${dir}" ls-files --error-unmatch -- ":(literal)${name}" >/dev/null 2>&1; then
    echo "::warning::agp-gate: '${path_log}' is committed to this repository, so it will still show up as a modified file. Configuration is now governed centrally in Sonatype Guide and re-fetched on every run: untrack the committed copy ('git rm --cached ${path_log}' then commit) so it stops conflicting with the governed config." >&2
  fi

  exclude_file="${gitdir}/info/exclude"
  file_log="$(printf '%s' "${exclude_file}" | sanitize_for_log)"
  # info/ is not guaranteed to exist (git only creates it from the init template).
  mkdir -p "${gitdir}/info" 2>/dev/null || {
    echo "::warning::agp-gate: could not create the git info directory next to '${file_log}'; '${path_log}' may appear as an uncommitted change." >&2
    return 0
  }
  # Idempotent: re-running the gate must not append duplicates. -Fx (whole-line, fixed-string) and
  # not -F: a substring match against a longer line (e.g. '/agp.yml.bak') would otherwise suppress
  # the append and leave the config visible to git.
  if [ -f "${exclude_file}" ] && grep -Fxq "${line}" "${exclude_file}" 2>/dev/null; then
    return 0
  fi
  # An existing file that does not end in a newline would have its last pattern corrupted by the
  # append. Command substitution strips trailing newlines, so a non-empty result here means the
  # last byte is not a newline.
  # NOTE: '2>/dev/null' precedes '>>' on purpose in the appends below — redirections are applied
  # left to right, so with the usual ordering bash's own "Permission denied" for an unwritable
  # exclude file would leak to the real stderr before stderr was silenced, ahead of the tidy
  # ::warning:: (GUIDE-3347).
  if [ -s "${exclude_file}" ] && [ -n "$(tail -c 1 "${exclude_file}" 2>/dev/null || true)" ]; then
    printf '\n' 2>/dev/null >> "${exclude_file}" || {
      echo "::warning::agp-gate: could not append to '${file_log}'; '${path_log}' may appear as an uncommitted change." >&2
      return 0
    }
  fi
  # Write the provenance comment only the first time (it may already be there from an earlier run,
  # possibly for a different config-path).
  if ! { [ -f "${exclude_file}" ] && grep -Fxq "${marker}" "${exclude_file}" 2>/dev/null; }; then
    printf '%s\n' "${marker}" 2>/dev/null >> "${exclude_file}" || {
      echo "::warning::agp-gate: could not append to '${file_log}'; '${path_log}' may appear as an uncommitted change." >&2
      return 0
    }
  fi
  printf '%s\n' "${line}" 2>/dev/null >> "${exclude_file}" || {
    echo "::warning::agp-gate: could not append to '${file_log}'; '${path_log}' may appear as an uncommitted change." >&2
    return 0
  }
  return 0
}

main() {
  local script_dir base_url oidc_token http_code body_snippet raw_len directive
  local workspace_root config_resolved config_dir config_dir_real

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

  # Resolve the destination strictly under the workspace, portably. realpath -m is GNU-only
  # (BSD/macOS self-hosted runners don't have it), so resolve with `cd ... && pwd -P`, which
  # yields the physical, symlink-resolved absolute path of an existing directory on every
  # platform. Resolving the workspace and the config directory the same way means a symlink
  # anywhere in the path is followed consistently, so a real escape is still caught while the
  # common case works on macOS too. The directory is created first (only on the success path,
  # after the 200 check above) so it can be resolved; validate_config_path has already
  # rejected '..' segments and absolute paths.
  workspace_root="$(cd "${GITHUB_WORKSPACE}" 2>/dev/null && pwd -P)" || workspace_root=""
  if [ -z "${workspace_root}" ]; then
    echo "::error::agp-gate: GITHUB_WORKSPACE ('${GITHUB_WORKSPACE}') is not a readable directory (fail-closed)." >&2
    exit 1
  fi
  config_dir="$(dirname "${CONFIG_PATH}")"
  mkdir -p "${workspace_root}/${config_dir}"
  config_dir_real="$(cd "${workspace_root}/${config_dir}" 2>/dev/null && pwd -P)" || config_dir_real=""
  if [ -z "${config_dir_real}" ]; then
    echo "::error::agp-gate: could not resolve the config-path directory under the workspace (fail-closed)." >&2
    exit 1
  fi
  config_resolved="${config_dir_real}/$(basename "${CONFIG_PATH}")"
  if ! is_inside_workspace "${config_resolved}" "${workspace_root}"; then
    echo "::error::agp-gate: config-path '${CONFIG_PATH}' resolves outside the workspace (possible symlink escape); refusing (fail-closed)." >&2
    exit 1
  fi
  if [ -d "${config_resolved}" ]; then
    echo "::error::agp-gate: config-path '${CONFIG_PATH}' is an existing directory; refusing to write (fail-closed)." >&2
    exit 1
  fi

  # Materialise the governed config atomically. Stage inside the (resolved) destination
  # directory so the final rename is a same-filesystem rename(2) — RUNNER_TEMP may be a
  # different mount on self-hosted runners. The [ -d ] check above already rejects a directory
  # target, so plain `mv -f` (portable; BSD mv has no -T) is safe.
  if [ -e "${config_resolved}" ]; then
    echo "agp-gate: replacing existing ${CONFIG_PATH} with the governed config from Guide."
  fi
  # Hide the governed config from git BEFORE the rename, so there is never an instant in which
  # git (or a concurrently running `git status`) could observe it as an untracked change — the
  # failure mode from GUIDE-3347. Only reached on the success path: a fail-closed gate must not
  # touch the customer's repository state at all. Best-effort; it never fails the gate.
  exclude_config_from_git "${config_dir_real}" "$(basename "${CONFIG_PATH}")"

  _GATE_DEST_TMP="$(mktemp "${config_dir_real}/.agp-gate-config.XXXXXX")"
  cp "${_GATE_STAGING_TMP}" "${_GATE_DEST_TMP}"
  mv -f "${_GATE_DEST_TMP}" "${config_resolved}"
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
