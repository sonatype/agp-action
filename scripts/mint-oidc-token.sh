#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# mint-oidc-token.sh [audience]
#
# Mints a short-lived GitHub Actions OIDC token for the given audience and
# prints the raw token to stdout (and nothing else). Shared by
# scripts/prepare-auth.sh and gate/action.yml so the OIDC-minting logic lives
# in exactly one place instead of being copy-pasted between them.
#
# The audience argument is optional and defaults to DEFAULT_GUIDE_AUDIENCE below,
# which is the canonical Sonatype Guide OIDC audience. gate/action.yml exposes it
# as the overridable `audience` input (whose YAML default must mirror this value).
#
# Diagnostics go to stderr; the CALLER is responsible for masking the returned
# token (`echo "::add-mask::$TOKEN"`) because this script's stdout is captured
# via command substitution and must contain only the token.
#
# Required environment (present when the job declares `permissions: id-token: write`):
#   ACTIONS_ID_TOKEN_REQUEST_URL
#   ACTIONS_ID_TOKEN_REQUEST_TOKEN

set -euo pipefail

# Canonical Sonatype Guide OIDC audience. This is the single source of truth for
# callers that don't override it (e.g. scripts/prepare-auth.sh). Keep it in sync with
# the `audience` input default in gate/action.yml.
DEFAULT_GUIDE_AUDIENCE="https://guide.sonatype.com"
AUDIENCE="${1:-$DEFAULT_GUIDE_AUDIENCE}"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  echo "::error::OIDC unavailable: the job must declare 'permissions: id-token: write'." >&2
  exit 1
fi

# Bounded timeouts + a small retry/backoff: a transient network blip shouldn't fail the
# whole run, and a hung token endpoint must not stall the runner indefinitely. The
# trailing `|| true` lets the empty-token check below emit a friendly error instead of
# `set -e` aborting on a curl/jq pipeline failure.
# `-G --data-urlencode` appends audience as a properly URL-encoded query parameter so
# reserved characters can't corrupt the request or alter the token's `aud` claim.
# No -L: like gate.sh's credentialed fetch, this request carries a bearer credential,
# so it must not follow redirects to another host.
TOKEN="$(curl -fsS -G \
  --connect-timeout 5 --max-time 30 \
  --retry 3 --retry-delay 2 --retry-connrefused \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  --data-urlencode "audience=${AUDIENCE}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}" | jq -r '.value // empty' || true)"

if [ -z "$TOKEN" ]; then
  echo "::error::Failed to acquire a GitHub Actions OIDC token (id-token: write missing, or the token endpoint errored)." >&2
  exit 1
fi

printf '%s' "$TOKEN"
