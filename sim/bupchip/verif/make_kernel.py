#!/usr/bin/env python3
"""Build the mixer harness's images (kernel/harness.S).

  make_kernel.py HARNESS.bin OUT.hex OUT.a78 [--fw bupchip.hex]

OUT.hex is the firmware ROM for $readmemh (4096 words) with word 0 patched
to "b 0x2000" and the harness binary at 0x2000. OUT.a78 is a game-free image
whose asset window (0x02000000) holds four 1 KiB banks of synthetic signed
8-bit samples, which the harness's voices play.
"""
import argparse
import math
import os
import random
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_synth_arsc import a78  # noqa: E402

HARNESS_AT = 0x2000
ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("harness")
ap.add_argument("out_hex")
ap.add_argument("out_a78")
ap.add_argument("--fw", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                             "../../../src/fpga/mister/rtl/bupchip.hex"))
a = ap.parse_args()

words = [int(line, 16) for line in open(a.fw) if line.strip()]
if len(words) > HARNESS_AT // 4:
    sys.exit(f"{a.fw}: {len(words)} words, past the harness at {HARNESS_AT:#x}")
words += [0] * (HARNESS_AT // 4 - len(words))
words[0] = 0xea000000 | ((HARNESS_AT - 8) >> 2)          # b 0x2000
h = open(a.harness, "rb").read()
h += bytes(-len(h) % 4)
words += [int.from_bytes(h[i:i + 4], "little") for i in range(0, len(h), 4)]
if len(words) > 4096:
    sys.exit("harness too large")
words += [0] * (4096 - len(words))
open(a.out_hex, "w").write("".join(f"{w:08x}\n" for w in words))

R = random.Random(7800)
banks = b""
for k in range(4):
    banks += bytes(int(round(48 * math.sin(2 * math.pi * i * (k + 1) / 100) +
                             24 * math.sin(2 * math.pi * i / (7 + 5 * k)) + R.randint(-6, 6))) & 0xff
                   for i in range(1024))
open(a.out_a78, "wb").write(a78(banks))
print(f"{a.out_hex}: harness {len(h)} bytes at {HARNESS_AT:#x}; {a.out_a78}: {len(banks)} sample bytes")
