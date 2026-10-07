# Bootowser

A boot splash that keeps going.

Bootowser takes over your screen at boot and shows one fullscreen web page. It
runs Firefox in its built-in kiosk mode, so there are no tabs, no address bar,
no context menu and no user interface, under a managed policy that turns off
telemetry, accounts, updates, developer tools and the password manager.

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

Bootowser skips all of that. The browser starts the moment its display
server is up — no splash wait, no login session, no window manager — so the
first frame is a page instead of a desktop. The cost of going that early:
on a Plymouth system the splash can be cut short while it is still painting.
`--wait-for-splash` orders the browser after `plymouth-quit-wait.service`
instead (see [The boot splash](#the-boot-splash)).

## Install

**You do not need to build anything.** Firefox already exists on your system.

```sh
git clone https://github.com/Pratech1015/Bootowser
cd Bootowser

sudo ./tools/install.sh
```

Then set your page:

```sh
sudo $EDITOR /etc/bootowser/bootowser.conf
```

```ini
START_URL="https://example.com/menu"
```

And start it (the install has already enabled the units at boot — pass
`--no-enable` to `install.sh` to opt out of that):

```sh
sudo systemctl start bootowser
```

`install.sh` masks `getty@tty1.service` so the kiosk owns the console. See
[docs/architecture.md](docs/architecture.md#recovering-a-wedged-device) for
how to get your login prompt back.

### Shipping your own Firefox

Your distribution's Firefox can be replaced by a package update, which is not
under Bootowser's control. If you need a fixed, stripped binary that only
changes when you say so, build one:

```sh
cd firefox
./fetch.sh --dest /mnt/fast/firefox-src      # a drive with 30 GB free
cp mozconfig-bootowser /mnt/fast/firefox-src/.mozconfig
cd /mnt/fast/firefox-src && ./mach bootstrap && ./mach build
cd -
sudo ./tools/install.sh --browser /mnt/fast/firefox-src/obj-bootowser/dist/bin/bootowser
```

That build is optional. See [docs/building.md](docs/building.md) before starting
it, particularly the disk and filesystem requirements.

### Distro packages

| | |
| --- | --- |
| Arch | `packaging/arch/PKGBUILD` |
| Fedora | `packaging/fedora/bootowser.spec` |
| Debian/Ubuntu | `packaging/debian/` |
| anything | `tools/install.sh` |

All four use the system Firefox by default, and bundle a tree instead when you
point them at one with `BOOTOWSER_FIREFOX=...`.

### The boot splash

There is nothing Bootowser-side to install: it does not ship, replace or
configure any boot splash. Your distribution's own theme keeps running
untouched, and on encrypted roots the passphrase prompt keeps working
normally, since there is no Bootowser theme sitting in its way.

By default the browser starts the moment its display server is up, which can
cut a Plymouth splash short. If the splash has to finish first — a LUKS
passphrase prompt, or simply a theme you want to see to completion — order
the browser after it:

```sh
sudo ./tools/install.sh --wait-for-splash
```

or copy
`runtime/lib/systemd/system/bootowser.service.d/wait-for-splash.conf` to
`/etc/systemd/system/bootowser.service.d/` and run `systemctl daemon-reload`.

One thing is worth doing, because it is about your bootloader rather than
about Bootowser — if you want the kiosk without seeing the bootloader menu on
every boot:

```sh
sudo bootctl set-timeout 0
```

## Configuration

Everything lives in `/etc/bootowser/bootowser.conf`. The keys you actually
need:

| key | default | what it does |
| --- | --- | --- |
| `START_URL` | `https://start.example.com` | the page to show. `http`/`https` only. |
| `FULLSCREEN` | `yes` | `no` opens the page in a window instead of `--kiosk` (debugging) |
| `WINDOW_SIZE` | `1280x720` | window size when `FULLSCREEN="no"` |
| `DISABLE_NEW_TABS` | `yes` | refuse new tabs (page `window.open`, Ctrl+T, Ctrl/middle-click); a plain `target=_blank` click follows in the current tab; patched build only |
| `SCREEN_SIZE` | `auto` | Xorg virtual screen size |
| `SCREEN_DEPTH` | `24` | framebuffer depth |
| `DISABLE_GPU` | `no` | software rendering, for broken GPUs |
| `IDLE_BLANK_MINUTES` | `0` | blank the screen after N minutes, `0` disables |
| `IDLE_SUSPEND_MINUTES` | `0` | suspend the system after N minutes |
| `EXTRA_SWITCHES` | | passed straight to Firefox |
| `PROFILE_DIR` | `/var/lib/bootowser/profile` | profile location, point at tmpfs to keep it in RAM |

There is deliberately no allow-exit switch, and no way to add one from here.

If you use the command control API, its keys live separately in
`/etc/bootowser/control.conf` — most importantly `ALLOWED_ORIGINS`, which
must match your `START_URL`'s origin. See
[docs/page-guide.md](docs/page-guide.md) for building a page that talks
to it, [docs/control.md](docs/control.md) for the API and
[docs/security.md](docs/security.md#the-command-control-api) for what
allowing an origin means.

## How it stays locked

Two layers:

1. **Kiosk mode** — Firefox's own `--kiosk` (the default `FULLSCREEN="yes"`)
   gives fullscreen that cannot be exited from inside the browser, with no
   context menu and no status UI. `FULLSCREEN="no"` gives that layer up for a
   debug window; the policy below and the source patches still apply either
   way.
2. **Policy** — 47 managed policies in one auditable file: no sign-in, no
   telemetry, no updates, no studies, no developer tools, no about:config, no
   password manager, no printing, no remote settings.

The policy file is `runtime/etc/bootowser/policies/managed/policies.json`. It is
installed into the Firefox tree at
`<install dir>/distribution/policies.json`, which is where Firefox actually
reads policy from; the launcher verifies that path on every start and refuses to
run if the policy that would win is missing or is not a Bootowser policy.

**There is no keyboard shortcut out of the kiosk.** If a kiosk has an exit
hatch, somebody will use it. Recovery is Ctrl+Alt+F2, then
`systemctl stop bootowser`.

## What this does not protect you from

Firefox's kiosk mode does not stop the page itself from navigating elsewhere —
no address bar, but a link, a redirect or a script can still take over the
screen. Firefox has no allow-list policy, so the only way to enforce "this URL
and nothing else" is a source patch, which Bootowser does not yet ship.

This is a real gap, not a footnote. Read
[docs/security.md](docs/security.md) before deploying, and read the section on
navigation before you trust a kiosk on a network you do not control.

## Status

This is an early project. Be honest about what that means:

- The runtime, policy lockdown and packaging have been exercised on EndeavourOS
  with Firefox 156. The policy file itself was verified to load by Firefox with
  zero rejected preferences. But **no full Firefox build from source has been
  run yet**, and the kiosk has not been run against a real X server and systemd
  handoff. The optional `firefox/` build tree is unproven; expect to fix things.
- Navigation is not restricted. See above.
- No prebuilt packages are published.

## Documentation

| | |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | how the pieces hand off, and the lockdown layers |
| [docs/building.md](docs/building.md) | requirements, fetching and building Firefox |
| [docs/control.md](docs/control.md) | the page-driven command API: endpoints, config, root hooks |
| [docs/page-guide.md](docs/page-guide.md) | hands-on: add shell commands and build the page that runs them |
| [docs/security.md](docs/security.md) | what this does and does not protect you from |

## Licence

Bootowser's own code is GPL-3.0-or-later; see [LICENSE](LICENSE).

Firefox is MPL-2.0-licensed and carries its own licence files. If you bundle a
Firefox you built, it keeps its MPL-2.0 terms alongside this repository's GPL
text.