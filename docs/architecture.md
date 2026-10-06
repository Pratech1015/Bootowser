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
        |     bootowser     |   --kiosk, plus managed policies
        |    the patched    |   no tabs, no omnibox, no settings
        | Firefox 156 build |
        +-------------------+
```

## Why a display server is in here

Firefox cannot paint on a bare text console. Something has to own the
framebuffer and hand a window to the browser. Bootowser ships a deliberately
minimal Xorg configuration for this, because the alternative — a full desktop
environment — is exactly the bloat this project exists to remove.

If a display server is *already* running, the launcher notices the X socket
and reuses it, so Bootowser also works inside an existing desktop session for
development.

`bootowser-xserver.service` runs as root because X needs to become DRM master
and switch virtual terminals. The browser itself runs unprivileged as
`bootowser`, confined by the unit's sandboxing directives.

## The layers of lockdown

### 1. Kiosk mode — the command line

`runtime/bin/bootowser` builds the command line from
`/etc/bootowser/bootowser.conf` and execs the browser with `--kiosk`. Gecko's own
kiosk mode is fullscreen with no exit path, no context menu, no URL bar and no
loading status.

Two things about how this launcher works are deliberate:

- it **refuses to run** if the policy directory is missing, rather than
  starting an unrestricted browser;
- it **refuses** a `file://` `START_URL`, because a local file loaded as the
  kiosk page is a local read primitive with no legitimate kiosk use;
- it **refuses to fall back to a distro Firefox** unless `ALLOW_SYSTEM_BROWSER=1`
  is set. A distro browser carries none of the patches in layer 3, so running one
  silently drops the navigation allow-list and the removed escape hatches.

### 2. Policy time — `runtime/etc/bootowser/policies/managed/policies.json`

47 managed Firefox policies and 86 locked preferences: no sign-in, no
telemetry, no studies, no updates, no developer tools, no `about:config`, no
password manager, no printing, no private browsing, no new-tab page, no search.

Policy is preferred over patches wherever it can express the same intent,
because it is auditable in one file and adjustable without a rebuild.

Three details worth knowing:

- `Preferences` entries are `"Status": "locked"`, which prevents a user
  overriding them in `about:config`. Locked is the difference between a policy
  being a floor and being a suggestion.
- Firefox **silently ignores policy names it does not recognise**. A typo is an
  invisible hole, so CI checks every name against a vendored copy of Mozilla's
  policy list.
- Firefox also silently ignores `Preferences` names outside its prefix
  allow-list. Ten entries had to be dropped for this reason; see
  [security.md](security.md).

#### Where the file has to end up

Firefox resolves managed policy from one of two paths, in this order, from
`JSONPoliciesProvider` in `EnterprisePoliciesParent.sys.mjs`:

1. `$SysConfD/policies/policies.json` — that is `/etc/policies/policies.json`,
   **not** `/etc/firefox/policies/`, despite what most guides say;
2. `$XREAppDist/policies.json` — `<install dir>/distribution/policies.json`.

Only if path 1 does not exist is path 2 consulted, so a host policy silently
wins. Bootowser therefore installs the policy *inside the browser tree* it ships,
and the launcher re-checks the resolved path on every start: if the winning file
is missing, or lacks the `"BootowserManaged": true` marker, it exits rather than
run with the wrong policy.

### 3. Build time — `firefox/mozconfig-bootowser`

Bootowser is a Firefox 156 build with the dead weight left out: tests, DTDs,
debug symbols, WebSpeech and the WASM sandboxed libraries are all off. This
layer expresses what the other two cannot, which is why the launcher will not
silently substitute a distro browser for it.

The same file carries the product's identity: `--with-app-name=bootowser` plus
`MOZ_APP_BASENAME`, `MOZ_APP_PROFILE` and `MOZ_APP_VENDOR` rename the executable
and `application.ini`, which also moves the profile root to `~/.bootowser` — a
dedicated-profiles layout, so it shares nothing with a real Firefox on the same
machine — and the
patch series rewrites the branding strings under `browser/branding/` to say
Bootowser. The one deliberate exception is the User Agent, which stays
`Firefox/156.0` so pages that gate on it keep working.

Note that `--disable-debug` is deliberately *not* used. Those configs produce
unoptimised builds, which is precisely wrong for a display that repaints
forever.

