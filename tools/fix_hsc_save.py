#!/usr/bin/env python3
"""Repair high score cart saves written by versions 2.0.2 and 2.0.3.

Those versions answered the Pocket's save reads one word early, so each .sav
came out rotated by four bytes: the HSC signature that belongs at $1002
($68 $83 $AA $55 $9C) sits at the start and end of the file instead, and the
HSC firmware asks to be personalised again. This rotates the file back.

  fix_hsc_save.py FILE.sav [...]     fixes in place (keeps FILE.sav.bak)

Files that already have the signature in the right place are left alone.
"""
import shutil
import sys

SIG = bytes([0x68, 0x83, 0xAA, 0x55, 0x9C])

for path in sys.argv[1:]:
    data = open(path, "rb").read()
    if len(data) != 2048:
        print(f"{path}: not a 2 KiB HSC save, skipped")
    elif data[2:7] == SIG:
        print(f"{path}: already correct")
    elif (data[-4:] + data[:-4])[2:7] == SIG:
        shutil.copyfile(path, path + ".bak")
        open(path, "wb").write(data[-4:] + data[:-4])
        print(f"{path}: fixed (original kept as .bak)")
    else:
        print(f"{path}: no HSC signature found, left alone")
