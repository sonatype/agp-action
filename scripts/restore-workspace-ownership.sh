#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# restore-workspace-ownership.sh — give the checkout back to the runner user after the AGP
# container exits. The image chowns the workspace to its agp user (uid 10000) and never restores
# it, which makes actions/checkout's post-job cleanup fail to remove its credential header.
#
# Runs after the container has exited, so no build process can race the walk. The one-shot root
# container has no network, a read-only root, only CHOWN and DAC_READ_SEARCH, and mounts only the
# workspace. `chown -h` never follows symlinks. Failures are warnings, never job failures.
#
# Usage: restore-workspace-ownership.sh <docker-image> <workspace-dir>

set -euo pipefail

readonly CONTAINER_MOUNT="/workspace"

# Accept only an existing absolute directory that is not a top-level system directory, and whose
# path is safe for `docker run --mount` (a comma would add mount options).
validate_workspace() {
  local dir="$1"
  while [ "${#dir}" -gt 1 ] && [ "${dir%/}" != "${dir}" ]; do dir="${dir%/}"; done
  case "${dir}" in
    /*) ;;
    *) return 1 ;;
  esac
  case "${dir}" in
    *,* | *$'\n'* | *$'\r'*) return 1 ;;
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var) return 1 ;;
  esac
  [ -d "${dir}" ] && [ ! -L "${dir}" ]
}

build_command() {
  local image="$1" workspace="$2" uid="$3" gid="$4"
  printf '%s\n' \
    run --rm --pull never --user 0:0 \
    --network none --read-only \
    --security-opt no-new-privileges \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_READ_SEARCH \
    --mount "type=bind,source=${workspace},target=${CONTAINER_MOUNT}" \
    --entrypoint chown \
    "${image}" \
    -hR "${uid}:${gid}" "${CONTAINER_MOUNT}"
}

main() {
  local image="${1:-}" workspace="${2:-}"

  if [ -z "${image}" ] || [ -z "${workspace}" ]; then
    echo "::warning::restore-workspace-ownership: usage: <docker-image> <workspace-dir>"
    return 0
  fi
  if ! validate_workspace "${workspace}"; then
    echo "::warning::restore-workspace-ownership: refusing workspace '${workspace}' (not an absolute, non-system directory)"
    return 0
  fi
  # No image means no container ever ran; never pull here.
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "restore-workspace-ownership: image ${image} is not present, nothing to restore"
    return 0
  fi

  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  local -a args=()
  while IFS= read -r line; do args+=("${line}"); done < <(build_command "${image}" "${workspace}" "${uid}" "${gid}")

  if docker "${args[@]}"; then
    echo "restore-workspace-ownership: workspace ownership restored to ${uid}:${gid}"
  else
    echo "::warning::restore-workspace-ownership: could not restore workspace ownership; checkout cleanup may warn"
  fi
}

# Run main only when executed directly, so the test can source this file.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
