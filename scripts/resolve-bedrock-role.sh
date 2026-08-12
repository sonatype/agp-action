#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# resolve-bedrock-role.sh — read the governed Bedrock IAM role out of the effective agp.yml
# that the gate wrote into the workspace, and emit it for the assume-role step in action.yml.
#
# Why this exists (GUIDE-3302): the role ARN used to live in each repository's workflow as a
# secrets.AWS_ROLE_TO_ASSUME reference, so onboarding a repo required a workflow edit and
# rotating the role required editing every repo. It is now governed centrally as agent.awsRole
# in Sonatype Guide, exactly like agent.model / agent.awsRegion already are. The AGP CLI cannot
# consume it — role assumption has to happen before the container starts — so the wrapper does
# it here and the resulting AWS_* credentials are forwarded into the container as before.
#
# Emits nothing (and exits 0) unless ALL of the following hold, so a repo that does not use
# Bedrock, or has not set a role, is completely unaffected:
#   * the config file exists and parses
#   * agent.provider == "bedrock"
#   * agent.awsRole is a syntactically valid, literal IAM role ARN
#
# SECURITY: agp.yml is a trust boundary (GUIDE-2951) — it is fetched at run time from a remote
# service, so its contents are untrusted input. Two consequences drive the design here:
#   1. The ARN is re-validated even though the CLI's schema.ts validates it, because the config
#      may reach this wrapper without ever passing through the CLI.
#   2. The value is only ever written to GITHUB_OUTPUT and read back by the runner via a
#      ${{ steps... }} expression into an action input. It is never interpolated into a shell
#      command, so a value containing shell metacharacters cannot execute (that class of bug is
#      GUIDE-2953, and "no ${{ }} in run: blocks" is a standing rule).
#
# Inputs (supplied by action.yml):
#   CONFIG_PATH — path to the effective agp.yml, relative to GITHUB_WORKSPACE
# Set by the Actions runtime:
#   GITHUB_OUTPUT, GITHUB_WORKSPACE
#
# Outputs (GITHUB_OUTPUT):
#   role   — the validated role ARN, or absent when not applicable
#   region — agent.awsRegion, or absent
#
# A missing/unparseable config is NOT an error: the gate may legitimately not have run (e.g. a
# consumer invoking this action directly), and failing here would break repos that never wanted
# a governed role. Callers detect "not applicable" by an empty `role` output.

set -euo pipefail

# Anchored literal IAM role ARN. Kept in lock-step with IAM_ROLE_ARN_RE in the CLI
# (agentic-patches-ts/src/config/schema.ts) — see resolve-bedrock-role_test.sh, which asserts
# the same accept/reject cases as the CLI's schema tests.
#
# Deliberately rejects: bare role names, non-role ARNs (user, instance-profile), malformed
# account ids, GitHub Actions expression syntax (${{ secrets.X }} — never expanded here, since
# agp.yml is data, not workflow YAML), env: indirection, shell metacharacters, and any value
# with embedded whitespace or newlines.
# The length bound is enforced separately (see MAX_ROLE_ARN_LEN) rather than as a {1,512}
# repetition: POSIX sets RE_DUP_MAX at 255 and BSD grep enforces it, so a larger bound fails
# with "invalid repetition count(s)" on macOS while working under GNU grep. Keeping the regex
# unbounded and checking length in shell behaves identically on both.
readonly IAM_ROLE_ARN_RE='^arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$'

# Upper bound on the whole ARN. AWS caps the role path+name at 512 characters; the fixed prefix
# makes the total slightly longer, so this is a generous sanity limit rather than an exact rule.
readonly MAX_ROLE_ARN_LEN=600

