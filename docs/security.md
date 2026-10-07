# Security model

Bootowser runs an unattended browser on a device that is usually in a public
place, showing a page an operator chose. Treat it as a locked-down appliance,
not as a general-purpose browser.

## What the kiosk is good at

Keeping the operator's page on screen, with no browser chrome for a passer-by to
fiddle with, and no trivial way out.

## What navigation confinement does and does not do

Firefox's `--kiosk` hides the user interface. On its own it does not confine
the browser: a link can be clicked, an HTTP redirect can land elsewhere, a
script can set `window.location`, and a served page can simply differ on the
next reload. So Bootowser enforces this in source instead. Patch `0001` in
`firefox/patches/` cancels any **top-level** navigation outside a short allow-list,
at the two choke points in `nsDocShell` every such navigation passes through.

This stops the page steering the kiosk into privileged space:

- `about:config`, `about:addons`, `view-source:`, `resource:`, `devtools://`
- `file://`, which would be arbitrary local file read
- `javascript:` and other pseudo-schemes
- any scheme added by a future Firefox that nobody has thought about yet

Sub-frames are deliberately untouched. A page may embed what it likes; it just
cannot navigate the kiosk itself out of the web.

**This is a scheme allow-list, not a host allow-list.** It does not pin the
kiosk to one site. A redirect to any other HTTPS origin is still permitted,
because there is no Firefox policy that can express "this URL and nothing
else" — `WebsiteFilter` is a *block*-list.

So the honest statement of the threat boundary:

> Anyone who can influence the network path can change *which site* the kiosk
> displays. They cannot change *what kind of thing* the kiosk is displaying.

Closing the first half would need either a redirect-blocking proxy on the
network path or a configured allow-list of hosts in the navigation patch. The
former needs no root on the device and is the better recommendation.

### The allow-list is slightly wider than "http and https"

It also permits `chrome://`, `about:blank`, `about:newtab`, `about:home` and
`moz-extension://`. None of these are reachable from page content, so none is an
escape route:

- `chrome://` is already refused to a non-chrome caller by the security manager,
  before any docshell is involved. It is allowed here only because Firefox loads
  its own window and browser-UI documents (`chrome://global/content/win.xhtml`,
  `chrome://browser/content/browser.xhtml`) through this same code path.
- `moz-extension://` requires an extension to hold host permission that page
  content does not have.

That list is load-bearing, and getting it wrong is not hypothetical: a revision
allowing only `http`/`https`/`about:blank` produced a browser that could not draw
its own window, and `about:newtab` plus the bundled extensions' background pages
broke the same way. Patch `0001` documents this, and the way to catch it is a
real launch, not just a compile.

`chrome://` is not *unreachable* in a kiosk, though, and it is worth being exact
about how. A page cannot navigate to it, but the person standing at the machine
can type it: `chrome://browser/content/browser.xhtml` opens a second, live
browser-UI document *inside a content tab*, URL bar and all. It is not an
escalation — that document runs the same compiled-in lockdown, so no key below is
live in it either, and its own navigation is filtered by the same allow-list —
but it is a reachable privileged document, and treating "a user typed it" as
out of scope is an assumption, not a control.

Patch `0002` closes three UI escape hatches that `--kiosk` leaves behind, since
policy binds neither keyboard shortcuts nor Chrome commands:

| key | was | now |
| --- | --- | --- |
| <kbd>Ctrl</kbd>+<kbd>O</kbd> | file picker: arbitrary local file read | refused |
| <kbd>Ctrl</kbd>+<kbd>L</kbd> | focus the URL bar, navigate anywhere | refused |
| <kbd>F12</kbd> | devtools console in the page's own chrome context | refused |

The devtools one matters most. Once the console is open, no policy setting puts
it away, and it is arbitrary code execution in the context the lockdown is
protecting.

Patch `0004` then removes the rest of the chrome that `--kiosk` only hides. It
drops 28 `<key>` elements from the browser's key set — new tab, search, file,
save, print, quit, history, bookmarks, sidebar, private browsing, clear data,
restore session and the rest — and gates the <kbd>F10</kbd> menu-bar handler. What
is kept is what a kiosk actually needs: new tab, reload, find, fullscreen, zoom,
back/forward, and view-source (which the allow-list then refuses anyway).

The visible chrome — app menu, PanelUI, menu bar, bookmarks toolbar, sidebar and
vertical tabs, downloads, account, zoom, all-tabs, overflow, panic — is hidden
with CSS behind a `bootowser="true"` attribute on the toolbox, not deleted.
Deleting those nodes breaks startup: browser JavaScript dereferences several of
them unconditionally. The same patch makes three missing-key lookups null-safe,
which is the other half of removing elements instead of hiding them.

