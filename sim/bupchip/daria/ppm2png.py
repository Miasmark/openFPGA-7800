#!/usr/bin/env python3
# Convert the P6 snapshots tb_daria.sv writes to PNG (standard library only:
# no PIL on the build machine). Usage: ppm2png.py FILE.ppm...
# SPDX-License-Identifier: MIT
import struct
import sys
import zlib


def ppm_to_png(path):
    data = open(path, "rb").read()
    parts = data.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    pix = parts[3]
    raw = b"".join(b"\x00" + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    open(path[:-4] + ".png", "wb").write(png)


for p in sys.argv[1:]:
    ppm_to_png(p)
