#!/usr/bin/env python3
"""Generate the PNG assets for the Bootowser Plymouth theme.

The theme is deliberately asset-light: instead of shipping opaque binaries
nobody can review, every image is drawn from code in this file. Re-run it to
regenerate:

    tools/gen-plymouth-assets.py

Only Image.Text, Image() and Image.Scale() are used by the theme, which are
the documented, stable parts of Plymouth's scripting API.

No third-party dependencies: PNGs are assembled with zlib + struct.
"""

from __future__ import annotations

import math
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
THEME_DIR = os.path.normpath(os.path.join(HERE, os.pardir, "plymouth", "theme.bootowser"))

# 4x supersampling. Plymouth scales the logo to fit whatever resolution the
# framebuffer has, so the source has to survive being blown up.
SS = 4

# Brand palette, kept in sync with plymouth/theme.bootowser/bootowser.plymouth.
ACCENT = (0.16, 0.86, 0.62)
ACCENT_DIM = (0.10, 0.55, 0.42)
FG = (0.93, 0.95, 0.97)


class Canvas:
    """A tiny RGBA canvas that composites solid shapes with anti-aliasing."""

    def __init__(self, width: int, height: int, scale: int = SS) -> None:
        self.w = width * scale
        self.h = height * scale
        self.out_w = width
        self.out_h = height
        self.scale = scale
        # Float RGBA accumulation, premultiplied over a transparent canvas.
        self.px = bytearray(self.w * self.h * 4)

    # -- shape tests, in supersampled coordinates ----------------------------
    def rounded_rect(self, x, y, w, h, radius, color, alpha=1.0) -> None:
        x, y, w, h, radius = (v * self.scale for v in (x, y, w, h, radius))
        r = radius * self.scale
        for py in range(int(y), int(math.ceil(y + h))):
            for px in range(int(x), int(math.ceil(x + w))):
                if _in_rounded_rect(px + 0.5, py + 0.5, x, y, w, h, r):
                    self._blend(px, py, color, alpha)

    def circle(self, cx, cy, r, color, alpha=1.0) -> None:
        cx, cy, r = cx * self.scale, cy * self.scale, r * self.scale
        for py in range(int(cy - r) - 1, int(cy + r) + 2):
            for px in range(int(cx - r) - 1, int(cx + r) + 2):
                dx, dy = px + 0.5 - cx, py + 0.5 - cy
                if dx * dx + dy * dy <= r * r:
                    self._blend(px, py, color, alpha)

    def _blend(self, px: int, py: int, color, alpha: float) -> None:
        if not (0 <= px < self.w and 0 <= py < self.h):
            return
        i = (py * self.w + px) * 4
        # Source-over compositing on premultiplied values.
        src_a = alpha
        dst_a = self.px[i + 3] / 255.0
        out_a = src_a + dst_a * (1 - src_a)
        if out_a <= 0:
            return
        for c in range(3):
            src_c = color[c] * src_a
            dst_c = (self.px[i + c] / 255.0) * dst_a
            self.px[i + c] = int(round(((src_c + dst_c * (1 - src_a)) / out_a) * 255))
        self.px[i + 3] = int(round(out_a * 255))

    def clear(self, x, y, w, h, radius=0) -> None:
        """Erase a rounded region back to transparent.

        Needed to hollow out shapes: blending with alpha 0 is a no-op, so you
        cannot subtract by drawing. This punches through to transparent, which
        is what we want for a window outline.
        """
        x, y, w, h, radius = (v * self.scale for v in (x, y, w, h, radius))
        r = radius * self.scale
        for py in range(int(y), int(math.ceil(y + h))):
            for px in range(int(x), int(math.ceil(x + w))):
                if _in_rounded_rect(px + 0.5, py + 0.5, x, y, w, h, r):
                    i = (py * self.w + px) * 4
                    self.px[i] = self.px[i + 1] = self.px[i + 2] = self.px[i + 3] = 0

    # -- output -------------------------------------------------------------
    def resolve(self) -> bytearray:
        """Box-downsample the supersampled buffer to final RGBA8."""
        s = self.scale
        out = bytearray(self.out_w * self.out_h * 4)
        for y in range(self.out_h):
            for x in range(self.out_w):
                r = g = b = a = 0
                for sy in range(s):
                    row = (y * s + sy) * self.w
                    for sx in range(s):
                        i = (row + x * s + sx) * 4
                        r += self.px[i]
                        g += self.px[i + 1]
                        b += self.px[i + 2]
                        a += self.px[i + 3]
                n = s * s
                o = (y * self.out_w + x) * 4
                out[o] = min(255, r // n)
                out[o + 1] = min(255, g // n)
                out[o + 2] = min(255, b // n)
                out[o + 3] = min(255, a // n)
        return out


def _in_rounded_rect(px, py, x, y, w, h, r):
    if px < x or py < y or px > x + w or py > y + h:
        return False
    for cx, cy in ((x + r, y + r), (x + w - r, y + r), (x + r, y + h - r), (x + w - r, y + h - r)):
        if (px < x + r or px > x + w - r) and (py < y + r or py > y + h - r):
            if abs(px - cx) <= r and abs(py - cy) <= r:
                if (px - cx) ** 2 + (py - cy) ** 2 > r * r:
                    return False
    return True


def write_png(path: str, width: int, height: int, rgba: bytes) -> None:
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(typ: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + typ
            + data
            + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


# --- The assets ------------------------------------------------------------
def gen_logo() -> None:
    """A browser window mark: rounded frame, address-bar pill, three dots.

    Reads as "a web browser" at 64px and still resolves as a clean geometric
    shape when Plymouth scales it up to a 4K boot splash.
    """
    size = 256
    c = Canvas(size, size)

    outer, inset, radius = 14, 22, 24

    # Window frame: a filled rounded rect with the middle punched out.
    c.rounded_rect(outer, outer, size - 2 * outer, size - 2 * outer, radius, ACCENT)
    c.clear(inset, inset, size - 2 * inset, size - 2 * inset, radius - 8)

    # Address-bar pill, inset inside the hollow so it never touches the frame.
    c.rounded_rect(56, 62, size - 112, 38, 19, ACCENT_DIM)

    # The three classic window dots, centred under the pill.
    dot_y = 148
    for i, col in enumerate((ACCENT, ACCENT_DIM, ACCENT)):
        c.circle(size / 2 + (i - 1) * 44, dot_y, 15, col)

    # A short accent underline suggesting a loading line.
    c.rounded_rect(size / 2 - 40, 190, 80, 9, 4.5, ACCENT)

    write_png(os.path.join(THEME_DIR, "bootowser-logo.png"), size, size, bytes(c.resolve()))


def gen_bar() -> None:
    """Progress bar track and fill.

    Both are 1px wide on purpose: the theme scales them with Image.Scale() to
    whatever width the current progress needs, so a solid run of colour stays
    crisp instead of being resampled from a large bitmap.
    """
    for name, color in (("bar-track.png", (0.16, 0.18, 0.21)), ("bar-fill.png", ACCENT)):
        c = Canvas(1, 8)
        c.rounded_rect(0, 0, 1, 8, 0, color)
        write_png(os.path.join(THEME_DIR, name), 1, 8, bytes(c.resolve()))


def gen_dot() -> None:
    """The status dot that fills in once the browser is ready."""
    for name, color in (("dot.png", ACCENT), ("dot-dim.png", (0.20, 0.22, 0.25))):
        c = Canvas(32, 32)
        c.circle(16, 16, 15, color)
        write_png(os.path.join(THEME_DIR, name), 32, 32, bytes(c.resolve()))


def main() -> int:
    if not os.path.isdir(THEME_DIR):
        print(f"theme directory does not exist: {THEME_DIR}", file=sys.stderr)
        return 1
    gen_logo()
    gen_bar()
    gen_dot()
    for name in sorted(os.listdir(THEME_DIR)):
        if name.endswith(".png"):
            path = os.path.join(THEME_DIR, name)
            print(f"  {name:24s} {os.path.getsize(path):7d} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())