#!/usr/bin/env bash
#
# apply-patches.sh - apply the Bootowser patch series to a Firefox tree.
#
# The policy file locks down what Firefox *allows*. These patches enforce what
# it *cannot be talked out of*: policies are a runtime control an operator can
# weaken, and they do not cover schemes or entry points Firefox grows later.
# Kiosk mode is meant to be a one-way door, so the load-bearing lockdown lives
# in the source.
#
# Idempotent: re-running on an already-patched tree is a no-op unless --force,
# which resets first.
#
# The series is applied with `git am` inside firefox-src/ so each change becomes
# a real commit that `git rebase -i` can reorder, drop or squash.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PATCH_DIR="${SCRIPT_DIR}/patches"

# Must agree with fetch.sh's default, or "run fetch.sh then apply-patches.sh"
# silently looks in two different directories.
SRC_DIR="${BOOTOWSER_FIREFOX_SRC:-${FIREFOX_SRC_DIR:-${HOME}/firefox-src}}"
FORCE=0
CHECK_ONLY=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

  --src-dir DIR   Firefox checkout (default: \${BOOTOWSER_FIREFOX_SRC:-${SRC_DIR}})
  --check         verify the series applies, then reset (leaves no changes)
  --force         reset the tree to a clean state before applying
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
# .git is a directory in a normal clone but a file in a linked worktree; accept
# both so --check can run against a disposable worktree.
[ -e "${SRC_DIR}/.git" ]     || die "'${SRC_DIR}' is not a Firefox checkout; run firefox/fetch.sh first"

FIREFOX_VERSION="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${SCRIPT_DIR}/FIREFOX_VERSION" \
  | head -n1 | tr -d '[:space:]')"
[ -n "${FIREFOX_VERSION}" ] || die "firefox/FIREFOX_VERSION is empty"

# Resolve the series. Blank lines and # comments are allowed (quilt-style).
mapfile -t PATCHES < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${PATCH_DIR}/series" | grep -v '^$')
[ "${#PATCHES[@]}" -gt 0 ] || die "patch series is empty"

for p in "${PATCHES[@]}"; do
  [ -f "${PATCH_DIR}/${p}" ] || die "series references missing patch: ${p}"
done

PATCH_PATHS=()
for p in "${PATCHES[@]}"; do PATCH_PATHS+=("${PATCH_DIR}/${p}"); done

# Refuse to build against a different Firefox than the patches were written
# for. Without this you get "patch does not apply" much later, after a 20 GB
# build has already burned an afternoon.
CURRENT_TAG="$(git -C "${SRC_DIR}" describe --tags --abbrev=0 2>/dev/null || true)"
# The desktop release and its Android build are tagged on the same commit,
# and git describe is free to name either one -- which fails the check
# below on a fresh clone even though the tree is exactly right. If the
# pinned tag is among the tags pointing at HEAD, we are where we should be.
if git -C "${SRC_DIR}" tag --points-at HEAD 2>/dev/null | grep -Fxq "${FIREFOX_VERSION}"; then
  CURRENT_TAG="${FIREFOX_VERSION}"
fi
if [ -n "${CURRENT_TAG}" ] && [ "${CURRENT_TAG}" != "${FIREFOX_VERSION}" ]; then
  die "firefox-src is at ${CURRENT_TAG} but the patch series targets ${FIREFOX_VERSION}.
     Re-run firefox/fetch.sh, or roll the series forward (see docs/building.md)."
fi

if [ "${FORCE}" -eq 1 ]; then
  # Reset to the pinned release tag, not to HEAD. Resetting to HEAD would be a
  # no-op on an already-patched tree, which is precisely the case --force
  # exists to fix.
  git -C "${SRC_DIR}" am --abort >/dev/null 2>&1 || true
  log "resetting ${SRC_DIR} to ${FIREFOX_VERSION}"
  git -C "${SRC_DIR}" checkout -q --detach "${FIREFOX_VERSION}"
  git -C "${SRC_DIR}" reset -q --hard "${FIREFOX_VERSION}"
  git -C "${SRC_DIR}" clean -qfd
fi

# Are we already patched? Each Bootowser commit carries a [Bootowser] tag.
ALREADY="$(git -C "${SRC_DIR}" log --format=%s -20 | grep -c '\[Bootowser\]' || true)"

if [ "${CHECK_ONLY}" -eq 1 ]; then
  # Check in a throwaway worktree rather than in SRC_DIR itself. Two reasons:
  # a tree that is already patched would otherwise fail the check for the wrong
  # reason, and --check should never leave the operator's tree modified or
  # abortable mid-am.
  log "checking ${#PATCHES[@]} patch(es) against ${FIREFOX_VERSION}"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/bootowser-patchcheck.XXXXXX")"
  rm -rf "${tmp_dir}" # git worktree add wants the path to not exist
  cleanup_check() {
    git -C "${SRC_DIR}" worktree remove --force "${tmp_dir}" >/dev/null 2>&1 || true
    rm -rf "${tmp_dir}"
  }
  trap cleanup_check EXIT

  if ! git -C "${SRC_DIR}" worktree add --quiet --detach "${tmp_dir}" "${FIREFOX_VERSION}"; then
    die "could not create a temporary worktree at ${tmp_dir}"
  fi

  if git -C "${tmp_dir}" am --3way --keep-non-patch --quiet "${PATCH_PATHS[@]}" 2>&1; then
    applied="$(git -C "${tmp_dir}" log --format=%s "${FIREFOX_VERSION}..HEAD" | grep -c '\[Bootowser\]' || true)"
    log "series applies cleanly to ${FIREFOX_VERSION} (${applied} patch commit(s))"
  else
    git -C "${tmp_dir}" am --abort >/dev/null 2>&1 || true
    die "patch series does NOT apply cleanly to ${FIREFOX_VERSION}"
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

log "patched. ${#PATCHES[@]} commit(s) on top of Firefox ${FIREFOX_VERSION}"
git -C "${SRC_DIR}" log --oneline -n "${#PATCHES[@]}"