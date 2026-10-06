# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed

- **Bootowser is now Firefox-based.** The previous Chromium implementation has
  been replaced. This is a rewrite of the browser layer, not a tweak to it.

  Why: Chromium needs tens of gigabytes and hours to build, and carries a
  patch series that must be regenerated whenever upstream moves a file.
  Firefox has a built-in `--kiosk` mode that already does the hard part, and
  the default build applies no patches at all, so it does not have that
  maintenance problem.

  - Replaced the Chromium launcher and build pipeline with `firefox/fetch.sh`
    and `firefox/mozconfig-bootowser`. The optional build is no longer needed
    to run Bootowser: `install.sh` uses the distribution's Firefox by default.
  - Replaced 43 managed Chromium policies with 47 managed Firefox policies and
    about 96 locked preferences, in
    `runtime/etc/bootowser/policies/managed/policies.json`.
  - Deleted `browser/` (fetch, patch, build, GN args and the three-patch
    series), `docs/browser.md`, `tools/verify-patches.sh` and the "Patch
    broken against Chromium" issue template.
  - Rewrote the packaging for all three families to install a Firefox *tree*
    rather than a single binary, falling back to the system install when no
    tree is staged.

### Added

- **Command control sidecar** (`bootowser-control`, patch `0006`): the kiosk
  page can run shell commands on the device through a loopback-only HTTP
  API — `/v1/exec` as the kiosk user, `/v1/root` for root hooks limited to
  the shipped scripts in `/usr/lib/bootowser/commands` via `sudo -n` and a
  sudoers rule. Ships as its own systemd unit with `NoNewPrivileges=false`
  (deliberately, so setuid exec works), an origin allow-list plus optional
  token gate, an admin console on `/`, and `network.lna.*` policy locks so
  Firefox 156's Local Network Access check does not refuse the page's
  fetches. `tools/test-control.sh` exercises the whole API matrix; see
  `docs/control.md`.
- `firefox/fetch.sh` — shallow clone of a pinned Firefox release tag, with
  filesystem and free-space checks that refuse NTFS, exFAT, FAT, NFS and CIFS
  before downloading anything.
- `firefox/mozconfig-bootowser` — the "safe strip" build profile: tests, DTDs,
  crash reporter, telemetry, system add-ons, updater, search plumbing and
  experiments all off. Keeps a normal release optimiser and working codecs.
- `tools/firefox-policy-names.txt` and a CI check that every policy name in
  `policies.json` is a real Firefox policy. Firefox silently ignores names it
  does not recognise, so a typo is an invisible hole in the lockdown.

### Fixed

- **The Debian packaging could copy the entire root filesystem.** `ffdir` was
  set on one `rules` recipe line and used on another; Make runs each
  un-continued line in a separate shell, so it was empty at the copy and
  `cp -a "$ffdir"/.` became `cp -a "/."`. Fixed with `.ONESHELL:` and `$$`
  escaping, plus an explicit guard that refuses to copy from `/` or an empty
  path in the Arch, Fedora and Debian packagers alike.
- An explicitly set `BOOTOWSER_FIREFOX` that was not a usable browser tree used
  to be ignored in favour of the system Firefox. It is now a hard error, rather
  than silently shipping a different browser than the operator asked for.
- `bootowser.service` set `RestrictNamespaces=true`, which would have broken
  Firefox's content sandbox outright — it creates a user namespace per content
  process. Now an allow-list of the namespace types the sandbox needs. Also
  added `HOME` pointing at the state directory, because Firefox creates it on
  first run and `ProtectHome=true` turned that into a failure to start.
- `packaging/debian/rules` never created `debian/bootowser/lib/systemd/system`,
  so a real `dpkg-buildpackage` would have failed installing the units.

### Known limitations

- **Navigation is not restricted.** Firefox's kiosk mode hides the user
  interface but does not confine the browser to one URL, and Firefox has no
  allow-list policy. A link, a redirect or a script can change what the screen
  shows. Closing this needs a Gecko `NavigationThrottle` patch, which is not
  written yet. See `docs/security.md`.
- **No source build has been run.** The runtime and policy have been exercised
  with Firefox 156, but `firefox/fetch.sh` and `mozconfig-bootowser` have not
  been through a full `./mach build`.

### Removed

- **Bootowser no longer ships or configures a Plymouth theme.** Recorded here
  rather than as a release, since it predates 0.1.0 being usable.
  - Removed `plymouth/theme.bootowser/` and `tools/gen-plymouth-assets.py`.
  - Removed the `--theme` flag from `tools/install.sh` and `--keep-theme` from
    `tools/uninstall.sh`, along with all code that installed, activated or
    restored a theme.
  - `bootowser.service` still orders itself after `plymouth-quit-wait.service`,
    so the system's existing splash finishes first and the browser takes the
    screen cleanly. No splash is installed and no `plymouth` command is run.
  - Dropped the `plymouth` packaging dependency from the Arch, Fedora and
    Debian metadata.

Two things follow, both improvements: encrypted roots just work, since nothing
sits in front of the stock theme's passphrase prompt; and there is no theme
script to keep working across Plymouth API changes.

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