#!/usr/bin/env bash
#
# build.sh - build the stripped Bootowser browser from the Chromium tree.
#
# Assumes fetch.sh has already populated ../src and that apply-patches.sh has
# run (build.sh runs it for you unless --no-patches is given).
#
# A Release Chromium build wants 16 GB of RAM per link job and roughly 25 GB of
# disk for out/. With 14 GB of RAM you will need to drop AUTONINJA parallelism
# for linking; build.sh does that automatically via jobs.py when it detects a
# small machine.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

SRC_DIR="${SCRIPT_DIR}/../src"
OUT_DIR="${SCRIPT_DIR}/../out"
TARGET="chrome"
JOBS=""
SKIP_PATCHES=0
EXTRA_ARGS=""
EXTRA_TARGETS=()

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [gn-args...]

  --src-dir DIR    Chromium checkout (default: ${SRC_DIR})
  --out-dir DIR    build output directory (default: ${OUT_DIR})
  --target NAME    ninja target to build (default: ${TARGET})
  --jobs N         parallel ninja jobs (default: auto)
  --no-patches     do not run apply-patches.sh first
  -h, --help       show this help

Anything after the options is passed through to \`gn gen\` as extra
key=value args, e.g.:

    ${0##*/} enable_spellcheck=true enable_widevine=false
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src-dir)     SRC_DIR="$2"; shift 2 ;;
    --out-dir)     OUT_DIR="$2"; shift 2 ;;
    --target)      TARGET="$2"; shift 2 ;;
    --jobs)        JOBS="$2"; shift 2 ;;
    --no-patches)  SKIP_PATCHES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --)            shift; EXTRA_ARGS="$*"; break ;;
    *)             EXTRA_TARGETS+=("$1"); shift ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

DEPOT_TOOLS="${DEPOT_TOOLS:-${HOME}/depot_tools}"
[ -x "${DEPOT_TOOLS}/gn" ] || die "depot_tools not found at ${DEPOT_TOOLS}; run fetch.sh first"
export PATH="${DEPOT_TOOLS}:${PATH}"

[ -d "${SRC_DIR}" ] || die "'${SRC_DIR}' does not exist; run fetch.sh first"

if [ "${SKIP_PATCHES}" -eq 0 ]; then
  "${SCRIPT_DIR}/apply-patches.sh" --src-dir "$(cd -- "${SRC_DIR}" && pwd)"
fi

# --- Job sizing ------------------------------------------------------------
# Linking chrome is the memory high-water mark. jobs.py understands that and
# keeps -j low enough that the linker does not get OOM-killed.
if [ -z "${JOBS}" ]; then
  RAM_GB="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)"
  log "detected ${RAM_GB} GB RAM, sizing jobs automatically"
  if [ -x "${DEPOT_TOOLS}/third_party/jobs/jobs.py" ]; then
    JOBS="$("${DEPOT_TOOLS}/third_party/jobs/jobs.py" -j 1 2>/dev/null || echo "$(nproc)")"
  else
    JOBS="$(nproc)"
    [ "${RAM_GB}" -lt 16 ] && JOBS=$(( JOBS > 4 ? JOBS / 2 : JOBS ))
  fi
fi

# --- Generate --------------------------------------------------------------
mkdir -p "${OUT_DIR}"

ARGS_FILE="${SCRIPT_DIR}/gn/bootowser.args"
[ -f "${ARGS_FILE}" ] || die "missing ${ARGS_FILE}"

log "gn gen ${OUT_DIR}"
gn gen "${OUT_DIR}" \
  --args-file "${ARGS_FILE}" \
  ${EXTRA_ARGS:+"${EXTRA_ARGS}"}

# --- Build -----------------------------------------------------------------
log "ninja -C ${OUT_DIR} ${TARGET} -j${JOBS}"
ninja -C "${OUT_DIR}" -j"${JOBS}" "${TARGET}"

BIN="$(find "${OUT_DIR}" -maxdepth 1 -type f -name chrome -print -quit)"
[ -n "${BIN}" ] || die "build finished but no 'chrome' binary found in ${OUT_DIR}"

SIZE_MB="$(du -m "${BIN}" | cut -f1)"
log "built ${BIN} (${SIZE_MB} MB)"

# Sanity check: the patch series must actually be in the binary, otherwise we
# silently produced an un-hardened kiosk.
if strings "${BIN}" 2>/dev/null | grep -q -- '--bootowser-config'; then
  log "Bootowser switches present: OK"
else
  die "Bootowser switches missing from the binary - the patch series did not apply.
     Re-run apply-patches.sh, or pass --no-patches only if you know what you are doing."
fi

cat <<EOF

Next steps:
  1. Install the runtime:   tools/install.sh
  2. Enable at boot:         systemctl enable bootowser.service
  3. Or package it:         packaging/{arch,debian,fedora}

See docs/building.md for packaging the resulting binary.
EOF