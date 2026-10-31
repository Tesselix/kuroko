#!/usr/bin/env python3
"""Rasterizes UI font atlases into Kuroko records (type 0x0101 FontAtlas).

This is a stopgap until the text stack is chosen (Widget Framework, open
question: HarfBuzz + FreeType, or pure Zig). Atlases are pre-rendered alpha
masks at fixed physical pixel sizes, one record per file.

Usage:
    python3 sdk/tools/fontgen/gen_fonts.py REGULAR.otf SEMIBOLD.otf OUT_DIR
    python3 sdk/tools/fontgen/gen_fonts.py --hebrew REGULAR.ttf SEMIBOLD.ttf OUT_DIR

The first renders the UI font (Inter). The second renders the Hebrew
fallback atlases (Noto Sans Hebrew), used for what the UI font lacks.

Needs Pillow and fontTools. The output is committed, so building Kuroko
does not need Python.
"""
import struct
import sys
from pathlib import Path

from fontTools.ttLib import TTFont
from PIL import ImageFont

MAGIC = 0xFFFFFFFB
TYPE_FONT_ATLAS = 0x0101
VERSION = 1

# Physical pixel sizes: logical 11, 13, 15, 20 at scale 1 and 2.
SIZES = [11, 13, 15, 20, 22, 26, 30, 40]

EXTRA = [
    0x00B7, 0x00BB, 0x00D7, 0x2013, 0x2014, 0x2022, 0x2026, 0x2190,
    0x2191, 0x2192, 0x2193, 0x2212, 0x2318, 0x2713, 0x25B8,
]


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def record(type_id: int, version: int, payload: bytes) -> bytes:
    head = struct.pack("<IHHII", MAGIC, type_id, version, len(payload), crc32c(payload))
    pad = (-len(payload)) % 8
    return head + payload + b"\0" * pad


# Hebrew letters and punctuation, and the shekel sign.
HEBREW = [0x05BE, 0x05C0, 0x05C3, 0x05C6] + list(range(0x05D0, 0x05EB)) + \
    list(range(0x05EF, 0x05F5)) + [0x20AA]
# Points and cantillation marks: placing them over their letter needs
# shaping, which the atlases do not have yet. They are kept as empty,
# zero-width glyphs so they vanish instead of showing as '?'.
HEBREW_MARKS = [c for c in range(0x0591, 0x05C8) if c not in HEBREW]


def build(path: str, weight: int, px: int, ui: bool = True) -> bytes:
    cmap = TTFont(path).getBestCmap()
    wanted = list(range(32, 127)) + EXTRA if ui else HEBREW + HEBREW_MARKS
    cps = sorted(c for c in wanted if c in cmap)
    font = ImageFont.truetype(path, px)
    ascent, descent = font.getmetrics()
    line_height = round((ascent + descent) * 1.2)

    glyphs = []
    bitmap = bytearray()
    for cp in cps:
        ch = chr(cp)
        if cp in HEBREW_MARKS:
            glyphs.append(struct.pack("<IHBBbbHI", cp, 0, 0, 0, 0, 0, 0, len(bitmap)))
            continue
        advance = round(font.getlength(ch) * 64)
        mask, (ox, oy) = font.getmask2(ch, mode="L")
        w, h = mask.size
        if w == 0 or h == 0:
            w = h = 0
            data = b""
        else:
            data = bytes(mask)
        glyphs.append(struct.pack(
            "<IHBBbbHI", cp, advance, w, h, ox, ascent - oy, 0, len(bitmap)))
        bitmap += data

    head = struct.pack("<HHhhHHI", px, len(glyphs), ascent, -descent, line_height, weight, 0)
    return record(TYPE_FONT_ATLAS, VERSION, head + b"".join(glyphs) + bytes(bitmap))


def main() -> None:
    args = sys.argv[1:]
    ui = args[0] != "--hebrew"
    if not ui:
        args = args[1:]
    regular, semibold, out = args[0], args[1], Path(args[2])
    prefix = "" if ui else "hebrew-"
    out.mkdir(parents=True, exist_ok=True)
    for name, path, weight in ((prefix + "regular", regular, 400), (prefix + "semibold", semibold, 600)):
        for px in SIZES:
            data = build(path, weight, px, ui)
            (out / f"{name}-{px}.krkde").write_bytes(data)
            print(f"{name}-{px}.krkde {len(data)} bytes")


if __name__ == "__main__":
    main()
