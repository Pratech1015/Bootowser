# The patch series

Three patches, each touching exactly one upstream file. If you are reading
this because a patch failed to apply, the file it touches is named in its
header.

`browser/patches/series` lists them in order. They are generated with
`git format-patch` against the tag in `browser/CHROMIUM_VERSION`
(`154.0.8037.92`).

---

## 0001 — `chrome/common/chrome_switches.h`

Adds three switches next to the existing kiosk ones:

```cpp
inline constexpr char kBootowser[] = "bootowser";
inline constexpr char kBootowserConfig[] = "bootowser-config";
inline constexpr char kBootowserVerbose[] = "bootowser-verbose";
```

Chromium is moving its switch table to `constexpr` strings in headers; this
follows that convention rather than adding to the old `.cc` registry that was
deleted in this series.

There is deliberately **no** `kBootowserAllowExit`. A switch to leave the
kiosk would be a switch somebody forgets to remove. Recovery is documented in
docs/architecture.md instead.

---

## 0002 — `chrome/app/chrome_main_delegate.cc`

The important one. `PreSandboxStartup()` runs before any subsystem reads the
command line, so this is the last place where dangerous flags can be removed
before they take effect.

When `--bootowser` is present:

```cpp
for (const char* flag : {
    "--remote-debugging-port", "--remote-debugging-pipe",
    "--remote-allow-origins", "--remote-debugging-socket-name",
    "--remote-debugging-io-pipes", "--disable-web-security",
    "--allow-file-access-from-files", "--load-extension",
    "--disable-extensions-except", "--renderer-cmdline", "--js-flags"}) {
  base::CommandLine::ForCurrentProcess()->RemoveSwitchASCII(flag);
}
```

Then it forces `--kiosk` on the start URL, drops `--app`/`--app-id` (which
would otherwise be an alternative way out of windowed mode) and
`--restore-last-session`, and appends `--no-first-run` and
`--hide-crash-restore-bubble`.

Note this runs *after* `switches::` handles registration but *before* any
`BrowserMainLoop` code, so no later component can see the removed switches.

---

## 0003 — `chrome/browser/chrome_content_browser_client_navigation_throttles.cc`

Adds `BootowserNavigationThrottle` and registers it in
`CreateAndAddChromeThrottlesForNavigation`:

```cpp
if (!url.is_valid()) { throttle->CancelAndBlock(); return; }
if (url.SchemeIsHTTPOrHTTPS()) return;                 // the web, allowed
if (url.SchemeIs("about") && url.path() == "blank") return;  // initial doc
throttle->CancelAndBlock();                            // everything else
```

This is the layer that cannot be switched off from inside the kiosk. The
managed policy `URLBlocklist` covers the same ground, but policy is operator
configuration that can be edited on a running device; this is in the binary.

Only main-frame navigations are filtered. Sub-frame loads are left alone: a
page may embed whatever it wants, but it can never navigate the kiosk out of
the web.

---

## Verifying without a checkout

```sh
tools/verify-patches.sh
```

Fetches the upstream files the series touches from `chromium.googlesource.com`
at the pinned tag, builds a throwaway git tree, replays the series with
`git am --3way`, and asserts:

- patch 1 registers `kBootowser`
- patch 2 installs the lockdown and strips the remote-debugging escape hatches
- patch 3 adds and registers the navigation throttle

Then it deletes the scratch tree. Set `KEEP_WORK_DIR=1` to inspect it when a
patch misbehaves.

This is deliberately cheap enough to run on every pull request, which is how
upstream churn gets noticed before it becomes a broken release.

## Adding a patch

1. Work in a real Chromium checkout at the pinned tag.
2. Make the change.
3. `git commit -am "..."`
4. `git format-patch -1 --stdout > browser/patches/000N-short-name.patch`
5. Append `000N-short-name.patch` to `browser/patches/series`
6. Add assertions to `tools/verify-patches.sh` so CI proves the patch is
   present and doing something.
7. `tools/verify-patches.sh`

Touch one file per patch. It costs nothing now and saves a great deal when
the file is renamed upstream.