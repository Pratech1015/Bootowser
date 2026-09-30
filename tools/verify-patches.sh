#!/usr/bin/env bash
#
# verify-patches.sh - prove the Bootowser patch series still applies.
#
# The series is written against one pinned Chromium tag. This downloads only
# the individual upstream files the patches touch (a few hundred KB, versus a
# 45 GB checkout), builds a throwaway git tree from them, and replays the
# series with `git am`.
#
# Run this in CI, and run it before bumping browser/CHROMIUM_VERSION.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly BROWSER_DIR="${REPO_ROOT}/browser"
readonly PATCH_DIR="${BROWSER_DIR}/patches"
readonly GITILES="https://chromium.googlesource.com/chromium/src"

WORK_DIR="${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/bootowser-verify.XXXXXX")}"
readonly WORK_DIR

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git     >/dev/null 2>&1 || die "git is required"
command -v base64  >/dev/null 2>&1 || die "coreutils base64 is required"
command -v curl    >/dev/null 2>&1 || die "curl is required"

VERSION="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${BROWSER_DIR}/CHROMIUM_VERSION" \
  | head -n1 | tr -d '[:space:]')"
[ -n "${VERSION}" ] || die "browser/CHROMIUM_VERSION is empty"

[ -f "${PATCH_DIR}/series" ] || die "missing ${PATCH_DIR}/series"

mapfile -t PATCHES < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${PATCH_DIR}/series" | grep -v '^$')
[ "${#PATCHES[@]}" -gt 0 ] || die "patch series is empty"
for p in "${PATCHES[@]}"; do
  [ -f "${PATCH_DIR}/${p}" ] || die "series references missing patch: ${p}"
done

log "verifying ${#PATCHES[@]} patch(es) against Chromium ${VERSION}"

# --- Which upstream files does the series touch? ---------------------------
# Read the b/ paths straight out of the diff headers so this stays correct
# even when the series is extended.
SERIES_PATHS=()
for p in "${PATCHES[@]}"; do SERIES_PATHS+=("${PATCH_DIR}/${p}"); done

mapfile -t FILES < <(
  cat "${SERIES_PATHS[@]}" \
    | sed -n 's|^diff --git a/\(.*\) b/.*$|\1|p' \
    | sort -u
)
[ "${#FILES[@]}" -gt 0 ] || die "could not determine which files the series touches"

log "series touches ${#FILES[@]} file(s):"
printf '    %s\n' "${FILES[@]}"

# --- Build a minimal tree of just those files ------------------------------
TREE="${WORK_DIR}/tree"
mkdir -p "${TREE}"
cd "${TREE}"

for f in "${FILES[@]}"; do
  log "fetching ${f}"
  url="${GITILES}/+/${VERSION}/${f}?format=TEXT"
  mkdir -p "$(dirname -- "${f}")"
  if ! curl -sfL --max-time 120 --retry 2 "${url}" | base64 -d > "${f}"; then
    die "could not fetch upstream file: ${f}
     (does it still exist at tag ${VERSION}? upstream may have moved it)"
  fi
  [ -s "${f}" ] || die "upstream file ${f} is empty - fetch probably failed"
done

git init -q -b main .
git config user.email "verify@bootowser.invalid"
git config user.name  "Bootowser verify"
git add -A
git commit -qm "pristine Chromium ${VERSION} (files touched by the patch series)"

# --- Replay the series -----------------------------------------------------
PATCH_PATHS=()
for p in "${PATCHES[@]}"; do PATCH_PATHS+=("${PATCH_DIR}/${p}"); done

log "applying series with git am"
if ! git am --3way --keep-non-patch "${PATCH_PATHS[@]}"; then
  echo >&2
  die "the patch series does NOT apply cleanly to Chromium ${VERSION}.
     Roll the series forward first (see docs/browser.md, 'Rolling Chromium forward')."
fi

APPLIED="$(git rev-list --count HEAD -n "${#PATCHES[@]}" 2>/dev/null || echo "${#PATCHES[@]}")"
log "applied ${APPLIED} commit(s)"

# --- Confirm the intent of each patch landed -------------------------------
# Cheap, targeted assertions so a silently-truncated patch cannot pass review.
assert_src_contains() {
  local file="$1" needle="$2" why="$3"
  if grep -qF -- "${needle}" "${file}"; then
    log "ok: ${why}"
  else
    die "assertion failed in ${file}: expected ${needle} (${why})"
  fi
}

assert_src_contains chrome/common/chrome_switches.h \
  'inline constexpr char kBootowser[] = "bootowser";' \
  "patch 1 registers the --bootowser switch"

assert_src_contains chrome/app/chrome_main_delegate.cc \
  'void ApplyBootowserKioskLockdown()' \
  "patch 2 installs the startup lockdown"

assert_src_contains chrome/app/chrome_main_delegate.cc \
  'switches::kRemoteDebuggingPort' \
  "patch 2 strips the remote-debugging escape hatches"

assert_src_contains chrome/browser/chrome_content_browser_client_navigation_throttles.cc \
  'class BootowserNavigationThrottle' \
  "patch 3 adds the navigation allowlist"

assert_src_contains chrome/browser/chrome_content_browser_client_navigation_throttles.cc \
  'std::make_unique<BootowserNavigationThrottle>(registry)' \
  "patch 3 registers the throttle"

# --- Report ----------------------------------------------------------------
if [ -z "${KEEP_WORK_DIR:-}" ]; then
  cd /
  rm -rf "${WORK_DIR}"
  log "scratch tree removed (set KEEP_WORK_DIR=1 to inspect it)"
else
  log "scratch tree kept at ${TREE}"
fi

printf '\n\033[1;32m==> patch series verified against Chromium %s\033[0m\n' "${VERSION}"