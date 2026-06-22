#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# prepare-auth.sh — choose and materialize the token/identity used by the AGP
# action to push commits and open pull requests.
#
# Invoked from action.yml as the "Prepare GitHub authentication" step. Writes
# four key=value pairs to $GITHUB_OUTPUT which the "Run AGP" step reads:
#
#   token            — bearer token for git push and gh pr create
#   git-user-name    — commit author/committer name
#   git-user-email   — commit author/committer email
#   auth-source      — human-readable source, used only for the status line in
#                      the action log
#
# Precedence (first match wins):
#
#   1. $INPUT_GITHUB_TOKEN — explicit override supplied via the action's
#      `github-token` input. Used for air-gapped runners, GitHub Enterprise
#      Server without OIDC federation, or local debugging. PRs are authored
#      by whoever owns the supplied token.
#
#   2. GitHub Actions OIDC → Sonatype Guide broker — the default. Requires
#      `permissions: id-token: write` on the job and the Sonatype Guide App
#      installed on the repo. Mints a GitHub App installation access token
#      scoped to the repo with contents:write + pull_requests:write so PRs
#      open as sonatype-guide[bot].
#
#   3. $GITHUB_TOKEN — legacy backward-compat path. Workflow exported the
#      token the old way (pre-OIDC). Emits a deprecation warning and keeps
#      going so existing customer workflows don't break.
#
#   4. Fail loud with remediation instructions.
#
# Required environment:
#   GITHUB_OUTPUT                  — path provided by the Actions runtime
#
# Optional environment (any of these may be empty):
#   INPUT_GITHUB_TOKEN             — from action input `github-token`
#   INPUT_GIT_USER_NAME            — from action input `git-user-name`
#   INPUT_GIT_USER_EMAIL           — from action input `git-user-email`
#   ACTIONS_ID_TOKEN_REQUEST_URL   — set by runtime when id-token: write is on
#   ACTIONS_ID_TOKEN_REQUEST_TOKEN — set by runtime when id-token: write is on
#   AGP_API_URL                    — override broker URL (defaults to prod)
#   GITHUB_TOKEN                   — legacy env-var-based auth

set -euo pipefail

# Normalise optional inputs so 'set -u' doesn't trip on them.
INPUT_GITHUB_TOKEN="${INPUT_GITHUB_TOKEN:-}"
INPUT_GIT_USER_NAME="${INPUT_GIT_USER_NAME:-}"
INPUT_GIT_USER_EMAIL="${INPUT_GIT_USER_EMAIL:-}"

TOKEN=""
GIT_NAME="$INPUT_GIT_USER_NAME"
GIT_EMAIL="$INPUT_GIT_USER_EMAIL"
AUTH_SOURCE="unknown"

if [ -n "$INPUT_GITHUB_TOKEN" ]; then
  # Explicit override: customer passed a PAT or workflow-scoped token.
  # Do NOT fall through to the broker if this is set, even if OIDC is
  # also available — the input is the customer's way to opt out.
  TOKEN="$INPUT_GITHUB_TOKEN"
  AUTH_SOURCE="github-token input"
  echo "🔑 Using customer-supplied github-token input"

