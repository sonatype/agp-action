#!/usr/bin/env bash
#
# Copyright (c) 2011-present Sonatype, Inc. All rights reserved.
# Includes the third-party code listed at http://links.sonatype.com/products/clm/attributions.
# "Sonatype" is a trademark of Sonatype, Inc.
#
# gate_test.sh — unit tests for scripts/gate.sh. Sources gate.sh (which does NOT run main
# when sourced) and exercises the directive parsing/normalisation, the base-url /
# config-path validators — the safety-critical, network-free logic of the gate — and the
# git-exclude bookkeeping (against real throwaway repositories).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Behavioural guard check (the guard at the bottom of gate.sh is what stops main from
# running when we source it). Sourcing in a child shell must reach the sentinel — if the
# guard is removed/broken, main runs and aborts under `set -u` before the sentinel prints.
# This is robust to cosmetic refactors of the guard line (unlike a literal grep).
if [ "$(bash -c "source '${SCRIPT_DIR}/gate.sh'; echo GUARD_OK" 2>/dev/null)" != "GUARD_OK" ]; then
  echo "FAIL - sourcing gate.sh ran main() (the 'run only when executed directly' guard is missing/broken)" >&2
  exit 1
fi

# shellcheck source=scripts/gate.sh
source "${SCRIPT_DIR}/gate.sh"

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

