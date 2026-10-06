#!/usr/bin/env bash
#
# fetch.sh - get the Firefox source tree Bootowser builds from.
#
# The build tree lives outside the repository by default. Firefox needs tens
# of gigabytes of objdir, which does not belong in a git checkout (nor in a
# system with a small root filesystem), so the default destination is a
# directory the operator points at a drive with room on it.
#
# The version is not decided here: firefox/FIREFOX_VERSION is the single source
# of truth, so that fetch.sh, apply-patches.sh and the patch series cannot
# drift apart. --version exists for deliberately testing a different release.
#
# Usage:
#   ./fetch.sh [--version <tag>] [--dest <dir>] [--depth <n>]
#
# Examples:
#   FIREFOX_SRC_DIR=/mnt/fast/firefox-src ./fetch.sh
#   ./fetch.sh --dest /mnt/fast/firefox-src
#
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SELF
readonly SCRIPT_DIR="${SELF%/*}"

# Read the pinned release. Strip comments and blank lines, take the first value.
FIREFOX_VERSION="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${SCRIPT_DIR}/FIREFOX_VERSION" \
  | head -n1 | tr -d '[:space:]')"
[ -n "${FIREFOX_VERSION}" ] || {
  echo "fetch.sh: firefox/FIREFOX_VERSION is empty or missing" >&2
  exit 1
}
readonly FIREFOX_VERSION

readonly DEFAULT_DEST="${FIREFOX_SRC_DIR:-${HOME}/firefox-src}"

# gecko-dev is archived and frozen; the tree that actually gets releases is
# mozilla-firefox/firefox. The two are the same code, but only this one still
# carries release tags, so pinning against the archived mirror fails.
readonly MOZILLA_REPO="https://github.com/mozilla-firefox/firefox.git"

VERSION="${FIREFOX_VERSION}"
DEST="${DEFAULT_DEST}"
DEPTH=1

usage() { sed -n '3,20p' "${SELF}" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a tag}"; shift 2 ;;
    --dest)    DEST="${2:?--dest needs a directory}"; shift 2 ;;
    --depth)   DEPTH="${2:?--depth needs a number}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fetch.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { echo "fetch.sh: $*" >&2; }
die() { echo "fetch.sh: $*" >&2; exit 1; }

case "${DEST}" in
  /*) ;;
  *) die "--dest must be an absolute path (got '${DEST}')" ;;
esac

command -v git >/dev/null 2>&1 || die "git is required"

# Firefox needs real filesystem semantics. A build on NTFS, exFAT, or a
# network mount fails in confusing ways, so refuse rather than waste a day.
fs_type="$(findmnt -no FSTYPE --target "${DEST}" 2>/dev/null || findmnt -no FSTYPE --target "$(dirname "${DEST}")" 2>/dev/null || echo unknown)"
case "${fs_type}" in
  ntfs|ntfs3|exfat|fuseblk|fuse.ntfs|vfat|cifs|nfs|nfs4|fuse.sshfs) die "refusing to build on '${fs_type}'; use ext4, btrfs, xfs, or zfs" ;;
  unknown) log "warning: could not determine filesystem type for ${DEST}" ;;
  *) log "filesystem: ${fs_type}" ;;
esac

# Note: `df -P --output=avail` cannot be combined -- coreutils rejects -P and
# --output together -- so parse the POSIX format instead. -P guarantees one
# line per filesystem, which makes the 4th column the available 1K blocks.
#
# DEST usually does not exist yet (that is the clone path), so walk up to the
# nearest directory that does and measure that: it is the filesystem the clone
# will land on, and it is the only thing we can measure before the clone.
probe="${DEST}"
while [ ! -e "${probe}" ] && [ "${probe}" != "/" ]; do
  probe="$(dirname -- "${probe}")"
done

avail_kb="$(df -Pk -- "${probe}" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
case "${avail_kb}" in
  ''|*[!0-9]*) avail_kb='' ;;
esac

if [ -n "${avail_kb}" ]; then
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  log "space available for ${DEST}: ${avail_gb} GB (on ${probe})"
  # Mozilla documents 30 GB as the minimum for a full build.
  if [ "${avail_gb}" -lt 30 ]; then
    die "only ${avail_gb} GB free at '${probe}'; Firefox needs at least 30 GB to build."
    die "Point --dest (or FIREFOX_SRC_DIR) at a bigger filesystem."
  fi
else
  log "warning: could not determine free space for ${DEST}"
fi

if [ -e "${DEST}" ]; then
  [ -d "${DEST}" ] || die "${DEST} exists and is not a directory"
  if [ -d "${DEST}/.git" ]; then
    log "updating the existing checkout at ${DEST}"
    git -C "${DEST}" remote set-url origin "${MOZILLA_REPO}"
    git -C "${DEST}" fetch --depth "${DEPTH}" origin "refs/tags/${VERSION}:refs/tags/${VERSION}"
    git -C "${DEST}" checkout --detach "${VERSION}"
  else
    die "${DEST} exists but is not a git checkout; remove it or pass a different --dest"
  fi
else
  log "cloning ${MOZILLA_REPO} at ${VERSION} (depth ${DEPTH})"
  log "this downloads several gigabytes; be patient"
  git clone --depth "${DEPTH}" --branch "${VERSION}" "${MOZILLA_REPO}" "${DEST}"
fi

log "source tree ready at ${DEST}"
log "next: ${SCRIPT_DIR}/apply-patches.sh --src-dir ${DEST} --check"
log "next: cp ${SCRIPT_DIR}/mozconfig-bootowser ${DEST}/.mozconfig"
log "then:  cd ${DEST} && ./mach bootstrap && ./mach build"