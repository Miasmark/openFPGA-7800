#!/usr/bin/env python3
"""Write a ROM image as a Quartus .mif and a $readmemh .hex beside it.

  bin2mem.py ar_stub.bin      writes ar_stub.mif and ar_stub.hex
"""
import os
import sys

src = sys.argv[1]
data = open(src, "rb").read()
base = os.path.splitext(src)[0]
with open(base + ".mif", "w") as f:
    f.write(f"WIDTH=8;\nDEPTH={len(data)};\n\nADDRESS_RADIX=HEX;\nDATA_RADIX=HEX;\n\nCONTENT BEGIN\n")
    for i, b in enumerate(data):
        f.write(f"\t{i:x}   :   {b:02x};\n")
    f.write("END;\n")
with open(base + ".hex", "w") as f:
    f.write("".join(f"{b:02x}\n" for b in data))
