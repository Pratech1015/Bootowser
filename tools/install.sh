#!/usr/bin/env bash
#
# install.sh - install the Bootowser runtime onto this machine.
#
# Installs the launcher, the display server config, the managed policy and the
# systemd units, then creates the bootowser user and masks the console getty so
# the kiosk can own vt1.
#
# No boot splash is installed. Whatever Plymouth theme the machine already uses
# keeps showing during boot, and bootowser.service simply waits for
# plymouth-quit-wait.service before taking the screen.
#
# Bootowser is NOT installed by this script: point --browser at a build tree
# (see firefox/fetch.sh). A distro Firefox is only usable with
# ALLOW_SYSTEM_BROWSER=1, because it has none of the source patches.
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
readonly REPO_ROOT
# PREFIX stays mutable: --prefix has to be able to change it. Everything
# derived from it is computed after argument parsing, further down.
PREFIX="${BOOTOWSER_PREFIX:-/usr}"
# Config always lives in /etc, except in an unprivileged dry run, where there
# is no root to write there and the point is only to exercise the file layout.
ETC_DIR="${BOOTOWSER_ETC_DIR:-/etc/bootowser}"
STATE_DIR="${BOOTOWSER_STATE_DIR:-/var/lib/bootowser}"
readonly SERVICE_USER="bootowser"

ENABLE_SERVICE=0
ENABLE_NOW=0
BROWSER_BIN=""

usage() {
  # LIB_DIR is derived from PREFIX further down, and this runs before that.
  # Under `set -u` an unset reference aborts, so --help would not even print.
  local lib_dir="${PREFIX}/lib/bootowser"
  cat <<EOF
Usage: ${0##*/} [options]

  --browser DIR    install the Bootowser tree from DIR as ${lib_dir}/bootowser
                   (optional; see ALLOW_SYSTEM_BROWSER below)
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
    --enable)       ENABLE_SERVICE=1; shift ;;
    --now)          ENABLE_NOW=1; ENABLE_SERVICE=1; shift ;;
    --prefix)       PREFIX="$2"; shift 2 ;;
    --no-mask-getty) MASK_GETTY=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Derived now that --prefix has been applied.
LIB_DIR="${PREFIX}/lib/bootowser"
SHARE_DIR="${PREFIX}/share/bootowser"
UNIT_DIR="${PREFIX}/lib/systemd/system"
readonly LIB_DIR SHARE_DIR UNIT_DIR
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Creating the service user, chowning the profile and touching systemd all
# need root. ALLOW_UNPRIVILEGED_TESTING exists so the install layout can be
# exercised in CI and by anyone without a root shell; it is never set by the
# packages, and it is refused outright unless this is a throwaway prefix.
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

# Now that any dry-run override has been applied, freeze them.
readonly ETC_DIR STATE_DIR

command -v systemctl >/dev/null 2>&1 || die "systemd is required"

# --- System user -----------------------------------------------------------
if [ "${UNPRIV}" -eq 1 ]; then
  log "skipping the system user (dry run)"
elif ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  log "creating system user ${SERVICE_USER}"
  useradd --system --home-dir "${STATE_DIR}" --shell /usr/sbin/nologin \
          --comment "Bootowser kiosk browser" "${SERVICE_USER}"
else
  log "system user ${SERVICE_USER} already exists"
fi

# video/render: GPU acceleration. input: raw evdev for the kiosk's own hotkeys.
if [ "${UNPRIV}" -eq 0 ]; then
  for grp in video render input; do
    getent group "${grp}" >/dev/null 2>&1 || continue
    if ! id -nG "${SERVICE_USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
      log "adding ${SERVICE_USER} to group ${grp}"
      usermod -aG "${grp}" "${SERVICE_USER}"
    fi
  done
fi

# --- Layout ----------------------------------------------------------------
log "installing to ${PREFIX}"
install -d -m 0755 "${LIB_DIR}" "${SHARE_DIR}" "${UNIT_DIR}"
install -d -m 0755 "${ETC_DIR}"
if [ "${UNPRIV}" -eq 0 ]; then
  install -d -m 0700 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
                "${STATE_DIR}" "${STATE_DIR}/profile"
else
  install -d -m 0700 "${STATE_DIR}" "${STATE_DIR}/profile"
fi

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

policy="${REPO_ROOT}/runtime/etc/bootowser/policies/managed/policies.json"

