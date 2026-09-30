#!/usr/bin/env bash
#
# install.sh - install the Bootowser runtime onto this machine.
#
# Installs the launcher, the display server config, the managed policy, the
# Plymouth theme and the systemd units, then creates the bootowser user and
# masks the console getty so the kiosk can own vt1.
#
# The browser binary is NOT installed by this script: build it first with
# browser/build.sh and point --browser at it, or let the package manager do it.
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
readonly REPO_ROOT
readonly PREFIX="${BOOTOWSER_PREFIX:-/usr}"
readonly LIB_DIR="${PREFIX}/lib/bootowser"
readonly SHARE_DIR="${PREFIX}/share/bootowser"
readonly UNIT_DIR="${PREFIX}/lib/systemd/system"
readonly THEME_DIR="${PREFIX}/share/plymouth/themes"
readonly ETC_DIR="/etc/bootowser"
readonly STATE_DIR="/var/lib/bootowser"
readonly SERVICE_USER="bootowser"

ENABLE_THEME=0
ENABLE_SERVICE=0
ENABLE_NOW=0
BROWSER_BIN=""

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

  --browser PATH   install PATH as ${LIB_DIR}/chrome (required to actually boot)
  --theme          make theme.bootowser the active Plymouth theme
  --enable         enable bootowser.service at boot
  --now            start bootowser.service immediately (implies --enable)
  --prefix DIR     install under DIR instead of ${PREFIX}
  --no-mask-getty  do not mask getty@tty1 (you will lose console access to vt1)
  -h, --help       show this help

After installing, set START_URL in ${ETC_DIR}/bootowser.conf.
EOF
}

MASK_GETTY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --browser)      BROWSER_BIN="$2"; shift 2 ;;
    --theme)        ENABLE_THEME=1; shift ;;
    --enable)       ENABLE_SERVICE=1; shift ;;
    --now)          ENABLE_NOW=1; ENABLE_SERVICE=1; shift ;;
    --prefix)       PREFIX="$2"; shift 2 ;;
    --no-mask-getty) MASK_GETTY=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root"

command -v systemctl >/dev/null 2>&1 || die "systemd is required"

# --- System user -----------------------------------------------------------
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  log "creating system user ${SERVICE_USER}"
  useradd --system --home-dir "${STATE_DIR}" --shell /usr/sbin/nologin \
          --comment "Bootowser kiosk browser" "${SERVICE_USER}"
else
  log "system user ${SERVICE_USER} already exists"
fi

# video/render: GPU acceleration. input: raw evdev for the kiosk's own hotkeys.
for grp in video render input; do
  getent group "${grp}" >/dev/null 2>&1 || continue
  if ! id -nG "${SERVICE_USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
    log "adding ${SERVICE_USER} to group ${grp}"
    usermod -aG "${grp}" "${SERVICE_USER}"
  fi
done

# --- Layout ----------------------------------------------------------------
log "installing to ${PREFIX}"
install -d -m 0755 "${LIB_DIR}" "${SHARE_DIR}" "${UNIT_DIR}"
install -d -m 0755 "${ETC_DIR}" "${ETC_DIR}/policies/managed"
install -d -m 0700 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
              "${STATE_DIR}" "${STATE_DIR}/profile"

# --- Launcher and helpers --------------------------------------------------
install -m 0755 "${REPO_ROOT}/runtime/bin/bootowser"          "${LIB_DIR}/bootowser"
install -m 0755 "${REPO_ROOT}/runtime/bin/bootowser-xsession" "${LIB_DIR}/bootowser-xsession"

# --- Config: install defaults, never clobber an operator's edits ----------
conf_src="${REPO_ROOT}/runtime/etc/bootowser/bootowser.conf"
conf_dest="${ETC_DIR}/bootowser.conf"
if [ -e "${conf_dest}" ]; then
  warn "${conf_dest} already exists, leaving it alone"
  install -m 0644 "${conf_src}" "${conf_dest}.dist"
else
  install -m 0644 "${conf_src}" "${conf_dest}"
fi

policy="${REPO_ROOT}/runtime/etc/bootowser/policies/managed/bootowser.json"
if [ -e "${ETC_DIR}/policies/managed/bootowser.json" ]; then
  warn "existing managed policy left in place (copy ${policy} to ${ETC_DIR}.new and merge)"
  install -m 0644 "${policy}" "${ETC_DIR}/policies/managed/bootowser.json.dist"
