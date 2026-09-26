#!/usr/bin/env python3
"""Wrap a 7800 ROM image in an A78 header.

  make_a78.py [audf]                       the tone_test.py program, 16K plain
  make_a78.py --bin rom.bin [--type 0x0001]  any image; type = A78 cart type
                                              (0x0001 = POKEY at $4000,
                                               0x0040 = POKEY at $450)
"""
import argparse, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("audf", nargs="?", default="7")
ap.add_argument("--bin")
ap.add_argument("--type", default="0")
a = ap.parse_args()
here = __file__.rsplit("/", 1)[0] or "."
if a.bin:
    rom = open(a.bin, "rb").read()
else:
    hexdata = subprocess.check_output([sys.executable, f"{here}/tone_test.py", a.audf], text=True)
    rom = bytes(int(l, 16) for l in hexdata.split())
hdr = bytearray(128)
hdr[0] = 3                                   # header version
hdr[1:17] = b"ATARI7800".ljust(16, b"\0")
hdr[17:49] = b"Pocket test".ljust(32, b"\0")
hdr[49:53] = len(rom).to_bytes(4, "big")     # ROM size
hdr[53:55] = int(a.type, 0).to_bytes(2, "big")
hdr[55] = 1; hdr[56] = 1                     # joysticks
hdr[57] = 0                                  # NTSC
hdr[58] = 0                                  # no save device
hdr[100:128] = b"ACTUAL CART DATA STARTS HERE"
sys.stdout.buffer.write(bytes(hdr) + rom)