# ok_status <fn> <arg...> — run a validator, swallowing its stderr, print accept/reject.
ok_status() { local fn="$1"; shift; if "${fn}" "$@" 2>/dev/null; then echo accept; else echo reject; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- directive parsing (parse_directive_file: extract + normalise from a headers file) ---
printf 'HTTP/2 200\r\nContent-Type: application/yaml\r\n\r\n'  > "${tmp}/none"
printf 'HTTP/2 200\r\nx-agp-directive: run\r\n\r\n'            > "${tmp}/run"
printf 'HTTP/2 200\r\nx-agp-directive: paused\r\n\r\n'         > "${tmp}/paused"
printf 'HTTP/2 200\r\nx-agp-directive:paused\r\n\r\n'          > "${tmp}/nospace"
printf 'HTTP/2 200\r\nx-agp-directive: paused \r\n\r\n'        > "${tmp}/trailing"
printf 'HTTP/2 200\r\nX-AGP-Directive: RUN\r\n\r\n'            > "${tmp}/upper"
printf 'HTTP/2 200\r\nx-agp-directive: maybe\r\n\r\n'          > "${tmp}/unknown"
printf 'HTTP/2 200\r\nx-agp-directive:\r\n\r\n'                > "${tmp}/empty"
printf 'HTTP/2 200\r\nx-agp-directive: run\r\nx-agp-directive: paused\r\n\r\n' > "${tmp}/dup"
# Multi-block: curl -D appends every retry attempt's headers; only the FINAL block counts.
printf 'HTTP/1.1 503 Service Unavailable\r\nx-agp-directive: paused\r\n\r\nHTTP/2 200\r\nx-agp-directive: run\r\n\r\n' > "${tmp}/retry_run"
printf 'HTTP/1.1 503 Service Unavailable\r\nx-agp-directive: run\r\n\r\nHTTP/2 200\r\nx-agp-directive: paused\r\n\r\n' > "${tmp}/retry_paused"
printf 'HTTP/1.1 502 Bad Gateway\r\n\r\nHTTP/2 200\r\nContent-Type: application/yaml\r\n\r\n' > "${tmp}/retry_none"

check "absent header -> run (active default)" "run"    "$(parse_directive_file "${tmp}/none")"
check "explicit run -> run"                   "run"    "$(parse_directive_file "${tmp}/run")"
check "explicit paused -> paused"             "paused" "$(parse_directive_file "${tmp}/paused")"
check "paused without space after colon"      "paused" "$(parse_directive_file "${tmp}/nospace")"
check "paused with trailing whitespace"       "paused" "$(parse_directive_file "${tmp}/trailing")"
check "uppercase RUN -> run"                  "run"    "$(parse_directive_file "${tmp}/upper")"
check "unknown value -> paused (fail-closed)" "paused" "$(parse_directive_file "${tmp}/unknown")"
check "empty value -> paused (fail-closed)"   "paused" "$(parse_directive_file "${tmp}/empty")"
check "duplicate headers -> paused (ambig.)"  "paused" "$(parse_directive_file "${tmp}/dup")"
check "retry block: final 200 run wins"       "run"    "$(parse_directive_file "${tmp}/retry_run")"
check "retry block: final 200 paused wins"    "paused" "$(parse_directive_file "${tmp}/retry_paused")"
check "retry block: final 200 no header -> run" "run"  "$(parse_directive_file "${tmp}/retry_none")"

# parse_directive_file must fail-closed (non-zero) on a missing/unreadable headers file.
check "missing headers file rejected"         "reject" "$(if parse_directive_file "${tmp}/does-not-exist" >/dev/null 2>&1; then echo accept; else echo reject; fi)"

# normalize_directive decision logic (count-driven), independent of any file.
check "normalize count=0 -> run"              "run"    "$(normalize_directive 0 '')"
check "normalize count>1 -> paused"           "paused" "$(normalize_directive 2 'run')"
check "normalize single unknown -> paused"    "paused" "$(normalize_directive 1 'quarantine')"

# --- HTTPS-only / safe-host refusal (guards against leaking the OIDC bearer token) ---
check "https host accepted"                   "accept" "$(ok_status validate_base_url 'https://api.guide.sonatype.com')"
check "https host with port accepted"         "accept" "$(ok_status validate_base_url 'https://api.guide.sonatype.com:8443/x')"
check "http rejected"                         "reject" "$(ok_status validate_base_url 'http://api.guide.sonatype.com')"
check "non-http scheme rejected"              "reject" "$(ok_status validate_base_url 'ftp://evil.example')"
check "empty base url rejected"               "reject" "$(ok_status validate_base_url '')"
check "userinfo host rejected"                "reject" "$(ok_status validate_base_url 'https://user:pass@evil.example')"
check "empty-authority https:// rejected"     "reject" "$(ok_status validate_base_url 'https://')"
check "triple-slash empty host rejected"      "reject" "$(ok_status validate_base_url 'https:///some/path')"
check "whitespace in host rejected"           "reject" "$(ok_status validate_base_url 'https:// evil.example')"
check "ipv6 literal host accepted"            "accept" "$(ok_status validate_base_url 'https://[2606:4700::1111]/agp')"
check "ipv6 literal with port accepted"       "accept" "$(ok_status validate_base_url 'https://[::1]:8443/x')"

# --- config-path traversal / absolute-path rejection (segment-based) ---
check "relative config-path accepted"         "accept" "$(ok_status validate_config_path 'agp.yml')"
check "nested relative path accepted"         "accept" "$(ok_status validate_config_path 'sub/dir/agp.yml')"
check "filename containing .. accepted"       "accept" "$(ok_status validate_config_path 'agp..yml')"
check "dotted dir name accepted"              "accept" "$(ok_status validate_config_path 'v1.0..draft/agp.yml')"
check "absolute config-path rejected"         "reject" "$(ok_status validate_config_path '/etc/passwd')"
check "leading parent traversal rejected"     "reject" "$(ok_status validate_config_path '../../escape.yml')"
check "embedded parent traversal rejected"    "reject" "$(ok_status validate_config_path 'foo/../etc/passwd')"
check "empty config-path rejected"            "reject" "$(ok_status validate_config_path '')"
# Control characters are rejected fail-closed: a newline in this input would smuggle a second
# gitignore pattern into the .git/info/exclude entry the gate writes, e.g.
# 'agp.yml\nsrc/' would also hide everything under src/ from AGP's dirty-worktree pre-flight check.
check "newline in config-path rejected"       "reject" "$(ok_status validate_config_path "$(printf 'agp.yml\nsrc/')")"
check "carriage return in config-path rejected" "reject" "$(ok_status validate_config_path "$(printf 'agp.yml\rsrc/')")"
check "tab in config-path rejected"           "reject" "$(ok_status validate_config_path "$(printf 'agp\t.yml')")"

# --- workspace-containment guard (is_inside_workspace: pure string containment) ---
check "path inside workspace accepted"        "accept" "$(ok_status is_inside_workspace '/w/repo/agp.yml' '/w/repo')"
check "workspace root itself accepted"        "accept" "$(ok_status is_inside_workspace '/w/repo' '/w/repo')"
check "trailing-slash root accepted"          "accept" "$(ok_status is_inside_workspace '/w/repo/x' '/w/repo/')"
check "sibling-prefix path rejected"          "reject" "$(ok_status is_inside_workspace '/w/repo-evil/x' '/w/repo')"
check "absolute escape rejected"              "reject" "$(ok_status is_inside_workspace '/etc/passwd' '/w/repo')"
check "empty workspace root rejected"         "reject" "$(ok_status is_inside_workspace '/w/repo/x' '')"
check "empty resolved path rejected"          "reject" "$(ok_status is_inside_workspace '' '/w/repo')"
check "root-of-/ rejected (no match-all)"     "reject" "$(ok_status is_inside_workspace '/etc/passwd' '/')"

# --- git-exclude bookkeeping (exclude_config_from_git) -------------------------------------
# The behaviour under test IS git's (does `git status --porcelain` stay clean?), so these cases
# drive real throwaway repositories rather than mocking git. Hermetic: the global/system git
# config is neutralised for this whole section — the function shells out to git itself, so the
# env has to be exported rather than wrapped around each call — and every repo gets a local
# identity plus an explicit initial branch so no init.defaultBranch hint pollutes the output.
# HOME/XDG_CONFIG_HOME are redirected into the temp dir as well, because GIT_CONFIG_GLOBAL does
# NOT disable git's default excludes file: a developer's ~/.gitignore or
# ~/.config/git/ignore containing e.g. '*.yml' would make every "status is clean" assertion below
# pass vacuously and break the "sibling still seen" cases (each repo additionally pins
# core.excludesFile=/dev/null, so the suite is immune however git resolves the default).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "${tmp}/home" "${tmp}/xdg"
export HOME="${tmp}/home" XDG_CONFIG_HOME="${tmp}/xdg"

# new_repo <name> -> path of a fresh repository at ${tmp}/<name>
# The name is an argument rather than an internal counter on purpose: new_repo is called from a
# command substitution, so a counter would be incremented in a subshell and every case would
# silently share one repository.
new_repo() {
  local d="${tmp}/$1"
  mkdir -p "${d}"
  # -b needs git >= 2.28; fall back so the suite still runs on an older git.
  git init -q -b main "${d}" >/dev/null 2>&1 || git init -q "${d}" >/dev/null 2>&1
  git -C "${d}" config user.email "agp-test@example.invalid"
  git -C "${d}" config user.name "AGP Test"
  # Pin the excludes file so no ignore rule from the developer's machine can affect the assertions.
  git -C "${d}" config core.excludesFile /dev/null
  printf '%s' "${d}"
}
# grep_line <file> <line> -> accept|reject (exact, fixed-string match)
grep_line() { if grep -Fxq "$2" "$1" 2>/dev/null; then echo accept; else echo reject; fi; }

# The ticket's actual regression: an untracked governed config must not show up in git status.
repo="$(new_repo plain)"
: > "${repo}/agp.yml"
exclude_config_from_git "${repo}" "agp.yml" 2>/dev/null
check "untracked config -> clean git status"   ""         "$(git -C "${repo}" status --porcelain)"
check "anchored pattern written"               "accept"   "$(grep_line "${repo}/.git/info/exclude" '/agp.yml')"

# Idempotent: the gate runs on every workflow run (twice per run in the two-job pattern).
exclude_config_from_git "${repo}" "agp.yml" 2>/dev/null
exclude_config_from_git "${repo}" "agp.yml" 2>/dev/null
check "re-running appends no duplicate line"   "1"        "$(grep -Fxc '/agp.yml' "${repo}/.git/info/exclude" || true)"
check "provenance comment written exactly once" "1"       "$(grep -Fc 'Sonatype Guide (agp-action gate)' "${repo}/.git/info/exclude" || true)"

# A nested config-path must be anchored from the REPOSITORY ROOT, not from the config's directory.
repo_nested="$(new_repo nested)"
mkdir -p "${repo_nested}/sub/dir"
: > "${repo_nested}/sub/dir/agp.yml"
exclude_config_from_git "${repo_nested}/sub/dir" "agp.yml" 2>/dev/null
check "nested path anchored from repo root"    "accept"   "$(grep_line "${repo_nested}/.git/info/exclude" '/sub/dir/agp.yml')"
check "nested config -> clean git status"      ""         "$(git -C "${repo_nested}" status --porcelain)"

# A legal-but-odd filename must not become a glob: 'agp?.yml' is escaped, so the same-length
# 'agpX.yml' stays visible to git (an unescaped '?' would have swallowed it).
repo_glob="$(new_repo glob)"
: > "${repo_glob}/agp?.yml"
: > "${repo_glob}/agpX.yml"
exclude_config_from_git "${repo_glob}" 'agp?.yml' 2>/dev/null
check "glob metacharacter escaped in pattern"  "accept"   "$(grep_line "${repo_glob}/.git/info/exclude" '/agp\?.yml')"
check "escaped name excluded, sibling still seen" "?? agpX.yml" "$(git -C "${repo_glob}" status --porcelain)"

# Appending to an exclude file with no trailing newline must not corrupt its last pattern.
repo_nonl="$(new_repo no-trailing-newline)"
mkdir -p "${repo_nonl}/.git/info"
printf 'legacy-pattern.txt' > "${repo_nonl}/.git/info/exclude"   # deliberately no newline
: > "${repo_nonl}/legacy-pattern.txt"
: > "${repo_nonl}/agp.yml"
exclude_config_from_git "${repo_nonl}" "agp.yml" 2>/dev/null
check "pre-existing last pattern preserved"    "accept"   "$(grep_line "${repo_nonl}/.git/info/exclude" 'legacy-pattern.txt')"
check "both patterns effective -> clean status" ""        "$(git -C "${repo_nonl}" status --porcelain)"

# Legacy repos with a COMMITTED agp.yml: info/exclude cannot hide a tracked file, so the function
# must still succeed (never fail the gate, never touch the index) and warn the user to untrack it.
# git status is therefore expected to keep showing the modification — that is the point of the warning.
repo_tracked="$(new_repo tracked)"
printf 'version: "1"\n' > "${repo_tracked}/agp.yml"
git -C "${repo_tracked}" add agp.yml >/dev/null 2>&1
git -C "${repo_tracked}" commit -q -m "commit a legacy agp.yml" >/dev/null 2>&1
printf 'version: "2"\n' > "${repo_tracked}/agp.yml"   # as if the gate had just overwritten it
check "tracked config: still returns 0"        "0"        "$(exclude_config_from_git "${repo_tracked}" "agp.yml" >/dev/null 2>&1; echo $?)"
check "tracked config: warns to untrack it"    "warned"   "$(if exclude_config_from_git "${repo_tracked}" "agp.yml" 2>&1 >/dev/null | grep -q 'git rm --cached'; then echo warned; else echo silent; fi)"
check "tracked config: exclude line still added" "accept" "$(grep_line "${repo_tracked}/.git/info/exclude" '/agp.yml')"
check "tracked config: modification stays visible (hence the warning)" " M agp.yml" "$(git -C "${repo_tracked}" status --porcelain)"

# Linked worktree: .git is a FILE there, and info/exclude only lives in the SHARED git dir — the
# case --git-common-dir (rather than --git-dir) exists for.
repo_main="$(new_repo worktree-main)"
printf 'x\n' > "${repo_main}/seed.txt"
git -C "${repo_main}" add seed.txt >/dev/null 2>&1
git -C "${repo_main}" commit -q -m "seed" >/dev/null 2>&1
wt="${tmp}/worktree-linked"
git -C "${repo_main}" worktree add -q -b wt "${wt}" >/dev/null 2>&1 || true
: > "${wt}/agp.yml"
exclude_config_from_git "${wt}" "agp.yml" 2>/dev/null
check "worktree: pattern lands in the shared git dir" "accept" "$(grep_line "${repo_main}/.git/info/exclude" '/agp.yml')"
check "worktree: clean git status"             ""         "$(git -C "${wt}" status --porcelain)"

# A character-class glob must not be able to hide a sibling: 'a[bc].yml' is a legal filename, and
# an unescaped '[' / ']' would turn the pattern into a class that matches 'ab.yml'/'ac.yml'.
repo_class="$(new_repo char-class)"
: > "${repo_class}/a[bc].yml"
: > "${repo_class}/ab.yml"
exclude_config_from_git "${repo_class}" 'a[bc].yml' 2>/dev/null
check "bracket metacharacters escaped"         "accept"   "$(grep_line "${repo_class}/.git/info/exclude" '/a\[bc\].yml')"
check "character-class sibling stays visible"  "?? ab.yml" "$(git -C "${repo_class}" status --porcelain)"

# Backslash must be escaped FIRST: escaping '*' before '\' would double the backslash the '*'
# escape just added, yielding a pattern that matches neither the file nor anything else.
repo_bs="$(new_repo backslash)"
: > "${repo_bs}/a\\*.yml"
exclude_config_from_git "${repo_bs}" 'a\*.yml' 2>/dev/null
check "backslash escaped before glob chars"    "accept"   "$(grep_line "${repo_bs}/.git/info/exclude" '/a\\\*.yml')"
check "backslash+glob name -> clean status"    ""         "$(git -C "${repo_bs}" status --porcelain)"

# gitignore strips unescaped trailing spaces, so a name ending in a space needs its last space
# escaped; without that the pattern would degrade to '/agp.yml' and hide the WRONG file.
repo_sp="$(new_repo trailing-space)"
: > "${repo_sp}/agp.yml "
: > "${repo_sp}/agp.yml"
exclude_config_from_git "${repo_sp}" 'agp.yml ' 2>/dev/null
check "trailing space escaped in pattern"      "accept"   "$(grep_line "${repo_sp}/.git/info/exclude" '/agp.yml\ ')"
check "trailing-space name excluded, plain sibling seen" "?? agp.yml" "$(git -C "${repo_sp}" status --porcelain)"

# The duplicate check must be a whole-line match: a pre-existing longer line that merely CONTAINS
# the pattern (here '/agp.yml.bak') must not be mistaken for our entry, or the append is skipped
# and the config stays visible to git.
repo_sub="$(new_repo superstring)"
mkdir -p "${repo_sub}/.git/info"
printf '/agp.yml.bak\n' > "${repo_sub}/.git/info/exclude"
: > "${repo_sub}/agp.yml"
exclude_config_from_git "${repo_sub}" "agp.yml" 2>/dev/null
check "superstring line does not suppress append" "accept" "$(grep_line "${repo_sub}/.git/info/exclude" '/agp.yml')"
check "superstring case -> clean git status"   ""         "$(git -C "${repo_sub}" status --porcelain)"

# Control characters in the name would append a SECOND, caller-chosen pattern ('src/' here) that
# hides real customer changes from AGP's dirty-worktree pre-flight check. validate_config_path
# rejects such input outright; this function independently refuses to write anything.
repo_ctl="$(new_repo control-char)"
mkdir -p "${repo_ctl}/src"
: > "${repo_ctl}/src/real-change.java"
: > "${repo_ctl}/agp.yml"
injected="$(printf 'agp.yml\nsrc/')"
check "control char in name: returns 0"        "0"        "$(exclude_config_from_git "${repo_ctl}" "${injected}" >/dev/null 2>&1; echo $?)"
check "control char in name: nothing written"  "reject"   "$(grep_line "${repo_ctl}/.git/info/exclude" 'src/')"
check "control char in name: real change stays visible" "?? agp.yml
?? src/" "$(git -C "${repo_ctl}" status --porcelain)"

# A committed config must be reported even when the configured case differs from the committed case.
# On a case-insensitive filesystem (macOS APFS, Windows) git sets core.ignorecase=true and the index
# keeps the committed spelling, so a byte-exact `:(literal)` pathspec misses — leaving the gate
# silent in the one case the warning exists for, and the run aborting on " M agp.yml" unexplained.
# Only meaningful where the filesystem really is case-insensitive; skipped elsewhere so the suite
# stays honest on Linux CI.
icase_repo="$(new_repo icase)"
: > "${icase_repo}/agp.yml"
git -C "${icase_repo}" add agp.yml
git -C "${icase_repo}" -c commit.gpgsign=false commit -qm "commit the config"
if [ "$(git -C "${icase_repo}" config --get core.ignorecase 2>/dev/null || true)" = "true" ]; then
  check "tracked config, different case: warns" "warned" \
    "$(exclude_config_from_git "${icase_repo}" "AGP.yml" "${icase_repo}" 2>&1 >/dev/null | grep -q 'is committed to this repository' && echo warned || echo silent)"
else
  check "tracked config, different case: warns (skipped, case-sensitive FS)" "skip" "skip"
fi
# The exact-case form must warn on every filesystem.
check "tracked config, exact case: warns" "warned" \
  "$(exclude_config_from_git "${icase_repo}" "agp.yml" "${icase_repo}" 2>&1 >/dev/null | grep -q 'is committed to this repository' && echo warned || echo silent)"
# ...and an untracked config must NOT warn, whatever the filesystem.
untracked_repo="$(new_repo untracked)"
: > "${untracked_repo}/agp.yml"
check "untracked config: no committed-file warning" "silent" \
  "$(exclude_config_from_git "${untracked_repo}" "agp.yml" "${untracked_repo}" 2>&1 >/dev/null | grep -q 'is committed to this repository' && echo warned || echo silent)"

# The workspace is NOT a repository root but an ANCESTOR is one (actions/checkout with `path:`, or a
# self-hosted work dir nested inside someone's repo). git rev-parse walks upwards and finds the
# ancestor, so without the workspace check the entry lands in the WRONG repository: a silent no-op
# that leaves the real checkout dirty and still aborts the run.
anc="${tmp}/ancestor"
mkdir -p "${anc}/work/myrepo/src"
git -C "${anc}" init -q
git -C "${anc}" config user.email t@t
git -C "${anc}" config user.name t
: > "${anc}/root.txt"
git -C "${anc}" add -A
git -C "${anc}" -c commit.gpgsign=false commit -qm init
git -C "${anc}/work/myrepo/src" init -q
anc_ws="$(cd "${anc}/work/myrepo" && pwd -P)"
: > "${anc_ws}/agp.yml"
check "workspace not a repo root: returns 0"    "0"      "$(exclude_config_from_git "${anc_ws}" "agp.yml" "${anc_ws}" >/dev/null 2>&1; echo $?)"
check "workspace not a repo root: warns"        "warned" "$(exclude_config_from_git "${anc_ws}" "agp.yml" "${anc_ws}" 2>&1 >/dev/null | grep -q 'not the workspace' && echo warned || echo silent)"
check "workspace not a repo root: ancestor untouched" "reject" "$(grep_line "${anc}/.git/info/exclude" '/work/myrepo/agp.yml')"

# The control: a config in a SUBDIRECTORY of the workspace is the same repository, so it must still
# be excluded — the check must not fire merely because the config is not at the root.
sub_ws="${tmp}/subws"
mkdir -p "${sub_ws}/ci"
git -C "${sub_ws}" init -q
git -C "${sub_ws}" config user.email t@t
git -C "${sub_ws}" config user.name t
: > "${sub_ws}/keep.txt"
git -C "${sub_ws}" add -A
git -C "${sub_ws}" -c commit.gpgsign=false commit -qm init
sub_real="$(cd "${sub_ws}" && pwd -P)"
: > "${sub_real}/ci/agp.yml"
exclude_config_from_git "${sub_real}/ci" "agp.yml" "${sub_real}" >/dev/null 2>&1
check "config in a subdir of the workspace: still excluded" "accept" "$(grep_line "${sub_real}/.git/info/exclude" '/ci/agp.yml')"
check "config in a subdir of the workspace: status clean"   ""            "$(git -C "${sub_real}" status --porcelain)"

# Not a git repository at all: best-effort means warn and return 0, never abort the gate.
plain_dir="${tmp}/not-a-repo"
mkdir -p "${plain_dir}"
check "no git repo: returns 0 (best-effort)"   "0"        "$(exclude_config_from_git "${plain_dir}" "agp.yml" >/dev/null 2>&1; echo $?)"
check "missing arguments: returns 0"           "0"        "$(exclude_config_from_git "" "" >/dev/null 2>&1; echo $?)"

# --- log sanitiser defangs control chars and '::' workflow-command markers ---
check "sanitize strips :: command marker"     "__set-output__" "$(printf '::set-output::' | sanitize_for_log)"
check "sanitize strips control chars"         "ab"             "$(printf 'a\tb\r' | sanitize_for_log)"

# A byte that is not valid UTF-8 (here a Latin-1 filename) must not make the sanitiser FAIL. BSD tr
# exits 1 with "Illegal byte sequence" outside the C locale, and under `set -euo pipefail` that
# propagates out of the call sites' command substitutions and kills the whole gate — turning a
# cosmetic logging step into a failed run on exactly the macOS self-hosted runners this script
# supports. Both tr stages therefore pin LC_ALL=C. Asserted on the EXIT STATUS, because the
# surviving byte is irrelevant; not aborting is the contract.
check "sanitize survives an invalid UTF-8 byte" "0" \
  "$(set -euo pipefail; v="$(printf 'agp\xff.yml' | sanitize_for_log)"; printf '%s' "${v}" >/dev/null; echo $?)"
# ...and still defangs the things it exists to defang when such a byte is present.
check "sanitize defangs ':' beside an invalid byte" "a_b" "$(printf 'a\xff:b' | sanitize_for_log | LC_ALL=C tr -d '\377')"

# --- portability guard: no GNU-only coreutils flags (self-hosted runners may be BSD/macOS) ---
# `realpath -m` and `mv -T`/`mv -fT` are GNU-only and silently break on macOS, where they
# return empty / error — exactly the regression that took the gate down on a self-hosted mac.
no_gnu_only_flags() {
  # Strip comment lines first so the rule matches real usage, not prose mentioning the flags.
  ! grep -hv '^[[:space:]]*#' \
      "${SCRIPT_DIR}/gate.sh" "${SCRIPT_DIR}/mint-oidc-token.sh" "${SCRIPT_DIR}/prepare-auth.sh" \
    | grep -Eq 'realpath[[:space:]]+-[A-Za-z]*m|mv[[:space:]]+-[A-Za-z]*T'
}
check "no GNU-only realpath -m / mv -T"       "portable" "$(if no_gnu_only_flags; then echo portable; else echo gnu-only; fi)"

# --- audience default must not drift between the manifest and the mint helper ---
# Tolerant of whitespace/quoting reformats so it only fails on a real value change, not a
# cosmetic edit: both files must carry the canonical audience URL for the audience input/default.
audience_in_sync() {
  grep -Eq 'default:[[:space:]]*"?https://guide\.sonatype\.com"?' "${SCRIPT_DIR}/../gate/action.yml" \
    && grep -Eq 'DEFAULT_GUIDE_AUDIENCE=["'\'']?https://guide\.sonatype\.com["'\'']?' "${SCRIPT_DIR}/mint-oidc-token.sh"
}
check "audience default in sync"              "insync" "$(if audience_in_sync; then echo insync; else echo drift; fi)"

# NOTE: the fail-closed http_code != 200 branch, the curl 000 fallback, the realpath
# resolution, and the atomic stage->move in main() depend on a real (or mocked) HTTP
# round-trip / filesystem and are exercised end-to-end when the action runs, not here.
# is_inside_workspace (the decision the containment check turns on) is unit-tested above.

if [ "${fail}" -ne 0 ]; then
  echo "gate_test: FAILURES"
  exit 1
fi
echo "gate_test: all passed"