# resolve_bedrock_role <config-file>
# Print "role=<arn>" and "region=<region>" lines when a governed Bedrock role applies.
# Prints nothing otherwise. Never fails the build on bad input.
resolve_bedrock_role() {
  local config_file="$1"

  if [ ! -f "${config_file}" ]; then
    echo "resolve-bedrock-role: no config at ${config_file}; skipping governed role" >&2
    return 0
  fi

  # Cheap pre-check so a parser problem can never silently DISCARD a configured role.
  #
  # If the config asks for no role there is nothing to honour and any parser limitation is
  # irrelevant, so we skip quietly. If it does ask for one and we then cannot parse, we fail
  # loudly: ignoring it would leave the run with no Bedrock credentials and only the opaque
  # "Could not load credentials from any providers" downstream.
  #
  # The pattern requires a VALUE, not merely the key. The Guide UI writes `awsRole: ''` when a
  # repo overrides an inherited Bedrock default to Anthropic, so keying on the key alone would
  # hard-fail an Anthropic repo over a field it never set.
  local wants_role=0
  if grep -Eq "^[[:space:]]*awsRole:[[:space:]]*([^[:space:]'\"]|'[^']|\"[^\"])" \
    "${config_file}" 2>/dev/null; then
    wants_role=1
  fi

  if [ "${wants_role}" -eq 1 ] && ! python3 -c 'import yaml' >/dev/null 2>&1; then
    # One ::error:: per logical failure. Each ::error:: is a separate workflow command, so
    # splitting a sentence across several produces several fragmentary annotations; %0A puts the
    # line breaks inside one.
    local remedy="or set up AWS credentials in the workflow instead."
    if ! command -v python3 >/dev/null 2>&1; then
      echo "::error::agent.awsRole is configured but python3 is not installed, so the governed" \
        "Bedrock role cannot be read.%0AInstall python3 (with PyYAML) on the runner, ${remedy}" >&2
    else
      echo "::error::agent.awsRole is configured but PyYAML is unavailable, so the governed" \
        "Bedrock role cannot be read.%0AInstall it (pip install pyyaml) on the runner, ${remedy}" >&2
    fi
    return 1
  fi

  # Parse with python3 (preinstalled on GitHub-hosted runners) rather than grep/sed, so nested
  # keys and quoting are handled properly. Emits at most two KEY=VALUE lines on stdout.
  local parsed parse_rc=0
  # `|| parse_rc=$?` rather than `if ! ...` so the distinct exit 3 (malformed value) survives.
  parsed=$(CONFIG_FILE="${config_file}" python3 - <<'PY'
import os
import re
import sys

try:
    import yaml
except ImportError:
    # Unreachable when awsRole is present: the caller pre-checks for PyYAML and fails loudly in
    # that case. Reaching here means the config has no awsRole, so skipping loses nothing.
    sys.exit(0)

try:
    with open(os.environ["CONFIG_FILE"], encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}
except Exception as exc:  # malformed YAML, unreadable file, ...
    print(f"resolve-bedrock-role: could not parse config ({exc}); skipping", file=sys.stderr)
    sys.exit(0)

if not isinstance(cfg, dict):
    sys.exit(0)
agent = cfg.get("agent")
if not isinstance(agent, dict):
    sys.exit(0)

# Only the Bedrock provider uses an assumed role. Anthropic uses an API key, and an unset
# provider means the CLI's default (anthropic), so neither should trigger an assume-role.
if agent.get("provider") != "bedrock":
    sys.exit(0)

role = agent.get("awsRole")
region = agent.get("awsRegion")
if not isinstance(role, str):
    sys.exit(0)
role = role.strip()
if not role:
    # An empty scalar means "unset": the governed renderer emits empty strings for blank
    # optional fields (observed in real configs: baseUrl: '', apiKeyEnv: '').
    sys.exit(0)

# Reject any control character (newline, CR, tab, ...) in EITHER value before it is written to
# GITHUB_OUTPUT. A multi-line value is not merely malformed: that file is newline-delimited
# KEY=VALUE, so `<key>=<line1>\n<line2>` lets a hostile config inject ADDITIONAL step outputs.
# Both values are emitted, so both need the check - guarding only the role would leave the
# invariant resting on the downstream ARN regex happening to reject whatever was smuggled in.
# Exit 3 so the caller reports it instead of silently keeping the first line.
def has_control_chars(value):
    # C0, DEL, C1, and the Unicode line/paragraph separators. U+2028/U+2029 do not split
    # GITHUB_OUTPUT on today's runner, which splits on \n only, but any consumer using
    # Unicode-aware splitlines() would treat them as breaks - so the predicate matches the
    # "control characters are rejected" claim rather than just today's parser.
    return any(
        ord(ch) < 0x20 or ord(ch) == 0x7F or 0x80 <= ord(ch) <= 0x9F or ch in "\u2028\u2029"
        for ch in value
    )


region = region.strip() if isinstance(region, str) else ""
if has_control_chars(role) or has_control_chars(region):
    sys.exit(3)

# A role without a region is unusable: aws-region is a required input of
# configure-aws-credentials, so omitting the output makes that action abort with
# "Input required and not supplied: aws-region" - the opaque credential failure this script
# exists to prevent. Fail here, where the cause can be named.
if not region:
    sys.exit(4)

# Shape-check the region for the same reason the role ARN is re-validated: agp.yml may reach
# this wrapper without having passed through Guide's validator, and both values are handed to a
# credential-configuring action.
if not re.fullmatch(r"[a-z]{2}(-[a-z]+)+-\d+", region):
    sys.exit(5)

print(f"role={role}")
print(f"region={region}")
PY
  ) || parse_rc=$?

  if [ "${parse_rc}" -eq 3 ]; then
    echo "::error::agent.awsRole or agent.awsRegion in the governed configuration contains a" \
      "control character (e.g. a newline).%0ABoth must be single-line values." >&2
    return 1
  fi
  if [ "${parse_rc}" -eq 4 ]; then
    echo "::error::agent.awsRole is set but agent.awsRegion is missing.%0ABoth are required for" \
      "the governed Bedrock role: aws-region is a mandatory input of the assume-role step." >&2
    return 1
  fi
  if [ "${parse_rc}" -eq 5 ]; then
    echo "::error::agent.awsRegion in the governed configuration is not a valid AWS region." \
      "%0AExpected e.g. us-west-2." >&2
    return 1
  fi
  if [ "${parse_rc}" -ne 0 ]; then
    echo "resolve-bedrock-role: config parse failed; skipping governed role" >&2
    return 0
  fi

  local role="" region=""
  while IFS= read -r line; do
    case "${line}" in
      role=*) role="${line#role=}" ;;
      region=*) region="${line#region=}" ;;
    esac
  done <<<"${parsed}"

  if [ -z "${role}" ]; then
    return 0
  fi

  # Re-validate: agp.yml is untrusted input and may not have passed through the CLI's schema.
  if [ "${#role}" -gt "${MAX_ROLE_ARN_LEN}" ] || ! printf '%s' "${role}" | grep -Eq "${IAM_ROLE_ARN_RE}"; then
    echo "::error::agent.awsRole in the governed configuration is not a valid IAM role ARN." \
      "%0AExpected e.g. arn:aws:iam::123456789012:role/agp-bedrock" >&2
    return 1
  fi

  printf 'role=%s\n' "${role}"
  if [ -n "${region}" ]; then
    printf 'region=%s\n' "${region}"
  fi
}

