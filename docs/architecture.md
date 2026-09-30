# Architecture

Bootowser is two programs that hand the screen to each other, plus the
configuration that keeps them honest.

```
        firmware / bootloader
                 |
                 v
        +-------------------+   your distribution's existing boot
        |     plymouthd     |   splash. Bootowser ships none of its
        |  (stock theme)    |   own and never touches this.
        +-------------------+
                 |  plymouth-quit-wait.service
                 v
        +-------------------+   bootowser-xserver.service
        |     Xorg          |   minimal, no WM, no network, on vt1
        +-------------------+
                 |
                 v
        +-------------------+   bootowser.service, as user "bootowser"
        |   chromium        |   --bootowser --kiosk=<url>
        |   (patched +      |   no tabs, no omnibox, no settings
        |    stripped)      |
        +-------------------+
```

## Why a display server is in here

Chromium cannot paint on a bare text console. Something has to own the
framebuffer and hand a window to the browser. Bootowser ships a deliberately
minimal Xorg configuration for this, because the alternative — a full desktop
environment — is exactly the bloat this project exists to remove.

If a display server is *already* running, the launcher notices the X socket
and reuses it, so Bootowser also works inside an existing desktop session for
development.

`bootowser-xserver.service` runs as root because X needs to become DRM master
and switch virtual terminals. The browser itself runs unprivileged as
`bootowser`, confined by the unit's sandboxing directives.

## The three layers of lockdown

Bootowser deliberately does not put all its eggs in one basket. Three
independent layers have to fail before a user gets out of the kiosk.

### 1. Build time — `browser/gn/bootowser.args`

Features that are dead weight for a single-purpose display are not compiled
in: Safe Browsing, metrics, crash reporting, extensions, printing, spellcheck
dictionaries, translation, mDNS, Chrome's updater. Most of the size reduction
happens here, and it costs nothing at runtime.

### 2. Policy time — `runtime/etc/bootowser/policies/managed/bootowser.json`

43 managed Chromium policies: no sign-in, no sync, no password manager, no
autofill, no developer tools, downloads blocked, `chrome://*` and
`devtools://*` blocked by URL, popups/permissions denied by default.

Policy is preferred over patches wherever it can express the same intent,
because it is auditable in one file and adjustable without a rebuild.

### 3. Command line — `browser/patches/0002`

Some things are not expressible as policy. `ChromeMainDelegate::PreSandboxStartup()`
sanitises the command line before any subsystem reads it:

- **removed**: `--remote-debugging-port`, `--remote-debugging-pipe`,
  `--remote-allow-origins`, `--remote-debugging-socket-name`,
  `--remote-debugging-io-pipes`, `--disable-web-security`,
  `--allow-file-access-from-files`, `--load-extension`,
  `--disable-extensions-except`, `--renderer-cmdline`, `--js-flags`
- **forced**: `--kiosk`, `--no-first-run`, `--hide-crash-restore-bubble`
- **removed**: `--app`, `--app-id`, `--restore-last-session`

This is the layer that matters most, because it is enforced in the binary and
cannot be turned off from inside the kiosk.

### 4. Navigation time — `browser/patches/0003`

A `NavigationThrottle` that cancels any main-frame navigation which is not
http, https or `about:blank`. Policy's `URLBlocklist` is a runtime control an
operator can weaken; this is not.

## Taking the screen from the boot splash

Bootowser ships **no boot splash of its own**. It installs nothing into
`/usr/share/plymouth/themes` and never invokes `plymouth`, so the theme you
already had keeps behaving exactly as it did — including on encrypted roots,
where it still renders the passphrase prompt. Bootowser does not have to
solve that problem, because it is not in the way.

The hand-off is one line in `bootowser.service`:

```
After=bootowser-xserver.service plymouth-quit-wait.service
```

`plymouth-quit-wait.service` blocks until Plymouth has genuinely released the
screen, so Bootowser never draws over a splash that is still up. Listing it in
`After=` is harmless on a distribution that does not ship Plymouth at all,
because systemd ignores ordering against units that do not exist — which is
what keeps one unit file working on Debian, Fedora and Arch.

The visible result: your boot splash does what it always did, then the browser
appears. No flicker, no desktop, no login screen in between.

## Why the patch series is only three patches

Chromium moves. A tree that is well organised today has files renamed next
quarter: in the 154 series alone, `chrome_switches.cc` was deleted,
`startup_utils.cc` moved to `ui/startup/`, and `chrome/browser/ui/web_ui/`
disappeared entirely.

Every patch in this repository touches **exactly one file**, is **generated
with `git format-patch`** against a **pinned tag** recorded in
`browser/CHROMIUM_VERSION`, and is checked by
`tools/verify-patches.sh`, which fetches only the handful of upstream files
the series touches and replays the patches against them in CI. Rolling
Chromium forward is therefore a small, reviewable job rather than a rewrite.

## Recovering a wedged device

There is deliberately no keyboard shortcut out of the kiosk. A kiosk with an
exit hatch is not a kiosk. To recover:

1. Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>F2</kbd> (through F6) to reach a TTY.
2. `systemctl status bootowser`
3. `systemctl stop bootowser`

The unit masks `getty@tty1.service` so the kiosk owns the console. Switch to a
different TTY, or restore it from another machine:

```
systemctl unmask getty@tty1.service
systemctl enable getty@tty1.service
```

`tools/uninstall.sh` does all of this for you.