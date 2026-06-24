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
# whole run, and a hung token endpoint must not stall the runner indefinitely. Worst case
# ≈ 3 attempts × 10s plus backoff (~36s). --retry-all-errors matches gate.sh so a transient
# 5xx from the token endpoint is retried too.
# `-G --data-urlencode` appends audience as a properly URL-encoded query parameter so
# reserved characters can't corrupt the request or alter the token's `aud` claim.
# No -L: like gate.sh's credentialed fetch, this request carries a bearer credential, so it
# must not follow redirects to another host.
#
# We deliberately drop -f and capture the HTTP status (-w) and body separately so a failure
# can report the real status code + a body snippet (mirroring gate.sh) instead of a generic
# "no token" message. The fallback is applied OUTSIDE the substitution: only a transport
# failure makes curl print 000 and exit non-zero.
RESP_BODY="$(mktemp)"
trap 'rm -f "${RESP_BODY}"' EXIT
HTTP_CODE="$(curl -sS -G \
  --connect-timeout 5 --max-time 10 \
  --retry 2 --retry-delay 2 --retry-connrefused --retry-all-errors \
  -o "${RESP_BODY}" -w '%{http_code}' \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  --data-urlencode "audience=${AUDIENCE}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}")" || HTTP_CODE="000"

# Non-200: the body is an error envelope (not a credential), so it is safe to log a short,
# sanitised snippet. id-token: write is already validated above, so the cause is the token
# endpoint itself. The ':' -> '_' pass defangs any '::' workflow-command injection.
if [ "${HTTP_CODE}" != "200" ]; then
  BODY_SNIPPET="$(head -c 300 "${RESP_BODY}" 2>/dev/null | LC_ALL=C tr -d '[:cntrl:]' | tr ':' '_' || true)"
  echo "::error::Failed to acquire a GitHub Actions OIDC token: token endpoint returned HTTP ${HTTP_CODE}${BODY_SNIPPET:+ (body: ${BODY_SNIPPET})}." >&2
  exit 1
fi

# HTTP 200: the body legitimately contains the token, so it must NEVER be echoed here.
# Parse strictly and report only the failure shape, never the body.
if ! TOKEN="$(jq -r '.value // empty' < "${RESP_BODY}")"; then
  echo "::error::OIDC token endpoint returned HTTP 200 but the response was not valid JSON." >&2
  exit 1
fi
if [ -z "${TOKEN}" ]; then
  echo "::error::OIDC token endpoint returned HTTP 200 with no '.value' field." >&2
  exit 1
fi

# The CALLER masks the token (echo ::add-mask::) because this script's stdout is captured
# via command substitution; emitting the mask here would either pollute that capture (stdout)
# or risk leaking the raw token to the log if the runner doesn't parse commands from stderr.
printf '%s' "${TOKEN}"