elif [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  echo "🔑 Acquiring installation token via Sonatype Guide OIDC broker"
  API_URL="${AGP_API_URL:-https://api.guide.sonatype.com}"

  # Step 1: request an OIDC JWT from the GitHub Actions runtime. The minting logic
  # (timeouts, retries, error handling) is shared with gate/action.yml via
  # scripts/mint-oidc-token.sh so the two callers cannot drift apart.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  OIDC_JWT=$("$SCRIPT_DIR/mint-oidc-token.sh" "https://guide.sonatype.com")
  echo "::add-mask::$OIDC_JWT"

  # Step 2: exchange the JWT for a scoped installation token.
  RESP_BODY=$(mktemp)
  trap 'rm -f "$RESP_BODY"' EXIT
  RESP_STATUS=$(curl -sS -o "$RESP_BODY" -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $OIDC_JWT" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data '{}' \
    "${API_URL}/agp/installation-token")
  if [ "$RESP_STATUS" != "200" ]; then
    echo "::error::Sonatype Guide token broker returned HTTP $RESP_STATUS"
    echo "Response: $(cat "$RESP_BODY")"
    echo ""
    echo "Common causes:"
    echo "  - The Sonatype Guide GitHub App is not installed on this repository."
    echo "    Install it: https://github.com/apps/sonatype-guide"
    echo "  - The job is not running via sonatype/agp-action (required by"
    echo "    the broker's job_workflow_ref policy)."
    echo "  - The job is missing 'permissions: id-token: write'."
    exit 1
  fi
  TOKEN=$(jq -r '.token // empty' "$RESP_BODY")
  if [ -z "$TOKEN" ]; then
    echo "::error::Sonatype Guide token broker response missing 'token' field"
    echo "Response: $(cat "$RESP_BODY")"
    exit 1
  fi
  echo "::add-mask::$TOKEN"
  AUTH_SOURCE="sonatype-guide[bot] via OIDC broker"

  # Step 3: default commit identity to sonatype-guide[bot] when the broker
  # minted the token. The numeric user ID is required so GitHub shows the
  # 'Verified · by sonatype-guide[bot]' badge on commits (this is the
  # documented formula from GitHub's actions/create-github-app-token README).
  if [ -z "$GIT_NAME" ]; then
    GIT_NAME="sonatype-guide[bot]"
  fi
  if [ -z "$GIT_EMAIL" ]; then
    BOT_USER_ID=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/users/sonatype-guide%5Bbot%5D" \
      | jq -r '.id // empty')
    if [ -z "$BOT_USER_ID" ]; then
      echo "::warning::Could not resolve sonatype-guide[bot] user ID; falling back to app email without numeric prefix. The Verified bot badge will not appear on commits."
      GIT_EMAIL="sonatype-guide[bot]@users.noreply.github.com"
    else
      GIT_EMAIL="${BOT_USER_ID}+sonatype-guide[bot]@users.noreply.github.com"
    fi
  fi

elif [ -n "${GITHUB_TOKEN:-}" ]; then
  # Legacy backward-compat path: workflow exported env.GITHUB_TOKEN the
  # old way (no id-token: write declared, no github-token input given).
  # PRs produced this way will be authored by whoever owns the token
  # — typically github-actions[bot]. We warn, but we do not fail so
  # existing workflows keep working until they migrate.
  TOKEN="$GITHUB_TOKEN"
  AUTH_SOURCE="env.GITHUB_TOKEN (legacy)"
  echo "::warning::Using env.GITHUB_TOKEN (legacy). PRs will not be authored by sonatype-guide[bot]. To switch: add 'permissions: id-token: write' to the job and remove the GITHUB_TOKEN env var."

else
  echo "::error::No github-token provided and GitHub Actions OIDC is unavailable."
  echo "Either set 'permissions: { id-token: write }' on the job (recommended),"
  echo "or pass a 'github-token' input with the desired write-scoped token."
  exit 1
fi

# Fallback identity when broker is NOT used and customer didn't override:
# keep the historical defaults so pre-existing workflows still work.
[ -z "$GIT_NAME" ] && GIT_NAME="AGP Bot"
[ -z "$GIT_EMAIL" ] && GIT_EMAIL="agp-bot@sonatype.com"

{
  echo "token=$TOKEN"
  echo "git-user-name=$GIT_NAME"
  echo "git-user-email=$GIT_EMAIL"
  echo "auth-source=$AUTH_SOURCE"
} >> "$GITHUB_OUTPUT"

echo "✅ Authenticated as: $AUTH_SOURCE"
echo "   git user: $GIT_NAME <$GIT_EMAIL>"
