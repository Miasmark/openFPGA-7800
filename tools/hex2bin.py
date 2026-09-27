#!/usr/bin/env python3
"""Convert a MiSTer-style .hex ROM image (one hex byte per line) to binary.

    python3 tools/hex2bin.py mem4.hex > highscor.rom
"""
import sys

src = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
sys.stdout.buffer.write(bytes(int(tok, 16) for tok in src.read().split()))
