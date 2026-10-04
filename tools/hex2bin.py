#!/usr/bin/env python3
"""Convert a MiSTer-style ROM image to binary.

    python3 tools/hex2bin.py mem4.hex > highscor.rom
    python3 tools/hex2bin.py bupchip.hex > bupchip.bin
    python3 tools/hex2bin.py bupchip.mif > bupchip.bin

A .hex image has one value per line. Two-digit values are bytes. Eight-digit
values are 32-bit words, written little-endian, which is how the BupChip's
ARM reads its firmware. A Quartus .mif image (WIDTH=8 or 32) is read the same
way; any depth past the last listed address is left out.
"""
import re, sys

text = (open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin).read()

if "CONTENT" in text and "BEGIN" in text:
    width = int(re.search(r"WIDTH\s*=\s*(\d+)", text).group(1))
    body = text.split("BEGIN", 1)[1].split("END", 1)[0]
    cells = {}
    for addr, data in re.findall(r"([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f]+)\s*;", body):
        cells[int(addr, 16)] = int(data, 16)
    values = [cells.get(a, 0) for a in range(max(cells) + 1)] if cells else []
else:
    tokens = text.split()
    width = 32 if tokens and len(tokens[0]) == 8 else 8
    values = [int(tok, 16) for tok in tokens]

if width == 8:
    out = bytes(values)
elif width == 32:
    out = b"".join(v.to_bytes(4, "little") for v in values)
else:
    sys.exit(f"unsupported width {width}")
sys.stdout.buffer.write(out)