# validate_config_path <path>
# Same posture as gate.sh's validate_config_path: this reads the file the gate writes, so the two
# actions should agree on what a legitimate config-path is. Rejects empty values, absolute paths
# and any '..' path SEGMENT (matching '..' as a substring would wrongly reject 'agp..yml').
# Not attacker-crossable - a workflow author who can set config-path can already add steps - but
# divergent trust postures on the same input invite the looser one being treated as the contract.
validate_config_path() {
  local path="${1:-}" rest seg
  if [ -z "${path}" ]; then
    echo "::error::resolve-bedrock-role: config-path must not be empty." >&2
    return 1
  fi
  case "${path}" in
    /*)
      echo "::error::resolve-bedrock-role: config-path must be a relative path within the" \
        "workspace (got '${path}')." >&2
      return 1 ;;
  esac
  rest="${path}"
  while :; do
    seg="${rest%%/*}"
    if [ "${seg}" = ".." ]; then
      echo "::error::resolve-bedrock-role: config-path must not contain '..' path segments" \
        "(got '${path}')." >&2
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
  local config_path="${CONFIG_PATH:-agp.yml}"
  validate_config_path "${config_path}" || return 1
  local config_file="${config_path}"
  # Resolve against the workspace, matching how the gate writes it. Paths are relative by the
  # check above, so no tilde or absolute handling is needed here.
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    config_file="${GITHUB_WORKSPACE}/${config_path}"
  fi

  local out
  out=$(resolve_bedrock_role "${config_file}")

  if [ -n "${out}" ]; then
    # Log the role so the audit trail shows which principal was assumed. An ARN is an
    # identifier, not a credential, so this is safe to print.
    while IFS= read -r line; do
      [ -n "${line}" ] && echo "resolve-bedrock-role: ${line}"
    done <<<"${out}"
    printf '%s\n' "${out}" >>"${GITHUB_OUTPUT}"
  else
    # Name the file that was inspected. config-path is declared independently on the gate action
    # and on this one, so a consumer who points the gate at a custom path and forgets to mirror it
    # here gets a skip; printing the path makes that mismatch visible instead of leaving it to be
    # diagnosed from a downstream credential error.
    echo "resolve-bedrock-role: no governed Bedrock role in ${config_file};" \
      "leaving credentials as-is"
  fi
}

# Only run main when executed, so the test script can source this file and exercise
# resolve_bedrock_role directly.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
