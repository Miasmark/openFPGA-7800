#!/usr/bin/env python3
"""Make FujiNet's 7800 CONFIG into an .a78 the Pocket core can run.

FujiNet's firmware tree carries a built CONFIG as a C array,
pico/atari-7800/firmware/baked/fujiconfigrom.h (32K at $8000, with the FUJI
claim at $FF70 asking for the 16K of RAM at $4000). This reads the bytes out
of that header (as data: nothing in it is run), wraps them in an A78 header
(sim/make_a78.py's) and, with --sign, signs the image for a console's BIOS
with the a7800-toolkit's sign7800.py (the claim at $FF70 sits below the
signature and survives it).

  mk_config_a78.py FUJINET_FIRMWARE_DIR OUT.a78 [--sign SIGN7800_PY]

CONFIG is FujiNet's (fujinet-config, atari7800/), under their license; this
repository does not carry it. On the Pocket core (2.2.7) it runs and boots
games; the INFO screen's INPTCTRL and High Score Cart lines show defaults.
See docs/FUJINET_SETUP.md and docs/FUJINET_TESTING.md.
SPDX-License-Identifier: MIT
"""
import argparse, os, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("firmware")
ap.add_argument("out")
ap.add_argument("--sign")
a = ap.parse_args()
hdr = os.path.join(a.firmware, "pico/atari-7800/firmware/baked/fujiconfigrom.h")
src = open(hdr).read()
body = src[src.index("{") + 1:src.index("};")]
rom = bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", body))
if len(rom) != 32768:
    sys.exit("expected 32768 bytes, got %d" % len(rom))
claim = rom[0x7F70:0x7F7A]
if claim[:4] != b"FUJI":
    sys.exit("no FUJI claim at $FF70")
print("CONFIG: 32K, claim version %d, kind %d, flags %d" % (claim[4], claim[5], claim[6]))
here = os.path.dirname(os.path.abspath(__file__))
binf = a.out + ".bin"
open(binf, "wb").write(rom)
with open(a.out, "wb") as f:
    f.write(subprocess.check_output([sys.executable, os.path.join(here, "..", "make_a78.py"), "--bin", binf]))
os.remove(binf)
if a.sign:
    subprocess.check_call([sys.executable, "-I", a.sign, "--write", a.out])
print(a.out)
