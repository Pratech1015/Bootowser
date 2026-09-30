#!/usr/bin/env bash
#
# fetch.sh - download the Chromium source tree Bootowser is built from.
#
# This only fetches; it does not patch or build. See build.sh for that.
#
# Disk: the default checkout (minus test data and fuzzing corpora) needs
# roughly 45 GB, and a Release build in out/ needs another ~25 GB.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

CHROMIUM_VERSION="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${SCRIPT_DIR}/CHROMIUM_VERSION" \
  | head -n1 | tr -d '[:space:]')"
readonly CHROMIUM_VERSION

SRC_DIR="${REPO_ROOT}/src"
OUT_DIR="${REPO_ROOT}/out"
JOBS="$(nproc 2>/dev/null || echo 4)"

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

  --src-dir DIR     checkout location (default: ${SRC_DIR})
  --out-dir DIR     build output location (default: ${OUT_DIR})
  --jobs N          parallel fetch jobs (default: ${JOBS})
  --full            also fetch test data and fuzzing corpora (~150 GB extra)
  -h, --help        show this help

Environment:
  DEBIAN_FRONTEND=noninteractive   recommended for Debian/Ubuntu
EOF
}

FULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --src-dir)  SRC_DIR="$2"; shift 2 ;;
    --out-dir)  OUT_DIR="$2"; shift 2 ;;
    --jobs)     JOBS="$2";     shift 2 ;;
    --full)     FULL=1;        shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Toolchain checks ------------------------------------------------------
for tool in git python3; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed"
done

# depot_tools pins the exact clang, ninja and gn revisions Chromium expects.
# Using a distribution clang almost always fails to compile Chromium.
DEPOT_TOOLS="${DEPOT_TOOLS:-${HOME}/depot_tools}"
if [ ! -x "${DEPOT_TOOLS}/gclient" ]; then
  log "fetching depot_tools into ${DEPOT_TOOLS}"
  git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    "${DEPOT_TOOLS}"
fi

export PATH="${DEPOT_TOOLS}:${PATH}"

# --- Layout ---------------------------------------------------------------
mkdir -p "${SRC_DIR}"

if [ ! -f "${SRC_DIR}/.gclient" ]; then
  log "configuring gclient for Chromium ${CHROMIUM_VERSION}"
  # custom_vars drop the parts of the checkout Bootowser never links. Test
  # data and the fuzzing corpora alone are well over 100 GB.
  gclient config \
    --name=src \
    --unmanaged \
    --custom-var=checkout_pgo_profiles=false \
    --custom-var=checkout_test_data="$( [ "$FULL" -eq 1 ] && echo true || echo false )" \
    --custom-var=checkout_fuzzing="$(   [ "$FULL" -eq 1 ] && echo true || echo false )" \
    --custom-var=checkout_android=false \
    --custom-var=checkout_ios=false \
    --custom-var=checkout_mac=false \
    --custom-var=checkout_win=false \
    "https://chromium.googlesource.com/chromium/src.git"
fi

# Pin to the exact tag the patch series is written against. Using --force
# here is intentional: a stale checkout of a different tag is the single most
# common way to end up with patches that mysteriously do not apply.
log "syncing Chromium ${CHROMIUM_VERSION} (this takes a while)"
gclient sync \
  --force \
  --no-history \
  --shallow \
  --with_branch_heads \
  --with_tags \
  --jobs="${JOBS}" \
  --revision "src@${CHROMIUM_VERSION}"

log "checkout complete: ${SRC_DIR}"
log "next: ${SCRIPT_DIR}/build.sh"