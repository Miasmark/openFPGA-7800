#!/usr/bin/env python3
"""Turn a flat binary into a ROM image for $readmemh.

  bin2hex.py IN.bin OUT.hex [WORDS]

Little-endian 32-bit words, one per line, the format of rtl/bupchip.hex,
padded with zeros to WORDS (default 4096, the BupChip ROM).
"""
import struct
import sys

d = open(sys.argv[1], "rb").read()
d += b"\0" * (-len(d) % 4)
words = [struct.unpack_from("<I", d, i)[0] for i in range(0, len(d), 4)]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 4096
if len(words) > n:
    sys.exit(f"{sys.argv[1]}: {len(words)} words, more than {n}")
words += [0] * (n - len(words))
open(sys.argv[2], "w").write("".join(f"{w:08x}\n" for w in words))
