#!/usr/bin/env python3
"""Rasterizes UI font atlases into Tesselix records (type 0x0101 FontAtlas).

This is a stopgap until the text stack is chosen (Widget Framework, open
question: HarfBuzz + FreeType, or pure Zig). Atlases are pre-rendered alpha
masks at fixed physical pixel sizes, one record per file.

Usage:
    python3 tools/fontgen/gen_fonts.py REGULAR.otf SEMIBOLD.otf OUT_DIR

Needs Pillow and fontTools. The output is committed, so building Tesselix
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


def build(path: str, weight: int, px: int) -> bytes:
    cmap = TTFont(path).getBestCmap()
    cps = [c for c in list(range(32, 127)) + EXTRA if c in cmap]
    font = ImageFont.truetype(path, px)
    ascent, descent = font.getmetrics()
    line_height = round((ascent + descent) * 1.2)

    glyphs = []
    bitmap = bytearray()
    for cp in cps:
        ch = chr(cp)
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
    regular, semibold, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    for name, path, weight in (("regular", regular, 400), ("semibold", semibold, 600)):
        for px in SIZES:
            data = build(path, weight, px)
            (out / f"{name}-{px}.tslx").write_bytes(data)
            print(f"{name}-{px}.tslx {len(data)} bytes")


if __name__ == "__main__":
    main()
