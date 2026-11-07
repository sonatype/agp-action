#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# restore-workspace-ownership.sh — hand the checkout back to the runner user after the AGP
# container has exited.
#
# Why this exists: the AGP image starts as root and runs `chown -R agp:agp .` on the bind-mounted
# workspace so that its non-root `agp` user (uid 10000) can write to it. When the container exits
# the whole checkout, including .git/config, is still owned by uid 10000. The runner then cannot
# take the .git/config lock, so actions/checkout's post-job cleanup cannot remove its persisted
# `http.https://github.com/.extraheader` entry and reports
#   Failed to remove 'http.https://github.com/.extraheader' from the git config
# and any later step in the job that writes to the workspace hits the same permission error.
#
# How: one short-lived container from the image that was already pulled for the AGP run, run as
# root with only the two capabilities `chown` needs (CHOWN, plus DAC_READ_SEARCH to traverse a
# directory the agp user created with mode 0700). It runs AFTER the AGP container has exited, so
# no process of the untrusted build is left to swap a path for a symlink while root is walking the
# tree. It needs no `sudo` on the host, so it also works on self-hosted runners.
#
# Hardening of that container, and why:
#   chown -h        never dereference a symlink, so a link the build planted in the workspace
#                   cannot make root change the owner of anything outside it. (-R already does
#                   not traverse symlinks; -h also stops the link itself being followed.)
#   --network none  nothing to reach, nothing to exfiltrate over
#   --read-only     the container writes nothing but file metadata under the mount
#   --cap-drop ALL  plus CHOWN and DAC_READ_SEARCH only (CHOWN alone fails on a 0700 directory)
#   no-new-privileges, and --pull never so a missing image can never trigger a download here
#   only the workspace is mounted: no docker socket, no credential files, no environment
#
# Best effort by design: a failure here only leaves the ownership as it was, so it is reported as
# a warning and never fails the job.
#
# Usage: restore-workspace-ownership.sh <docker-image> <workspace-dir>

set -euo pipefail

# The mount point inside the throwaway container. Never user-controlled.
readonly CONTAINER_MOUNT="/workspace"

# validate_workspace <dir> — accept only an existing, absolute directory that is not a top-level
# system directory and whose path is safe to hand to `docker run --mount` (a comma would add
# mount options). Only the top-level directories themselves are refused: a runner workspace
# legitimately lives under /var/lib or /opt on self-hosted machines.
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

# build_command <image> <workspace> <uid> <gid> — print the docker argument vector, one per line.
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
  # The AGP step may have stopped before the image was pulled; then no container ever ran and
  # there is nothing to restore. Do not pull it here.
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

# Run main only when executed directly, not when sourced (scripts/restore-workspace-ownership_test.sh
# sources this file to test the validation and the command it builds without running docker).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
