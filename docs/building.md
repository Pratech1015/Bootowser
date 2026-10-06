# Building Firefox

**You probably do not need to.** `install.sh` uses your distribution's Firefox
by default, and that is a supported way to run Bootowser. Read the top of
[README.md](../README.md) first.

Build your own when you need a binary that only changes when you decide it
should: your distro's Firefox gets replaced by a package update, and a kiosk
whose behaviour changes on someone else's release schedule is not an appliance.

## Requirements

Mozilla's documented figures for a full Firefox build:

| | minimum | comfortable |
| --- | --- | --- |
| disk | 30 GB free | 60 GB free |
| RAM | 4 GB | 8 GB+ |
| cores | 4 | 8+ |

Those numbers are for a stock build. `mozconfig-bootowser` disables tests and
debug info, which cuts both disk and time noticeably, so 30 GB is a real
floor rather than an optimistic one.

Filesystem matters more than the numbers suggest. Firefox's build is tens of
thousands of files and it will fail in confusing ways on filesystems without
real POSIX semantics. `fetch.sh` refuses to start on NTFS, exFAT, FAT, NFS and
CIFS for exactly this reason.

On Arch:

```sh
sudo pacman -S --needed git clang lld llvm-devel cbindgen ccache \
  python make autoconf2.13 nasm pkgconf libx11 libxtst libxrandr \
  libxdamage libxcomposite libxfixes libxkbcommon gtk3 dbus-glib \
  alsa-lib libpulseaudio nss
```

`nasm`, `autoconf2.13` and `ccache` are the three that `./mach bootstrap` will
insist on if you skip them.

## Fetch

```sh
cd firefox
./fetch.sh --dest /mnt/fast/firefox-src
```

`fetch.sh` clones `mozilla-firefox/firefox` at a pinned release tag,
shallowly. (`mozilla/gecko-dev` is the same code but it is archived and
frozen, so it no longer carries release tags and pinning against it fails.)

The pin lives in `firefox/FIREFOX_VERSION`, which is the single source of
truth read by both `fetch.sh` and `apply-patches.sh`. That is deliberate: if
the fetcher and the patch series could disagree about the version, you would
find out at patch-apply time, after a multi-gigabyte download, instead of
immediately. The pin itself matters because an unpinned kiosk build breaks
when upstream moves a branch.

`--dest` must be absolute, and its filesystem is checked before anything is
downloaded, so you find out you picked the wrong drive in a second rather than
30 GB in.

## Patch

```sh
./firefox/apply-patches.sh --src-dir /mnt/fast/firefox-src --check
./firefox/apply-patches.sh --src-dir /mnt/fast/firefox-src
```

This is the step that makes Bootowser a kiosk rather than a Firefox with a
policy file. The patch series in `firefox/patches/` compiles the lockdown in:

| patch | what it does |
| --- | --- |
| `0001` | top-level navigation allowlist in `nsDocShell`, so the *page* cannot navigate the kiosk off the web |
| `0002` | removes the Ctrl+O, Ctrl+L and F12 escape hatches that `--kiosk` leaves behind |
| `0003` | renames the product to Bootowser: binary, window title, profile, vendor, UA |
| `0004` | removes the unused browser chrome: 28 dead key bindings and the F10 menu-bar handler compiled out, the rest hidden by CSS |
| `0005` | strips the crash reporter, updater and Normandy (remote experiments) so nothing can pop a GUI over the kiosk display; also stops `--version` printing the brand twice |

`--check` applies the series in a throwaway `git worktree` and throws it
away, so it never touches your tree and works whether or not you have already
applied the patches. CI runs it on every push.

`--force` resets back to the pinned tag and reapplies, which is how you pick up
an edit to the series without re-downloading Firefox.

The patches are applied with `git am`, so they land as ordinary commits in the
Firefox checkout. `git rebase -i` there to reorder, split or drop them.

## Configure

```sh
cp mozconfig-bootowser /mnt/fast/firefox-src/.mozconfig
```

`mozconfig-bootowser` does two separable things, and it is worth keeping them
apart:

1. It strips build-time features (`--disable-telemetry`, `--disable-updater`,
   `--disable-hubs`, ...). That is the easy half: reversible with a different
   configure line.