# --- Control sidecar config, sudoers rule, root hooks -----------------------
# Same never-clobber rule as bootowser.conf: the operator tunes
# ALLOWED_ORIGINS per deployment and must not lose it to a reinstall.
control_conf_src="${REPO_ROOT}/runtime/etc/bootowser/control.conf"
control_conf_dest="${ETC_DIR}/control.conf"
if [ -e "${control_conf_dest}" ]; then
  warn "${control_conf_dest} already exists, leaving it alone"
  install -m 0644 "${control_conf_src}" "${control_conf_dest}.dist"
else
  install -m 0644 "${control_conf_src}" "${control_conf_dest}"
fi

# sudo only ever reads /etc/sudoers.d, even for a --prefix install; a
# throwaway dry run gets a look-alike under the prefix instead.
if [ "${UNPRIV}" -eq 1 ]; then
  sudoers_dir="${PREFIX}/etc/sudoers.d"
else
  sudoers_dir="/etc/sudoers.d"
fi
install -d -m 0755 "${sudoers_dir}"
# 0440: sudo insists on group-readable, non-world-writable sudoers files.
install -m 0440 "${REPO_ROOT}/runtime/lib/sudoers.d/bootowser" "${sudoers_dir}/bootowser"

# Root hooks must be root-owned and not writable by others -- RunRoot
# re-checks that before every execution and refuses otherwise, so install
# them the way sudo expects to see them.
install -d -m 0755 "${LIB_DIR}/commands"
for f in "${REPO_ROOT}"/runtime/lib/bootowser/commands/*.sh; do
  install -m 0755 "$f" "${LIB_DIR}/commands/${f##*/}"
done

# --- Xorg config -----------------------------------------------------------
install -m 0644 "${REPO_ROOT}/runtime/xorg/xorg.conf" "${SHARE_DIR}/xorg.conf"

# --- Browser ---------------------------------------------------------------
# Bootowser is a directory, not a single binary: the launcher needs the
# executable, the shared libraries, the chrome/ resource tree and the
# localisation bundles. Copying only the executable produces a browser that
# starts and then renders nothing, so the whole tree is installed.
install_browser_tree() {
  local src="$1" dest="${LIB_DIR}/bootowser"
  # The renamed build produces dist/bin/bootowser; accept a stock firefox binary
  # too so a tree from before the rebrand still installs.
  local exe=""
  for candidate in bootowser firefox; do
    if [ -x "${src}/${candidate}" ]; then exe="${candidate}"; break; fi
  done
  [ -n "${exe}" ] || die "no executable bootowser (or firefox) in ${src}; is this a browser install dir?"
  log "installing Bootowser tree from ${src} (${exe})"
  rm -rf "${dest}"
  mkdir -p "${dest}"
  cp -a "${src}"/. "${dest}/"

  # The control sidecar is part of the same build tree (toolkit/
  # bootowser-control) but installs at a stable path so the unit's
  # ConditionPathExists can tell "no patched tree here" from "broken install".
  # A tree without it (built before the feature) means the page's API is
  # simply unavailable -- bootowser.service still runs.
  if [ -x "${src}/bootowser-control" ]; then
    install -m 0755 "${src}/bootowser-control" "${LIB_DIR}/bootowser-control"
    log "installed control sidecar to ${LIB_DIR}/bootowser-control"
  else
    warn "tree has no bootowser-control; the kiosk page's command API will not work"
  fi

  # Gecko finds libxul.so and the resource tree relative to the real binary
  # path. /usr/lib/bootowser/bootowser is that path after install, but the tree
  # may have been staged elsewhere.
  [ -e "${dest}/libxul.so" ] || warn "installed tree is missing libxul.so; the browser may not start"

  # Note: no omni.ja check. Gecko has not shipped one as a requirement for a
  # long time -- a Firefox 156 build from this tree runs with unpacked chrome/,
  # locales/ and *.ftl files and has no omni.ja at all, so checking for it only
  # ever produced a spurious warning.
  #Gecko reads managed policy from <install dir>/distribution/policies.json,
  # so the policy has to live inside the tree we just installed.
  install -d -m 0755 "${dest}/distribution"
  install -m 0644 "${policy}" "${dest}/distribution/policies.json"
  log "installed policy to ${dest}/distribution/policies.json"
}

if [ -n "${BROWSER_BIN}" ]; then
  # Accept either the install dir or the binary inside it.
  if [ -f "${BROWSER_BIN}" ]; then
    BROWSER_BIN="$(dirname -- "$(readlink -f -- "${BROWSER_BIN}")")"
  fi
  [ -d "${BROWSER_BIN}" ] || die "--browser expects a browser directory or binary, got: ${BROWSER_BIN}"
  install_browser_tree "${BROWSER_BIN}"
