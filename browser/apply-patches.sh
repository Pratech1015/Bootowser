#!/usr/bin/env bash
#
# apply-patches.sh - apply the Bootowser patch series to the Chromium tree.
#
# Idempotent: re-running it on an already-patched tree is a no-op unless
# --force is given, in which case any locally modified Chromium files are
# reset first.
#
# The series is applied with `git am` inside src/ so that each change becomes
# a real commit that `git rebase -i` can reorder, drop or squash.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PATCH_DIR="${SCRIPT_DIR}/patches"

SRC_DIR="${SCRIPT_DIR}/../src"
FORCE=0
CHECK_ONLY=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

  --src-dir DIR   Chromium checkout (default: ${SRC_DIR})
  --check         verify the series applies, then reset (does not leave changes)
  --force         reset src/ to a clean state before applying
  -h, --help      show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src-dir) SRC_DIR="$2"; shift 2 ;;
    --check)   CHECK_ONLY=1; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "${PATCH_DIR}/series" ] || die "missing ${PATCH_DIR}/series"
[ -d "${SRC_DIR}/.git" ]     || die "'${SRC_DIR}' is not a Chromium checkout; run fetch.sh first"

CHROMIUM_VERSION="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${SCRIPT_DIR}/CHROMIUM_VERSION" \
  | head -n1 | tr -d '[:space:]')"

# Resolve the series to absolute paths; blank lines and # comments are allowed
# in the series file (quilt-style), but we keep ours strict and simple.
mapfile -t PATCHES < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${PATCH_DIR}/series" | grep -v '^$')
[ "${#PATCHES[@]}" -gt 0 ] || die "patch series is empty"

for p in "${PATCHES[@]}"; do
  [ -f "${PATCH_DIR}/${p}" ] || die "series references missing patch: ${p}"
done

PATCH_PATHS=()
for p in "${PATCHES[@]}"; do PATCH_PATHS+=("${PATCH_DIR}/${p}"); done

# Refuse to build against a different Chromium than the patches were written
# for. Without this you get a wall of "patch does not apply" much later.
CURRENT_TAG="$(git -C "${SRC_DIR}" describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "${CURRENT_TAG}" ] && [ "${CURRENT_TAG}" != "${CHROMIUM_VERSION}" ]; then
  die "src/ is at Chromium ${CURRENT_TAG} but the patch series targets ${CHROMIUM_VERSION}.
     Re-run fetch.sh, or roll the series forward (see docs/browser.md)."
fi

if [ "${FORCE}" -eq 1 ]; then
  log "resetting ${SRC_DIR} to a clean checkout"
  git -C "${SRC_DIR}" reset --hard
  git -C "${SRC_DIR}" clean -fd
fi

# Are we already patched?  Each Bootowser commit carries a [Bootowser] tag.
ALREADY="$(git -C "${SRC_DIR}" log --format=%s -20 | grep -c '\[Bootowser\]' || true)"

if [ "${CHECK_ONLY}" -eq 1 ]; then
  log "checking ${#PATCHES[@]} patch(es) against ${SRC_DIR}"
  if git -C "${SRC_DIR}" am --3way --keep-non-patch --quiet \
       "${PATCH_PATHS[@]}" 2>&1; then
    log "series applies cleanly"
    git -C "${SRC_DIR}" am --abort 2>/dev/null || git -C "${SRC_DIR}" reset --hard -q
  else
    git -C "${SRC_DIR}" am --abort 2>/dev/null || true
    die "patch series does NOT apply cleanly to ${CHROMIUM_VERSION}"
  fi
  exit 0
fi

if [ "${ALREADY}" -gt 0 ]; then
  log "tree already carries ${ALREADY} Bootowser commit(s); nothing to do"
  log "use --force to reapply from scratch"
  exit 0
fi

log "applying ${#PATCHES[@]} patch(es)"
git -C "${SRC_DIR}" am --3way --keep-non-patch "${PATCH_PATHS[@]}"

log "patched. ${#PATCHES[@]} commit(s) on top of Chromium ${CHROMIUM_VERSION}"
git -C "${SRC_DIR}" log --oneline -n "${#PATCHES[@]}"