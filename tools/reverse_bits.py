#!/usr/bin/env python3
"""Convert a Quartus .rbf into the bit-reversed .rbf_r the Pocket loads."""
import sys

if len(sys.argv) != 3:
    sys.exit("usage: reverse_bits.py <in.rbf> <out.rbf_r>")

table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
with open(sys.argv[1], "rb") as f:
    data = f.read()
with open(sys.argv[2], "wb") as f:
    f.write(data.translate(table))
