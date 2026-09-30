# Building Chromium

This is the long part. A Chromium build is 30k+ files, ~40 GB of disk and
plenty of RAM. Bootowser cannot make that faster; it can only make it
reproducible.

## Requirements

| | minimum | comfortable |
| --- | --- | --- |
| disk | 60 GB free | 120 GB free |
| RAM | 16 GB | 32 GB |
| cores | 8 | 16+ |
| disk type | SSD strongly recommended | NVMe |

You also need the usual Chromium dependencies: `clang`, `ninja-build`,
`python3`, `pkg-config`, `libnss3`, `libatk1.0`, `libatspi2.0`,
`libcups2`, `libdrm`, `libgbm`, `libxkbcommon`, `libasound2`,
`libpango`, `libcairo`.

On Arch:

```sh
sudo pacman -S --needed git clang ninja-build pkgconf python make \
  libnss libatk1.0 libatspi2.0 libcups libdrm libgbm libxkbcommon \
  alsa-lib pango cairo glib
```

## Fetch

```sh
cd browser
./fetch.sh
```

`fetch.sh` installs `depot_tools` into `browser/depot_tools`, then runs
`gclient sync` against the tag pinned in `CHROMIUM_VERSION`
(`154.0.8037.92` at the time of writing). It sets the `checkout_*` gclient
variables to `false` so you do not pay for Android, iOS, Windows or macOS
sources you will never build — this alone saves roughly 30 GB.

## Patch

```sh
./apply-patches.sh          # apply
./apply-patches.sh --check  # verify only, apply nothing
```

`apply-patches.sh` refuses to apply the series to the wrong tag, and is
idempotent: run it twice and the second run is a no-op. `--force` rewinds a
previously patched tree.

To verify the series against upstream without a local checkout (a few
seconds, needs only network):

```sh
../tools/verify-patches.sh
```

This fetches the handful of upstream files the patches touch, replays the
series with `git am --3way`, and asserts that each patch actually did what it
claims. It is what CI runs.

## Build

```sh
./build.sh
```

`build.sh` runs `apply-patches.sh`, then:

```sh
gn gen out/Release --args-file gn/bootowser.args
ninja -C out/Release chrome
```

and finally checks the resulting binary actually contains the `--bootowser`
switch, because a silently unpatched Chromium that still starts is worse than
no build at all.

Pass extra GN arguments after `--`:

```sh
./build.sh -- --root=/tmp/chrome-root --lld
```

Note that `--root` is required if you are not building as the same user that
owns the checkout.

### Parallelism

`build.sh` defaults to half your cores, which is usually right for a
linker-heavy C++ build. Override with `NINJA_JOBS`:

```sh
NINJA_JOBS=32 ./build.sh
```

## Rolling Chromium forward

Bump `browser/CHROMIUM_VERSION`, then:

```sh
../tools/verify-patches.sh
```

It will tell you which patch broke. Each patch touches exactly one file and
carries full context, so fixing one is normally a matter of finding the new
home of the code it modifies — `chrome/browser/ui/web_ui/` is gone in recent
versions, `chrome_switches.cc` is gone, `startup_utils.cc` lives at
`ui/startup/` now — and regenerating the patch:

```sh
cd <your-chromium-checkout>
git fetch origin tag <new-version>
git checkout <new-version>
# make the change
git commit -am "..."
git format-patch -1
```

## Build arguments worth knowing

`gn/bootowser.args` is commented, but these are the ones you will reach for:

| argument | effect |
| --- | --- |
| `is_debug = false` | release, optimised |
| `is_component_build = false` | required for a shippable build |
| `dcheck_always_on = false` | remove debug-only checks |
| `blink_symbol_level = 0` | no Blink symbols, smaller binary |
| `enable_nacl = false` | NaCl is dead and huge |
| `safe_browsing_mode = 0` | default; see docs/security.md |
| `widevine_cdm = true` | keep DRM (streaming displays) |
| `proprietary_codecs = true` | H.264/AAC |
| `enable_hangout_services_extension = false` | strip more |
| `use_official_goma = false` | no Goma; set `use_remoteexec` if you have it |

If `gn gen` rejects an argument, that name no longer exists in this tag.
`gn args --list` is authoritative.