2. It passes `--enable-bootowser`, which defines `MOZ_BOOTOWSER` and turns on
   the patches above. That is the half that matters.

If you build with `--enable-bootowser` but *without* the patch series, you get
stock Firefox that happens to have a spare define. If you apply the patches
but drop `--enable-bootowser`, you get stock Firefox with dead code. Both are
wrong, and the second is silent, so do not go looking for the option to turn
the lockdown off at runtime: there is deliberately none.

One thing to know if you edit it: **`--disable-debug` is not in there and must
not be.** The `--disable-debug*` family produces unoptimised builds that are
enormously slow, which is exactly wrong for a display that repaints forever.
What is in there is `--enable-optimize --enable-o2`, which is the release
configuration.

It also sets `MOZ_OBJDIR` to `../obj-bootowser`, keeping build output outside
the source tree so a `--clean` or a re-clone does not fight with it.

## Build

```sh
cd /mnt/fast/firefox-src
./mach bootstrap
./mach build
```

`./mach bootstrap` installs the toolchain pieces you missed and exits. Run it
once, then `./mach build`.

The binary lands in `obj-bootowser/dist/bin/bootowser` (it is named `bootowser`,
not `firefox`, because the mozconfig passes `--with-app-name=bootowser`), and you
need the whole
directory, not just that file — `install.sh --browser` and the packagers copy
the tree because Firefox will not start without `omni.ja` and the shared
libraries beside it.

## Install your build

```sh
cd Bootowser
sudo ./tools/install.sh --browser /mnt/fast/firefox-src/obj-bootowser/dist/bin/bootowser
```

Pass the directory's `firefox` binary, not `libxul.so`. The installer checks
for that and tells you off if you get it wrong.

## Artifact builds

If you only need to change packaging, Rust, or JavaScript and not the C++
browser engine, Mozilla supports [artifact
builds](https://firefox-source-docs.mozilla.org/setup/linux_build.html): a
prebuilt Firefox is downloaded and only your changes are compiled.

```sh
./mach bootstrap --enable-artifact-builds
./mach build
```

This takes minutes and a few GB instead of hours and tens of GB. It is the
supported path for exactly the case "I want to ship my own build" and it is
what you should reach for before the full build.

## Rolling Firefox forward

Bump `DEFAULT_VERSION` in `fetch.sh`, then:

```sh
./fetch.sh --dest /mnt/fast/firefox-src
```

Bump `firefox/FIREFOX_VERSION`, then update the `FIREFOX_VERSION` env in the
`patches` job in `.github/workflows/ci.yml` to match — CI fails loudly if they
disagree, rather than failing to apply.

Then:

```sh
./firefox/fetch.sh --dest /mnt/fast/firefox-src
./firefox/apply-patches.sh --src-dir /mnt/fast/firefox-src --check
```

Expect work here. Both patches touch files Mozilla reorders often:
`nsDocShell.cpp` (9000+ lines, heavily refactored), `browser.js`, and
`StaticPrefList.yaml`, which is regenerated periodically and is where Firefox
broke most third-party builds between releases. A `3way` apply usually saves
it; a rejected hunk is usually a moved function, and the fix is to re-anchor
the context rather than to re-read the whole file.

The upside is that the series is small (two commits, ~300 lines) and both
patches fail *closed*: if the allowlist stops compiling you notice, and if the
series fails to apply CI stops before anything is built.

## Troubleshooting

| symptom | cause |
| --- | --- |
| `./mach` refuses to run | `./mach bootstrap` has not completed |
| build dies on a missing header | a `-devel` package; re-run `./mach bootstrap` |
| link errors about `rust` | `cbindgen` missing |
| `configure: error` about a syntax | `autoconf2.13` missing |
| assembly errors | `nasm` missing |
| disk full partway through | objdir is on a small filesystem; check `df` on `--dest` |
| `series references missing patch` | `patches/series` and the files in `patches/` disagree |
| `firefox-src is at X but the patch series targets Y` | `FIREFOX_VERSION` changed without replaying the series |
| error naming a pref and saying it is out of order | a pref was added to `StaticPrefList.yaml` out of alphabetical order |
| build is extremely slow | you are on a debug config, or on spinning/networked disk |