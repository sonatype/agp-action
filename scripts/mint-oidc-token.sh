#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# mint-oidc-token.sh <audience>
#
# Mints a short-lived GitHub Actions OIDC token for the given audience and
# prints the raw token to stdout (and nothing else). Shared by
# scripts/prepare-auth.sh and gate/action.yml so the OIDC-minting logic lives
# in exactly one place instead of being copy-pasted between them.
#
# Diagnostics go to stderr; the CALLER is responsible for masking the returned
# token (`echo "::add-mask::$TOKEN"`) because this script's stdout is captured
# via command substitution and must contain only the token.
#
# Required environment (present when the job declares `permissions: id-token: write`):
#   ACTIONS_ID_TOKEN_REQUEST_URL
#   ACTIONS_ID_TOKEN_REQUEST_TOKEN

set -euo pipefail

AUDIENCE="${1:-}"
if [ -z "$AUDIENCE" ]; then
  echo "::error::mint-oidc-token.sh: missing required <audience> argument." >&2
  exit 1
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  echo "::error::OIDC unavailable: the job must declare 'permissions: id-token: write'." >&2
  exit 1
fi

# Bounded timeouts + a small retry/backoff: a transient network blip shouldn't fail the
# whole run, and a hung token endpoint must not stall the runner indefinitely. The
# trailing `|| true` lets the empty-token check below emit a friendly error instead of
# `set -e` aborting on a curl/jq pipeline failure.
TOKEN="$(curl -fsSL \
  --connect-timeout 5 --max-time 30 \
  --retry 3 --retry-delay 2 --retry-connrefused \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}" | jq -r '.value // empty' || true)"

if [ -z "$TOKEN" ]; then
  echo "::error::Failed to acquire a GitHub Actions OIDC token (id-token: write missing, or the token endpoint errored)." >&2
  exit 1
fi

printf '%s' "$TOKEN"