else
  install -m 0644 "${policy}" "${ETC_DIR}/policies/managed/bootowser.json"
fi

# --- Xorg config -----------------------------------------------------------
install -m 0644 "${REPO_ROOT}/runtime/xorg/xorg.conf" "${SHARE_DIR}/xorg.conf"

# --- Browser binary --------------------------------------------------------
if [ -n "${BROWSER_BIN}" ]; then
  [ -x "${BROWSER_BIN}" ] || die "browser binary not executable: ${BROWSER_BIN}"
  log "installing browser binary"
  install -m 0755 "${BROWSER_BIN}" "${LIB_DIR}/chrome"
  # Chromium's runtime bits: locales, ANGLE, swiftshader, .pak files. Without
  # these the browser starts and then renders nothing at all.
  src_dir="$(dirname "$(readlink -f "${BROWSER_BIN}")")"
  for d in locales swiftshader; do
    if [ -d "${src_dir}/${d}" ]; then
      log "installing ${d}/"
      cp -a "${src_dir}/${d}" "${LIB_DIR}/"
    fi
  done
  shopt -s nullglob
  for pak in "${src_dir}"/*.pak; do
    install -m 0644 "${pak}" "${LIB_DIR}/"
  done
  if [ -f "${src_dir}/icudtl.dat" ]; then
    install -m 0644 "${src_dir}/icudtl.dat" "${LIB_DIR}/"
  fi
  if [ -x "${src_dir}/chrome_sandbox" ]; then
    log "installing SUID sandbox helper"
    install -m 4755 -o root -g root "${src_dir}/chrome_sandbox" "${LIB_DIR}/chrome_sandbox"
  fi
else
  warn "no --browser given: ${LIB_DIR}/chrome is missing, the kiosk will not start yet"
fi

# --- Plymouth theme --------------------------------------------------------
log "installing Plymouth theme"
install -d -m 0755 "${THEME_DIR}/theme.bootowser"
install -m 0644 "${REPO_ROOT}"/plymouth/theme.bootowser/* "${THEME_DIR}/theme.bootowser/"

if command -v plymouth >/dev/null 2>&1; then
  if [ "${ENABLE_THEME}" -eq 1 ]; then
    log "enabling theme.bootowser"
    plymouth set-default-theme bootowser
    plymouth update-theme
  else
    log "theme installed but not activated (pass --theme to activate)"
  fi
else
  warn "plymouth is not installed; the theme was copied but cannot be activated"
fi

# --- systemd ---------------------------------------------------------------
log "installing systemd units"
install -m 0644 "${REPO_ROOT}/runtime/lib/systemd/system/bootowser.service" \
               "${UNIT_DIR}/bootowser.service"
install -m 0644 "${REPO_ROOT}/runtime/lib/systemd/system/bootowser-xserver.service" \
               "${UNIT_DIR}/bootowser-xserver.service"

if [ "${MASK_GETTY}" -eq 1 ]; then
  log "masking getty@tty1 so the kiosk owns the console"
  log "  (undo with: systemctl unmask getty@tty1.service)"
  systemctl mask getty@tty1.service >/dev/null 2>&1 || \
    warn "could not mask getty@tty1.service"
fi

systemctl daemon-reload

if [ "${ENABLE_SERVICE}" -eq 1 ]; then
  log "enabling bootowser.service"
  systemctl enable bootowser.service bootowser-xserver.service
fi

if [ "${ENABLE_NOW}" -eq 1 ]; then
  log "starting bootowser.service"
  systemctl restart bootowser.service
  log "watch it with: journalctl -fu bootowser"
fi

cat <<EOF

Bootowser runtime installed.

Next:
  1. Set your start URL:        \$EDITOR ${ETC_DIR}/bootowser.conf
  2. Start it now:              systemctl start bootowser
  3. Follow the log:            journalctl -fu bootowser
  4. Undo everything:           ${REPO_ROOT}/tools/uninstall.sh

Note: on a LUKS-encrypted root the Plymouth theme cannot render a passphrase
prompt. Keep your distribution's default Plymouth theme and enable Bootowser
after unlock. See docs/security.md.
EOF