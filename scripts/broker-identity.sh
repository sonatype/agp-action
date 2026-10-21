#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# Sourced by prepare-auth.sh and prepare-auth_test.sh; defines functions only.

DEFAULT_BROKER_URL="https://api.guide.sonatype.com"
SONATYPE_GUIDE_BOT_LOGIN="sonatype-guide[bot]"
# GET https://api.github.com/users/sonatype-guide[bot] -> .id
SONATYPE_GUIDE_BOT_ID="262430933"

# Sets ACTOR_LOGIN, ACTOR_ID and AUTH_SOURCE, and fills GIT_NAME / GIT_EMAIL only where they are empty, from the
# minting App's bot that the broker names in `actor`. The broker is the only authority for it: it is already trusted
# with the token, so a wrong actor misattributes commits but grants nothing.
resolve_broker_identity() {
  local resp_body="$1" api_url="$2"
  local actor_type login="" id="" problem=""
  actor_type=$(jq -r 'if type == "object" and .actor != null then (.actor | type) else "absent" end' \
    "$resp_body" 2>/dev/null || echo absent)
  if [ "$actor_type" = "object" ]; then
    login=$(jq -r '.actor.login // empty' "$resp_body")
    id=$(jq -r '.actor.id // empty' "$resp_body")
    if [[ ! "$login" =~ ^[A-Za-z0-9-]{1,39}\[bot\]$ ]]; then
      problem="its login is not a GitHub bot login"
    elif [[ ! "$id" =~ ^[1-9][0-9]*$ ]]; then
      problem="its id is not a positive number"
    fi
  elif [ "$actor_type" != "absent" ]; then
    problem="it is not an object"
  fi

  if [ "$actor_type" != "object" ] || [ -n "$problem" ]; then
    if [ -n "$problem" ]; then
      echo "::warning::Ignoring the broker's actor because ${problem}; falling back to the sonatype-guide[bot] default identity."
    fi
    if [ "${api_url%/}" != "$DEFAULT_BROKER_URL" ] && { [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; }; then
      echo "::notice::The broker at ${api_url} named no commit identity, so commits default to sonatype-guide[bot]. To credit your own App's bot, set the git-user-name and git-user-email inputs."
    fi
    login="$SONATYPE_GUIDE_BOT_LOGIN"
    id="$SONATYPE_GUIDE_BOT_ID"
  fi

  ACTOR_LOGIN="$login"
  ACTOR_ID="$id"
  # shellcheck disable=SC2034
  AUTH_SOURCE="$ACTOR_LOGIN via OIDC broker"
  if [ -z "$GIT_NAME" ]; then
    GIT_NAME="$ACTOR_LOGIN"
  fi
  if [ -z "$GIT_EMAIL" ]; then
    GIT_EMAIL="${ACTOR_ID}+${ACTOR_LOGIN}@users.noreply.github.com"
  fi
}

# Annotates a likely mismatch between the OIDC audience and the broker it is sent to. Warns only, never fails.
warn_on_audience_broker_mismatch() {
  local audience="$1" api_url="$2"
  if [ -n "$audience" ] && [ "${api_url%/}" = "$DEFAULT_BROKER_URL" ]; then
    echo "::warning::audience is set but AGP_API_URL is the Sonatype cloud broker; a token addressed to ${audience} will be refused there. Set AGP_API_URL to the same installation"
  elif [ -z "$audience" ] && [ "${api_url%/}" != "$DEFAULT_BROKER_URL" ]; then
    echo "::notice::The token is addressed to Sonatype's cloud audience although AGP_API_URL points to ${api_url}. For a self-hosted installation, set audience to the same installation."
  fi
}
