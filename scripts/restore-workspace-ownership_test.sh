#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# restore-workspace-ownership_test.sh — tests for scripts/restore-workspace-ownership.sh.
# Unit tests use a stub docker. The integration test needs Linux and docker (Docker Desktop on
# macOS does not apply chown to host files faithfully).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/restore-workspace-ownership.sh
source "${SCRIPT_DIR}/restore-workspace-ownership.sh"

fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "ok   - ${desc} (=> ${actual})"
  else
    echo "FAIL - ${desc}: expected '${expected}', got '${actual}'"
    fail=1
  fi
}

TMP="$(mktemp -d)"
# Files left owned by other uids cannot be deleted by the invoking user; hand them back first.
INTEGRATION_IMAGE=""
cleanup() {
  if [ -n "${INTEGRATION_IMAGE}" ]; then
    docker run --rm --user 0:0 --mount "type=bind,source=${TMP},target=/t" \
      "${INTEGRATION_IMAGE}" chown -hR "$(id -u):$(id -g)" /t >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT
mkdir -p "${TMP}/ws" "${TMP}/real"
ln -s "${TMP}/real" "${TMP}/link"

# --- validate_workspace ---
accepts() { if validate_workspace "$1" 2>/dev/null; then echo accept; else echo reject; fi; }

check "accepts an existing absolute directory"     "accept" "$(accepts "${TMP}/ws")"
check "accepts a trailing slash"                   "accept" "$(accepts "${TMP}/ws/")"
check "rejects an empty path"                      "reject" "$(accepts "")"
check "rejects a relative path"                    "reject" "$(accepts "ws")"
check "rejects the filesystem root"                "reject" "$(accepts "/")"
check "rejects the root with extra slashes"        "reject" "$(accepts "//")"
check "rejects /etc"                               "reject" "$(accepts "/etc")"
check "rejects /usr/"                              "reject" "$(accepts "/usr/")"
check "rejects a missing directory"                "reject" "$(accepts "${TMP}/missing")"
check "rejects a symlinked workspace"              "reject" "$(accepts "${TMP}/link")"
check "rejects a comma that would add mount opts"  "reject" "$(accepts "${TMP}/a,readonly=false")"
check "rejects a newline in the path"              "reject" "$(accepts "$(printf '%s/a\nb' "${TMP}")")"

# --- build_command carries every hardening flag, and nothing else is mounted ---
cmd="$(build_command "img:1" "/work/ws" 1001 1002 | tr '\n' ' ')"
has() { case " ${cmd}" in *" $1 "*) echo present ;; *) echo missing ;; esac; }

check "runs with --rm"                       "present" "$(has --rm)"
check "never pulls an image"                 "present" "$(has "--pull never")"
check "disables the network"                 "present" "$(has "--network none")"
check "uses a read-only root filesystem"     "present" "$(has --read-only)"
check "sets no-new-privileges"               "present" "$(has "--security-opt no-new-privileges")"
check "drops all capabilities"               "present" "$(has "--cap-drop ALL")"
check "adds CHOWN"                           "present" "$(has "--cap-add CHOWN")"
check "adds DAC_READ_SEARCH"                 "present" "$(has "--cap-add DAC_READ_SEARCH")"
check "does not add DAC_OVERRIDE"            "missing" "$(has "--cap-add DAC_OVERRIDE")"
check "overrides the entrypoint with chown"  "present" "$(has "--entrypoint chown")"
check "does not follow symlinks (-hR)"       "present" "$(has "-hR 1001:1002 /workspace")"
check "mounts only the workspace"            "1"       "$(build_command img /work/ws 1 2 | grep -c '^--mount$')"
check "does not mount the docker socket"     "missing" "$(has "docker.sock")"
check "does not forward environment"         "missing" "$(has "-e")"

# --- main against a stub docker ---
STUB="${TMP}/bin"
mkdir -p "${STUB}"
CALLS="${TMP}/calls"
: > "${CALLS}"
write_stub() {
  # $1 = exit code of `docker image inspect`, $2 = exit code of `docker run`
  cat > "${STUB}/docker" <<STUBEOF
#!/usr/bin/env bash
echo "\$*" >> "${CALLS}"
case "\$1" in
  image) exit $1 ;;
  run) exit $2 ;;
