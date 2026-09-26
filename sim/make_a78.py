#!/usr/bin/env python3
"""Wrap the 16 KiB 7800 tone program (tone_test.py) in an A78 header."""
import subprocess, sys
audf = sys.argv[1] if len(sys.argv) > 1 else "7"
here = __file__.rsplit("/", 1)[0] or "."
hexdata = subprocess.check_output([sys.executable, f"{here}/tone_test.py", audf], text=True)
rom = bytes(int(l, 16) for l in hexdata.split())
hdr = bytearray(128)
hdr[0] = 3                                   # header version
hdr[1:17] = b"ATARI7800".ljust(16, b"\0")
hdr[17:49] = b"Pocket load test".ljust(32, b"\0")
hdr[49:53] = len(rom).to_bytes(4, "big")     # ROM size
hdr[53:55] = (0).to_bytes(2, "big")          # cart type: plain 16K
hdr[55] = 1; hdr[56] = 1                     # joysticks
hdr[57] = 0                                  # NTSC
hdr[58] = 0                                  # no save device
hdr[100:128] = b"ACTUAL CART DATA STARTS HERE"
sys.stdout.buffer.write(bytes(hdr) + rom)
