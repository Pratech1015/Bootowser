#!/usr/bin/env bash
#
# uninstall.sh - remove Bootowser and give the console back to getty.
#
# By default this removes the runtime but keeps the browser profile and the
# operator's config, because silently deleting a device's kiosk profile is a
# nasty surprise. Pass --purge to remove those too.
#
# Bootowser ships no Plymouth theme of its own, so there is nothing here to
# restore: whatever boot splash the machine used before is still configured.
#
set -euo pipefail

# Mutable so --prefix works; the derived paths are computed after parsing.
PREFIX="${BOOTOWSER_PREFIX:-/usr}"
ETC_DIR="${BOOTOWSER_ETC_DIR:-/etc/bootowser}"
STATE_DIR="${BOOTOWSER_STATE_DIR:-/var/lib/bootowser}"

PURGE=0
ASSUME_NO=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

  --purge         also delete ${STATE_DIR} (browser profile) and ${ETC_DIR}
  --prefix DIR    act on DIR instead of ${PREFIX} (for testing)
  --yes           do not prompt for confirmation
  -h, --help      show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)      PURGE=1; shift ;;
    --prefix)     PREFIX="$2"; shift 2 ;;
    --yes|-y)     ASSUME_NO=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [ "${ASSUME_NO}" -ne 1 ]; then
  printf 'Remove Bootowser and restore getty on tty1? [y/N] '
  read -r reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) log "aborted"; exit 0 ;;
  esac
fi

LIB_DIR="${PREFIX}/lib/bootowser"
SHARE_DIR="${PREFIX}/share/bootowser"
UNIT_DIR="${PREFIX}/lib/systemd/system"

# Mirrors install.sh: refuse to touch systemd or /etc unless we are root,
# but allow a dry run against a throwaway prefix so the layout is testable.
if [ "$(id -u)" -ne 0 ]; then
  if [ "${ALLOW_UNPRIVILEGED_TESTING:-0}" != 1 ]; then
    die "must be run as root (or set ALLOW_UNPRIVILEGED_TESTING=1 for a dry run)"
  fi
  case "${PREFIX}" in
    /tmp/*|/var/tmp/*) : ;;
    *) die "ALLOW_UNPRIVILEGED_TESTING requires a --prefix under /tmp" ;;
  esac
  warn "running unprivileged against ${PREFIX}; this is a dry run"
  UNPRIV=1
  ETC_DIR="${PREFIX}/etc/bootowser"
  STATE_DIR="${PREFIX}/var/lib/bootowser"
else
  UNPRIV=0
fi
readonly LIB_DIR SHARE_DIR UNIT_DIR ETC_DIR STATE_DIR

# --- Stop and disable ------------------------------------------------------
if [ "${UNPRIV}" -eq 1 ]; then
  warn "dry run: not touching systemd"
elif command -v systemctl >/dev/null 2>&1; then
  log "stopping and disabling bootowser units"
  systemctl disable --now bootowser.service bootowser-xserver.service \
                     bootowser-control.service 2>/dev/null || true

  # Give the console back before anything else, so a failure below still
  # leaves the machine bootable and reachable.
  if systemctl is-enabled --quiet getty@tty1.service 2>/dev/null || \
     [ -L /etc/systemd/system/getty@tty1.service ]; then
    log "restoring getty@tty1"
    systemctl unmask getty@tty1.service 2>/dev/null || true
    systemctl enable getty@tty1.service 2>/dev/null || true
  fi

  systemctl daemon-reload
  systemctl reset-failed bootowser.service 2>/dev/null || true
fi

# --- Files -----------------------------------------------------------------
# The unit files are removed regardless of whether systemd was reachable, so a
# --prefix dry run still cleans up after itself.
rm -f "${UNIT_DIR}/bootowser.service" "${UNIT_DIR}/bootowser-xserver.service" \
      "${UNIT_DIR}/bootowser-control.service"

# The sudoers rule hands root to scripts under LIB_DIR, so it must not
# outlive them. Its directory mirrors install.sh: /etc/sudoers.d for a real
# install, ${PREFIX}/etc/sudoers.d for a dry run.
if [ "${UNPRIV}" -eq 1 ]; then
  rm -f "${PREFIX}/etc/sudoers.d/bootowser"
else
  rm -f /etc/sudoers.d/bootowser
fi

log "removing ${LIB_DIR}"
rm -rf "${LIB_DIR}"

# A policy installed into the host Firefox tree (the no---browser case) lives
# outside LIB_DIR and would otherwise be orphaned in a package-managed tree.
for host in /usr/lib/bootowser /usr/lib/firefox /usr/lib64/firefox /usr/lib/firefox-esr; do
  if [ -f "${host}/distribution/policies.json" ] \
     && grep -q '"BootowserManaged"[[:space:]]*:[[:space:]]*true' \
          "${host}/distribution/policies.json" 2>/dev/null; then
    log "removing Bootowser policy from ${host}/distribution"
    rm -f "${host}/distribution/policies.json"
    rmdir "${host}/distribution" 2>/dev/null || true
  fi
done

log "removing ${SHARE_DIR}"
rm -rf "${SHARE_DIR}"

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