esac
exit 0
STUBEOF
  chmod +x "${STUB}/docker"
  : > "${CALLS}"
}
runs_main() { PATH="${STUB}:${PATH}" main "$@" 2>&1; echo "rc=$?"; }

write_stub 0 0
out="$(runs_main img:1 "${TMP}/ws")"
check "runs docker when the image is present"   "1"   "$(grep -c '^run ' "${CALLS}")"
check "reports success"                         "1"   "$(printf '%s' "${out}" | grep -c 'ownership restored')"
check "exits 0 on success"                      "1"   "$(printf '%s' "${out}" | grep -c 'rc=0')"

write_stub 1 0
out="$(runs_main img:1 "${TMP}/ws")"
check "does not run docker when image is absent" "0"  "$(grep -c '^run ' "${CALLS}")"
check "exits 0 when image is absent"             "1"  "$(printf '%s' "${out}" | grep -c 'rc=0')"

write_stub 0 1
out="$(runs_main img:1 "${TMP}/ws")"
check "warns when docker run fails"              "1"  "$(printf '%s' "${out}" | grep -c '::warning::')"
check "still exits 0 when docker run fails"      "1"  "$(printf '%s' "${out}" | grep -c 'rc=0')"

write_stub 0 0
out="$(runs_main img:1 /etc)"
check "refuses /etc without calling docker run"  "0"  "$(grep -c '^run ' "${CALLS}")"
check "warns on a refused workspace"             "1"  "$(printf '%s' "${out}" | grep -c '::warning::')"
out="$(runs_main "" "${TMP}/ws")"
check "warns on a missing image argument"        "1"  "$(printf '%s' "${out}" | grep -c '::warning::')"

# --- integration: real container, Linux only ---
if [ "$(uname -s)" = "Linux" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  IMG="${RESTORE_TEST_IMAGE:-alpine:3.22}"
  INTEGRATION_IMAGE="${IMG}"
  docker image inspect "${IMG}" >/dev/null 2>&1 || docker pull -q "${IMG}" >/dev/null
  WS="${TMP}/integration"
  OUTSIDE="${TMP}/outside/target"
  mkdir -p "${WS}" "${TMP}/outside"
  echo secret > "${OUTSIDE}"
  # Owned by a third uid so following the symlink would visibly change it.
  docker run --rm --user 0:0 --mount "type=bind,source=${TMP}/outside,target=/o" "${IMG}" \
    chown -R 12345:12345 /o
  ln -s "${OUTSIDE}" "${WS}/outside-link"
  # What the AGP container leaves behind: uid 10000 files, a 0700 directory, a dangling symlink.
  docker run --rm --user 0:0 --mount "type=bind,source=${WS},target=/w" "${IMG}" sh -c '
    mkdir -m 700 /w/priv && echo x > /w/priv/f && chmod 600 /w/priv/f
    echo c > /w/config
    ln -s /nonexistent /w/dangling
    chown -hR 10000:10000 /w'
  before="$(stat -c '%u' "${OUTSIDE}")"
  me="$(id -u)"
  check "integration: fixture starts owned by uid 10000" "10000" "$(stat -c '%u' "${WS}/priv")"
  main "${IMG}" "${WS}" >/dev/null 2>&1 || true
  check "integration: workspace root restored"          "${me}" "$(stat -c '%u' "${WS}/config")"
  check "integration: 0700 directory restored"          "${me}" "$(stat -c '%u' "${WS}/priv")"
  check "integration: file inside 0700 dir restored"    "${me}" "$(stat -c '%u' "${WS}/priv/f")"
  check "integration: dangling symlink restored"        "${me}" "$(stat -c '%u' "${WS}/dangling")"
  check "integration: symlink target starts owned by uid 12345" "12345" "${before}"
  check "integration: symlink target outside untouched" "12345" "$(stat -c '%u' "${OUTSIDE}")"
else
  echo "skip - integration test (needs Linux and a running docker)"
fi

if [ "${fail}" -ne 0 ]; then
  echo "restore-workspace-ownership_test.sh: FAILURES"
  exit 1
fi
echo "restore-workspace-ownership_test.sh: all tests passed"
