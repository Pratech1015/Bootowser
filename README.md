# Bootowser

A boot splash that keeps going.

Bootowser is a stripped-down Chromium that replaces your desktop with a single
fullscreen web page. No tabs. No omnibox. No settings. No extensions. No
telemetry. It starts at boot and shows the page you chose, and that is the
entire user interface.

Your boot splash stays exactly as it is. Bootowser ships no splash of its own:
whatever Plymouth theme your distribution already uses finishes booting, then
the browser takes the screen. Nothing about your existing boot looks different
until Bootowser is ready to replace it.

## What it is for

Single-purpose Linux devices where a desktop environment is more than the
device needs:

- **digital signage** and menu boards
- **information kiosks** in lobbies, museums, clinics
- **TV-style displays** showing a dashboard, a timetable, a status page
- **appliance-style front ends** for hardware that only shows one thing

If you want a browser you can browse in, use Firefox. If you want a computer
that shows exactly one page and cannot be wandered off from, this is that.

## Why it starts on the boot screen

Most kiosk setups boot into a window manager, wait for the network, wait for a
session, wait for a window manager plugin, and then *maybe* show a page. The
user stares at a spinner for ninety seconds.

Bootowser skips all of that. It orders itself after
`plymouth-quit-wait.service`, so your existing boot splash stays up until the
display server is genuinely ready and then gets out of the way — no flash, no
dead frame, no desktop in between.

## Install

> **Heads up:** you are building Chromium. Budget 40 GB of disk, several
> hours, and patience. There is no prebuilt binary for your distribution yet —
> see [Status](#status).

```sh
git clone https://github.com/Pratech1015/Bootowser
cd Bootowser

# 1. build the browser (the long part)
cd browser && ./fetch.sh && ./build.sh && cd ..

# 2. install the runtime
sudo ./tools/install.sh --browser
```

Then set your page:

```sh
sudo $EDITOR /etc/bootowser/bootowser.conf
```

```ini
START_URL="https://example.com/menu"
```

And start it:

```sh
sudo systemctl enable --now bootowser
```

`install.sh` masks `getty@tty1.service` so the kiosk owns the console. See
[docs/architecture.md](docs/architecture.md#recovering-a-wedged-device) for
how to get your login prompt back.

### Distro packages

Packaging is in place for all three major families:

| | |
| --- | --- |
| Arch | `packaging/arch/PKGBUILD` |
| Fedora | `packaging/fedora/bootowser.spec` |
| Debian/Ubuntu | `packaging/debian/` |
| anything | `tools/install.sh` |

All four expect an already-built Chromium binary rather than building it for
you, because a multi-hour compile has no business happening during
`pacman -Syu`.

### The boot splash

There is nothing to configure. Bootowser does not install, replace or
configure any boot splash, and it does not need to: it simply orders itself
after `plymouth-quit-wait.service`, so your existing theme gets to finish
first.

One thing is worth doing, because it is about your bootloader rather than
about Bootowser — if you want the kiosk without seeing the bootloader menu on
every boot:

```sh
sudo bootctl set-timeout 0
```

On encrypted root filesystems the passphrase prompt keeps working normally,
since there is no Bootowser theme sitting in its way.

## Configuration

Everything lives in `/etc/bootowser/bootowser.conf`. The keys you actually
need:

| key | default | what it does |
| --- | --- | --- |
| `START_URL` | `about:blank` | the page to show. `http`/`https` only. |
| `SCREEN_SIZE` | `1920x1080` | Xorg virtual screen size |
| `SCREEN_DEPTH` | `24` | framebuffer depth |
| `DISABLE_GPU` | `false` | software rendering, for broken GPUs |
| `IDLE_BLANK_MINUTES` | `10` | blank the screen after N minutes, `0` disables |
| `IDLE_SUSPEND_MINUTES` | `0` | suspend the system after N minutes |
| `EXTRA_SWITCHES` | | passed straight to Chromium |
| `VERBOSE` | `false` | Chromium `--v=1` logging |

Two switches are stripped from the browser regardless of what you put here:
`--bootowser-allow-exit` does not exist, and the remote-debugging flags are
removed by patch 0002. See [docs/security.md](docs/security.md).

## How it stays locked

Three independent layers, any one of which would be enough:

1. **Build time** — features a kiosk does not need are not compiled in
   (Safe Browsing, metrics, crash reporting, extensions, printing, spellcheck,
   translation, the updater). Most of the size reduction, zero runtime cost.
2. **Policy time** — 43 managed Chromium policies: no sign-in, no sync, no
   password manager, no developer tools, `chrome://*` blocked, popups and
   permissions denied.
3. **Binary time** — a patch in `ChromeMainDelegate::PreSandboxStartup()`
   removes the remote-debugging and file-access switches before any subsystem
   reads them, forces kiosk mode, and a `NavigationThrottle` cancels any
   navigation that is not http, https or `about:blank`.

The managed policy is in one auditable file you can read:
`runtime/etc/bootowser/policies/managed/bootowser.json`.

**There is no keyboard shortcut out of the kiosk.** If a kiosk has an exit
hatch, somebody will use it. Recovery is Ctrl+Alt+F2, then
`systemctl stop bootowser`.

## Status

This is an early project. Be honest about what that means:

- The patch series is verified against Chromium `154.0.8037.92` in CI, and
  `tools/verify-patches.sh` proves every patch still applies and still does
  what it claims. It has **not** been run through a full Chromium build by
  the author, because the machine it was written on had 1.9 GB of free disk.
  Expect to fix compile errors on your first real build.
- No prebuilt packages are published. You build it.

Read [docs/building.md](docs/building.md) before starting.

## Documentation

| | |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | how the pieces hand off, and the lockdown layers |
| [docs/building.md](docs/building.md) | requirements, fetch/patch/build, rolling Chromium forward |
| [docs/browser.md](docs/browser.md) | every patch, line by line |
| [docs/security.md](docs/security.md) | what this does and does not protect you from |

## Contributing

Patches welcome, especially ones that help Chromium churn survive. See
[docs/browser.md](docs/browser.md#adding-a-patch) — one file per patch,
`format-patch`, add a `verify-patches.sh` assertion.

## Licence

Bootowser's own code is GPL-3.0-or-later; see [LICENSE](LICENSE).

The browser is Chromium, which is BSD-licensed and carries its own licence
files. The patches here modify Chromium source and are therefore distributed
under GPL-3.0-or-later, which is compatible with Chromium's BSD terms. A
binary you build from this repository is a combined work: it carries
Chromium's BSD licence and notices alongside this repository's GPL text.