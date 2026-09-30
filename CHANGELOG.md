# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Bootowser no longer ships or configures a Plymouth theme.** This is the
  only change in 0.1.0, so it is recorded here rather than as a release.
  - Removed `plymouth/theme.bootowser/` and `tools/gen-plymouth-assets.py`.
  - Removed the `--theme` flag from `tools/install.sh` and `--keep-theme`
    from `tools/uninstall.sh`, along with all code that installed, activated
    or restored a theme.
  - `bootowser.service` still orders itself after `plymouth-quit-wait.service`,
    so the system's existing splash finishes first and the browser takes the
    screen cleanly. No splash is installed and no `plymouth` command is run.
  - Dropped the `plymouth` packaging dependency from the Arch, Fedora and
    Debian metadata. It is now only ever something the host distribution
    provides.

Two things follow from this, both of them improvements:

- **Encrypted roots now just work.** Bootowser installs nothing into
  `/usr/share/plymouth/themes`, so a stock Plymouth theme still renders the
  LUKS passphrase prompt. The limitation described in earlier drafts is gone
  rather than worked around.
- **Less to maintain.** There is no theme script to keep working across
  Plymouth API changes, and nothing to see on screen between boot and the
  browser appearing — the host's own splash, unchanged.

## [0.1.0] - 2026-09-30

First release. The project is at the point where the runtime, the build
pipeline and the packaging all exist and are verified statically, but no
Chromium binary has been compiled from source yet.

### Added

- **Chromium patch series** against `154.0.8037.92`, three patches each
  touching one file:
  - `--bootowser`, `--bootowser-config` and `--bootowser-verbose` switches.
  - Startup lockdown in `ChromeMainDelegate::PreSandboxStartup()`: removes
    remote-debugging, `--disable-web-security`, `--allow-file-access-from-files`,
    extension-loading, `--renderer-cmdline` and `--js-flags`; forces kiosk
    mode; appends `--no-first-run`.
  - `BootowserNavigationThrottle`, cancelling any main-frame navigation that
    is not http, https or `about:blank`.
- **`tools/verify-patches.sh`**, which fetches the upstream files the series
  touches, replays the series with `git am --3way` and asserts each patch's
  intent. Runs in CI, so upstream churn is caught before it breaks a release.
- **Build pipeline**: `browser/fetch.sh` (slim `gclient sync`), `apply-patches.sh`
  (tag-checked and idempotent), `build.sh` (gn + ninja, then asserts the
  built binary really contains the patch).
- **`browser/gn/bootowser.args`**: release-mode stripped build. No Safe
  Browsing, metrics, crash reporting, extensions, printing, spellcheck,
  translation, mDNS or updater.
- **Runtime**: `bootowser` and `bootowser-xsession` launchers, a minimal
  Xorg configuration with no window manager and no TCP listener, and 43
  managed Chromium policies in `bootowser.json`.
- **Systemd units**: `bootowser-xserver.service` and `bootowser.service`,
  ordered against `plymouth-quit-wait.service` so the system's existing boot
  splash stays up until the display server is ready. Bootowser installs no
  splash of its own and never configures Plymouth, so the stock theme — and
  its LUKS passphrase prompt — keep working untouched.
- **Packaging**: Arch `PKGBUILD`, Fedora spec, Debian source package, and a
  generic `tools/install.sh` / `tools/uninstall.sh`.
- **Documentation**: architecture, building, patch-by-patch browser notes, and
  an explicit security model.

### Known limitations

- The X server runs without an authentication cookie, so any local process
  can connect to it. Acceptable on a single-purpose kiosk, not on a multi-user
  machine.
- The bundled X server is plain Xorg with no auto-login and no session
  restart; a browser crash is handled by systemd `Restart=always` rather than
  by the display server restarting itself.
- No prebuilt binaries or distribution packages are published.
- No all-features build has been completed. Compile errors are likely on the
  first real build.

[Unreleased]: https://github.com/Pratech1015/Bootowser/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Pratech1015/Bootowser/releases/tag/v0.1.0