The new tab is `about:blank` in the dark theme: `NewTabPage: false` disables
Activity Stream and the locked `browser.theme.content-theme: 0` keeps the blank
page dark, instead of shipping a second theme to mirror. `DisplayMenuBar: "never"`
is the string form on purpose — the boolean form only writes an xulstore value,
whereas the string form disallows the feature, so browser-init drops the menu bar
out of the toolbox entirely, and locks `ui.key.menuAccessKeyFocuses` so
<kbd>Alt</kbd> cannot bring it back.

These are refused in the commands themselves, gated on `bootowser.build` — a
*static* pref compiled in from the `MOZ_BOOTOWSER` define. It cannot be changed
by a policy file, by `about:config`, or by anything the page loads, because a
kiosk whose lockdown can be undone from inside the browser is not locked down.
If you build without `--enable-bootowser`, none of this is compiled in and you
have stock Firefox plus a policy file.

## The command control API

The kiosk page can ask the device to run shell commands. That is a deliberate
capability, so it needs a deliberate boundary; full reference in
[control.md](control.md). In this model:

- **`/v1/exec` is not an escalation.** It runs `sh -c` as the kiosk user —
  the same user the page already is. Its blast radius is what the page could
  do with a form anyway; it exists for ergonomics, not privilege.
- **The origin header is the boundary.** Only pages from `ALLOWED_ORIGINS`
  (your `START_URL`'s origin) may call the API at all, and the sidecar binds
  loopback only. A page the kiosk was steered onto by a redirect still gets
  `403` unless you allowed its origin — one reason to keep the navigation
  allow-list and `ALLOWED_ORIGINS` in sync.
- **Root is script-shaped, not shell-shaped.** `/v1/root` runs only files
  directly inside `/usr/lib/bootowser/commands/`, which must be root-owned,
  not group/world-writable, via a sudoers rule that names exactly that
  directory. The page cannot pass a root shell, a path, or an `arg` that
  breaks out of the script's own parsing — and any script shipped there must
  treat its arguments as hostile, because they are.
- **The sidecar cannot be the weak link by accident.** It runs as the kiosk
  user in its own hardened unit (`NoNewPrivileges=false` is the deliberate
  exception, so `sudo` can work — see the unit's comments), never as root,
  and audits every execution to the journal.

What this does change: **the origin allow-list becomes part of your security
boundary.** If you widen `ALLOWED_ORIGINS`, you are handing shell access on
the kiosk user — and script access as root, if you ship hooks — to every
page at that origin.

Local Network Access locking (`network.lna.enabled` /
`network.lna.blocking` = `false`) is part of this feature: without it
Firefox 156 refuses or prompts for the page's loopback fetches. Both prefs
stay locked in the policy file.

## No sandbox hardening from upstream's threat model

Firefox's content sandbox is present and enabled. That sandbox exists to
contain *hostile web content*, not to contain a kiosk against its own page.
Do not point Bootowser at sites you would not point a browser at.

Note that `bootowser.service` cannot use `RestrictNamespaces=true`: Firefox
creates a user namespace per content process, and that would break the
sandbox rather than strengthen it. The unit restricts namespaces to an
allow-list instead, and `CapabilityBoundingSet=` is empty. If Firefox ever
fails to start its sandbox, **do not add `CAP_SYS_ADMIN` to make the error go
away** — that removes the containment entirely.

## Safe Browsing and updates

Both are off by default. `DisableAppUpdate` and `DisableTelemetry` are set, the
`app.update.*` preferences are locked off, and patch `0005` compiles the
updater, the crash reporter and Normandy (remote experiments) out of the
browser entirely.

Safe Browsing being off is deliberate and consistent: with no updater, the
download-based blocklists would never refresh anyway. If you want it, re-enable
it in `runtime/etc/bootowser/policies/managed/policies.json` and accept that
you are now allowing background network traffic the rest of this design tries
to remove.

**No crash reports.** The crash reporter is disabled, so the systemd journal is
your only diagnostic. That is a real cost of this design, not an oversight.

## Physical access

Anyone who can press keys can reboot and reach the bootloader. Bootowser cannot
prevent that. If the threat model includes a hostile person with physical
access:

- set a firmware/bootloader password,
- mark the Bootowser partition read-only,
- and remember that a device in the attacker's hands is lost.

There is deliberately **no** allow-exit switch. It is a flag nobody remembers
to turn off.

Recovery is from a TTY, not from the kiosk:

```sh
# Ctrl+Alt+F2..F6, then
sudo systemctl stop bootowser
```

## Encrypted root filesystems (LUKS)

**Not a problem, by design.**

Bootowser ships no boot splash. It installs nothing into
`/usr/share/plymouth/themes` and runs no `plymouth` command, so your
distribution's own theme keeps handling the unlock prompt exactly as before.
By default the browser starts as soon as its display server is up; with the
wait-for-splash drop-in (`tools/install.sh --wait-for-splash`) it orders
itself after `plymouth-quit-wait.service` instead, so the browser appears
only once the machine is unlocked and the splash released.

To come up as early as possible after unlock:

```ini
# /etc/systemd/system/bootowser.service.d/unlock.conf
[Unit]
Wants=bootowser.service
After=systemd-cryptsetup.target
```

## `EXTRA_SWITCHES` is a policy hole

`EXTRA_SWITCHES` in `bootowser.conf` is passed straight to Firefox. Unlike the
Chromium version of this project, there is no launcher-side filter that strips
dangerous switches, because Firefox has no equivalent patch yet.

Firefox does not have Chromium's `--remote-debugging-port` CDP endpoint, so the
worst of those switches are gone by construction. But `--allow-file-access-...`
style options, profile overrides and `-profile`-adjacent flags are not. Keep
that file root-owned and treat edits to it as a privileged change.

## What the policy removes

One file, `runtime/etc/bootowser/policies/managed/policies.json`, 47 policies
and 86 locked preferences. The notable ones:

| Removed | Why |
| --- | --- |
| `DisableDeveloperTools`, `BlockAboutConfig` | no debugging escape from inside the page |
| `DisableTelemetry`, `DisableFirefoxStudies` | no phoning home, no experiments |
| `DisableAppUpdate`, `ManualAppUpdateOnly` | no surprise browser changes |
| `DisableFirefoxAccounts`, `PasswordManagerEnabled=false` | no sign-in state to leak or be stolen |
| `BlockAboutProfiles`, `BlockAboutAddons`, `BlockAboutSupport` | no UI that would accept an escape |
| `PrintingEnabled=false`, `OfferToSaveLogins=false` | no local file writes to steal |
| `DisablePrivateBrowsing` | private mode is an exit hatch, not a feature |
| `NewTabPage=false`, `FirefoxHome` search off | nothing to navigate to |

CI validates every policy name against a vendored copy of Mozilla's policy list
(`tools/firefox-policy-names.txt`). Firefox **silently ignores** unknown policy
names, so a typo is an invisible hole in the lockdown; that check exists
specifically to catch it.

Note `Preferences` entries are `"Status": "locked"`, which stops users
overriding them in about:config. That is the point — it is what makes the
policy a floor rather than a suggestion.

### `Preferences` entries have a prefix allow-list

Firefox does **not** honour every preference in a `Preferences` policy. It
accepts only names starting with an allowed prefix (`browser.`, `dom.`,
`network.`, `intl.`, `ui.`, `toolkit.legacyUserProfileCustomizations.stylesheets`,
and a short list of others), plus an explicit allow-list for `security.*`. A
name outside those is dropped with only a console error, so the preference looks
applied in the policy file but is not.

Ten entries were removed from `policies.json` for this reason — `toolkit.telemetry.*`,
`datareporting.healthreport.uploadEnabled`, `services.settings.server`,
`device.sensors.enabled`, `privacy.trackingprotection.enabled`,
`privacy.donottrackheader.enabled`, `toolkit.startup.max_resumed_crashes`,
`full-screen-api.warning.timeout` and `xpinstall.signatures.required`. Most were
redundant with real policies (`DisableTelemetry`, `DisableAppUpdate`, …) or
already the Firefox default, so nothing was lost.

`xpinstall.signatures.required` is additionally rejected whenever the build sets
`MOZ_REQUIRE_SIGNING`, which is the default for official Mozilla builds and for
any `--enable-official-branding` build. Never rely on it in Bootowser policy.

To verify a policy actually lands, run Firefox with
`user_pref("browser.policies.loglevel","debug")` and
`user_pref("browser.dom.window.dump.enabled",true)` set in the profile, then look
for `Unable to set preference …` lines. The CI job
`validate-firefox-policy` performs the equivalent static check.

## The X server

The bundled `xorg.conf` listens on a unix socket only, never on TCP
(`-nolisten tcp`). There is no window manager, no desktop environment and no
auto-starting client, so the X session contains nothing but the browser.

Access control is the soft spot: the server has no authentication cookie, so
any local process running as any user can connect and snoop or screenshot. On a
single-purpose kiosk that is usually acceptable. If the device is multi-user,
run Bootowser inside a session with real X authorisation instead of the
bundled server.

## Profile and cookies

The profile lives in `/var/lib/bootowser/profile`, mode `0700`, owned by
`bootowser`. It is **not** wiped between boots unless `PROFILE_DIR` points at a
tmpfs. For a session that leaves nothing behind:

```ini
PROFILE_DIR="/run/bootowser/profile"
```

plus in `bootowser.service`:

```ini
RuntimeDirectory=bootowser
RuntimeDirectoryMode=0700
```

`SanitizeOnShutdown` is locked on, so cookies and cache are cleared when
Firefox exits cleanly — but a power cut skips that, which is why tmpfs is the
better answer.

## Reporting a vulnerability

Open a GitHub issue for ordinary bugs. For something that looks like a kiosk
escape, please open a private security advisory on the repository rather than a
public issue.