else
  # No --browser: fall back to the host package, which is unpatched and so only
  # usable with ALLOW_SYSTEM_BROWSER=1. See the launcher.
  host=""
  for c in /usr/lib/bootowser/bootowser /usr/lib/firefox/firefox \
           /usr/lib64/firefox/firefox /usr/lib/firefox-esr/firefox-esr /usr/bin/firefox
  do
    if [ -x "$c" ]; then host="$c"; break; fi
  done
  if [ -n "${host}" ]; then
    host_dir="$(dirname -- "$(readlink -f -- "${host}")")"
    log "no --browser given; using the system browser at ${host}"
    warn "using the distribution's browser: it can be replaced by a package update, and it carries none of the Bootowser source patches"
    warn "the launcher will refuse to start it unless ALLOW_SYSTEM_BROWSER=1 is set in ${ETC_DIR}/bootowser.conf"
    # A sidecar from an earlier --browser install would keep working here (it
    # is standalone), but offering the API with an unpatched browser in front
    # of it is a support trap: remove it so what runs is what was installed.
    if [ -e "${LIB_DIR}/bootowser-control" ]; then
      warn "removing ${LIB_DIR}/bootowser-control: the control API is only offered with an installed Bootowser tree (--browser)"
      rm -f "${LIB_DIR}/bootowser-control"
    fi
    # The host tree is package-managed, so its policy is written only when the
    # location is ours to use. Otherwise Bootowser would fight the package on
    # every update. A dry run never writes outside its throwaway prefix.
    if [ "${UNPRIV}" -eq 1 ]; then
      warn "dry run: not writing a policy into ${host_dir}"
    elif [ -w "${host_dir}" ]; then
      install -d -m 0755 "${host_dir}/distribution"
      install -m 0644 "${policy}" "${host_dir}/distribution/policies.json"
      log "installed policy to ${host_dir}/distribution/policies.json"
    else
      die "cannot write ${host_dir}/distribution/policies.json; pass --browser DIR to install a private Firefox tree with its policy"
    fi
  else
    warn "no --browser given and no system Firefox found; the kiosk will not start until Firefox is installed"
  fi
fi

# --- systemd ---------------------------------------------------------------
log "installing systemd units"
install -m 0644 "${REPO_ROOT}/runtime/lib/systemd/system/bootowser.service" \
               "${UNIT_DIR}/bootowser.service"
install -m 0644 "${REPO_ROOT}/runtime/lib/systemd/system/bootowser-xserver.service" \
               "${UNIT_DIR}/bootowser-xserver.service"
install -m 0644 "${REPO_ROOT}/runtime/lib/systemd/system/bootowser-control.service" \
               "${UNIT_DIR}/bootowser-control.service"

if [ "${UNPRIV}" -eq 1 ]; then
  warn "dry run: not masking getty@tty1, not reloading or starting systemd"
elif [ "${MASK_GETTY}" -eq 1 ]; then
  log "masking getty@tty1 so the kiosk owns the console"
  log "  (undo with: systemctl unmask getty@tty1.service)"
  systemctl mask getty@tty1.service >/dev/null 2>&1 || \
    warn "could not mask getty@tty1.service"
fi

if [ "${UNPRIV}" -eq 0 ]; then
  systemctl daemon-reload

  if [ "${ENABLE_SERVICE}" -eq 1 ]; then
    log "enabling bootowser units"
    systemctl enable bootowser.service bootowser-xserver.service bootowser-control.service
  fi

  if [ "${ENABLE_NOW}" -eq 1 ]; then
    log "starting bootowser.service"
    systemctl restart bootowser.service
    log "watch it with: journalctl -fu bootowser"
  fi
fi

cat <<EOF

Bootowser runtime installed.

Next:
  1. Set your start URL:        \$EDITOR ${ETC_DIR}/bootowser.conf
  2. Allow your page to call the command API (same origin as START_URL):
                                \$EDITOR ${ETC_DIR}/control.conf
  3. Start it now:              systemctl start bootowser
  4. Follow the log:            journalctl -fu bootowser
  5. Undo everything:           ${REPO_ROOT}/tools/uninstall.sh

Your existing Plymouth theme is untouched: it shows during boot as usual, and
Bootowser takes the screen once plymouth-quit-wait.service releases it. On a
LUKS-encrypted root the passphrase prompt therefore keeps working, because
Bootowser ships no theme of its own to break it.
EOF