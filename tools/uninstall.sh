#!/usr/bin/env bash
#
# uninstall.sh - remove Bootowser and give the console back to getty.
#
# By default this removes the runtime but keeps the browser profile and the
# operator's config, because silently deleting a device's kiosk profile is a
# nasty surprise. Pass --purge to remove those too.
#
set -euo pipefail

readonly PREFIX="${BOOTOWSER_PREFIX:-/usr}"
readonly LIB_DIR="${PREFIX}/lib/bootowser"
readonly SHARE_DIR="${PREFIX}/share/bootowser"
readonly UNIT_DIR="${PREFIX}/lib/systemd/system"
readonly THEME_DIR="${PREFIX}/share/plymouth/themes/theme.bootowser"
readonly ETC_DIR="/etc/bootowser"
readonly STATE_DIR="/var/lib/bootowser"

PURGE=0
KEEP_THEME=0
ASSUME_NO=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

  --purge         also delete ${STATE_DIR} (browser profile) and ${ETC_DIR}
  --keep-theme    leave the Plymouth theme installed
  --yes           do not prompt for confirmation
  -h, --help      show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)      PURGE=1; shift ;;
    --keep-theme) KEEP_THEME=1; shift ;;
    --yes|-y)     ASSUME_NO=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "${ASSUME_NO}" -ne 1 ]; then
  printf 'Remove Bootowser and restore getty on tty1? [y/N] '
  read -r reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) log "aborted"; exit 0 ;;
  esac
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root"

# --- Stop and disable ------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  log "stopping and disabling bootowser units"
  systemctl disable --now bootowser.service bootowser-xserver.service 2>/dev/null || true

  # Give the console back before anything else, so a failure below still
  # leaves the machine bootable and reachable.
  if systemctl is-enabled --quiet getty@tty1.service 2>/dev/null || \
     [ -L /etc/systemd/system/getty@tty1.service ]; then
    log "restoring getty@tty1"
    systemctl unmask getty@tty1.service 2>/dev/null || true
    systemctl enable getty@tty1.service 2>/dev/null || true
  fi

  log "restoring the previous Plymouth theme if possible"
  if command -v plymouth >/dev/null 2>&1 && [ "${KEEP_THEME}" -eq 0 ]; then
    plymouth set-default-theme 2>/dev/null || warn "could not restore the default Plymouth theme"
    plymouth update-theme 2>/dev/null || true
  fi

  rm -f "${UNIT_DIR}/bootowser.service" "${UNIT_DIR}/bootowser-xserver.service"
  systemctl daemon-reload
  systemctl reset-failed bootowser.service 2>/dev/null || true
fi

# --- Files -----------------------------------------------------------------
log "removing ${LIB_DIR}"
rm -rf "${LIB_DIR}"

log "removing ${SHARE_DIR}"
rm -rf "${SHARE_DIR}"

if [ "${KEEP_THEME}" -eq 0 ]; then
  log "removing ${THEME_DIR}"
  rm -rf "${THEME_DIR}"
fi

if [ "${PURGE}" -eq 1 ]; then
  log "purging ${STATE_DIR} and ${ETC_DIR}"
  rm -rf "${STATE_DIR}" "${ETC_DIR}"

  if id -u bootowser >/dev/null 2>&1; then
    log "removing the bootowser system user"
    userdel bootowser 2>/dev/null || true
  fi
else
  log "keeping ${STATE_DIR} and ${ETC_DIR} (pass --purge to remove them)"
fi

log "done"
if [ "${PURGE}" -eq 0 ]; then
  echo
  echo "Remaining, if you want them gone too:"
  echo "  ${0} --purge"
fi