### What is missing

**Navigation is not restricted.** This is the significant gap, and it is not a
layer that exists by omission — Firefox has no policy that can express "this URL
and only this URL", and Bootowser ships no Gecko patch to do it. A link, a
redirect or a script can still change what the screen shows.

The Chromium version of this project closed that with a `NavigationThrottle`
patch. Firefox would need the same, in `docshell/`. Until it exists, see
[docs/security.md](security.md#navigation-is-not-restricted) before deploying.

There is also no launcher-side switch filter, because Firefox has no CDP
endpoint for one to be aimed at. `EXTRA_SWITCHES` is therefore root-only
territory.

## The control sidecar

`bootowser-control` (patch `0006`, built from `toolkit/bootowser-control/`)
is the kiosk page's way back out to the device: a loopback-only HTTP API
that runs shell commands as the kiosk user and root hooks via `sudo -n`.
It is a **separate process in a separate systemd unit**, not part of the
browser, because `bootowser.service` runs Firefox with
`NoNewPrivileges=true` — nothing inside that process can ever exec a setuid
binary, so an in-browser `sudo` is a kernel-level impossibility, not a
policy question. The unit's `Wants=`/`After=` on `bootowser-control.service`
means the API is listening before the page loads;
`ConditionPathExists=/usr/lib/bootowser/bootowser-control` makes installs
without a patched tree run featureless instead of broken.

The full API, configuration and the security reasoning live in
[docs/control.md](control.md); the threat-model consequences in
[docs/security.md](security.md#the-command-control-api).

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

## Where the lockdown actually lives

Two layers, deliberately not the same kind of thing.

**The policy file is configuration.** It records what the kiosk is allowed to
do, it is readable, and anyone with the machine can edit it. That is the right
layer for things an operator should be able to change: the home page, whether
the password manager is offered, which certificates are trusted.

**The patch series is the floor.** `firefox/patches/` compiles the parts that
must not be negotiable into the binary:

| patch | enforces |
| --- | --- |
| `0001` | top-level navigations are limited to http/https/about:blank |
| `0002` | Ctrl+O, Ctrl+L and F12 do nothing |
| `0004` | the 28 unused key bindings and the F10 menu bar are gone from the binary, not just hidden |
| `0005` | the crash reporter, updater and remote-experiment runner are compiled out, so nothing can put a dialog or a background updater on top of the kiosk display |

The reason this is not left to policy: `--kiosk` removes the chrome but nothing
in it stops the *page* from navigating away. A link, a redirect, a form target
or a script can replace what is on screen, and at that point the kiosk is
showing whatever the page chose. Policy can block `about:*` through
`URLBlocklist`, but that is a runtime control on a disk file, and it will not
automatically cover schemes Firefox grows later.

There is no third layer, on purpose. In particular there is no runtime switch,
no pref, and no hidden URL that re-enables what the patches remove, because a
kiosk that can be talked out of its lockdown from inside the browser it is
protecting is not locked down. `bootowser.build`, which the chrome-side hatches
key off, is a *static* pref: it is compiled in from the `MOZ_BOOTOWSER` define
and cannot be changed by a policy file, by `about:config`, or by anything the
page loads.

## Why the series is kept small

The Chromium version of this project carried a three-patch series against a
9000-line file that Mozilla reorders constantly. The Firefox series is two
commits, about 300 lines, against files Mozilla moves far less often.

That is the whole reason for preferring Firefox here, and it is a real
constraint to keep respecting: every patch is a merge conflict waiting to
happen. When adding one, prefer a narrow anchor at a stable point in a file
over a wide hunk in a hot one. `nsDocShell.cpp` is the expensive file, so the
navigation check is one self-contained function inserted next to an existing
guard rather than edits spread through `LoadURI`.

Rolling forward is then a version bump in `firefox/FIREFOX_VERSION` and a
`--check`. See [docs/building.md](building.md).

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

## Recovering a kiosk that shows the wrong thing

The unit has `Restart=always` with `RestartSec=3`, so a browser that crashes
comes straight back. If it comes back showing the wrong page, the problem is
almost never the kiosk and almost always `START_URL` or a redirect on the
server side:

```sh
journalctl -u bootowser -b --no-pager | grep bootowser:
```

The launcher logs the exact command line it exec'd before starting it.