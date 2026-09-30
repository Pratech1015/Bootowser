# Security model

Bootowser runs an unattended browser on a device that is usually in a public
place, showing a page an operator chose. Treat it as a locked-down appliance,
not as a general-purpose browser.

## What the kiosk is good at

Making sure the operator's page is the only thing on screen, and that nothing
can trivially change that.

## What it is not

It is **not** a hardened multi-tenant browser, and it should not be exposed to
untrusted networks or used to browse arbitrary sites. Specifically:

- **No sandbox escape hardening from upstream's threat model.** Chromium's
  renderer sandbox is present and enabled, but the kiosk threat model is
  "operator's own page", not "hostile web content". Do not point Bootowser at
  sites you would not point a browser at.
- **Safe Browsing is disabled** in the default build. The updater is also
  disabled, so the download-based blocklists would never refresh anyway. On an
  internet-facing device, set `safe_browsing_mode = 2` in
  `browser/gn/bootowser.args` and rebuild.
- **No telemetry of any kind.** `enable_metrics`, `enable_reporting` and the
  crash reporter are all off. This is a privacy win and also means you get no
  crash reports: the systemd journal is your only diagnostic.

## Physical access

Anyone who can press keys on the device can, in principle, reboot it and get
into the bootloader. Bootowser cannot prevent that. If the threat model
includes a hostile person with physical access:

- set a firmware/bootloader password,
- mark the Bootowser partition read-only,
- and remember that a device in the attacker's hands is lost.

The `ALLOW_EXIT`-style escape hatch was deliberately **not** implemented. It
is a switch nobody remembers to turn off.

## Encrypted root filesystems (LUKS)

**Bootowser does not support rendering a Plymouth passphrase prompt.**

Plymouth's raw key handler delivers numeric keycodes, and its scripting
language has no verified way to convert those back into characters. Rather
than ship a passphrase field we could not test, `theme.bootowser` detects that
a question is pending, hides the progress bar, and says so:

> This device needs to be unlocked before Bootowser can start

If your root filesystem is encrypted, keep your distribution's **default**
Plymouth theme and enable Bootowser after unlock:

```ini
[Unit]
Wants=bootowser.service
After=systemd-cryptsetup.target bootowser-xserver.service
```

Alternatively, move the unlock step out of the initramfs (network-bound
unlock, a TPM-sealed key, or `crypttab` with `x-systemd.device-timeout`).

## What the lockdown actually removes

Enforced in the binary (`browser/patches/0002`), so it cannot be turned off
from inside the kiosk:

| Removed | Why |
| --- | --- |
| `--remote-debugging-port` / `-pipe` | a CDP endpoint is a full browser remote control |
| `--remote-allow-origins` | allows a web page to reach that endpoint |
| `--remote-debugging-socket-name` / `-io-pipes` | same, different transports |
| `--disable-web-security` | turns off the same-origin policy |
| `--allow-file-access-from-files` | turns `file://` URLs into a local read primitive |
| `--load-extension` | arbitrary code with the browser's privileges |
| `--disable-extensions-except` | ditto |
| `--renderer-cmdline` | injects switches into sandboxed children |
| `--js-flags` | injects V8 flags, e.g. `--jitless` or worse |
| `--app`, `--app-id`, `--restore-last-session` | would escape forced kiosk mode |

And at navigation time (`browser/patches/0003`), any main-frame navigation
that is not `http`, `https` or `about:blank` is cancelled — including
`chrome://`, `devtools://`, `chrome-extension://`, `view-source:` and
`file://`. Sub-frame loads are left alone: a page may embed whatever it
likes, but it can never navigate the kiosk itself out of the web.

## The X server

The bundled `xorg.conf` listens on a unix socket only, never on TCP
(`-nolisten tcp`). There is no window manager, no desktop environment, and no
auto-starting client, so there is nothing in the X session but the browser.

Access control is the one soft spot: the server has no authentication
cookie, so any local process running as any user can connect to it and snoop
or screenshot. On a single-purpose kiosk this is usually acceptable. If the
device is multi-user, run Bootowser inside a session with proper X
authorisation instead of the bundled server.

## Profile and cookies

The browser profile lives in `/var/lib/bootowser/profile`, mode `0700`,
owned by `bootowser`. It is **not** wiped between boots unless
`PROFILE_DIR` points at a tmpfs. To get a session that leaves nothing behind:

```ini
PROFILE_DIR="/run/bootowser/profile"
```

and add to `bootowser.service`:

```ini
RuntimeDirectory=bootowser
RuntimeDirectoryMode=0700
```

## Reporting a vulnerability

Open a GitHub issue for ordinary bugs. For something that looks like a
kiosk escape, please open a private security advisory on the repository
rather than a public issue.