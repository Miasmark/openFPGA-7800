#!/usr/bin/env python3
"""Build a Souper .a78 with its BupChip resources (an ARSC block) appended,
the layout the MiSTer core's BupChip expects.

  make_arsc.py GAME_DIR OUT.a78 [--rom FILE] [--bps PATCH] [--list]

GAME_DIR is a ProSystem/FoxBox-style install: Data/FoxBox.cdf names the
cartridge image, the sample bank (.smp), the instrument macros (.ins) and the
songs (.mus) in command order. --rom overrides the image (default: the one the
.cdf names). An image without an A78 header needs one: --bps applies a header
patch (Jamie Blanks posted one for Rikki & Vikki on the MiSTer forum), or pass
an already headered .a78 with --rom.

The .smp, .ins and .mus files are already the firmware's CSMP, CINS and CMUS
chunks, so the block is only an index plus those files, each 4-byte aligned:

  +0   "ARSC"
  +4   u32 offset of the CSMP chunk      (offsets are from the "ARSC" tag)
  +8   u32 offset of the CINS chunk
  +12  u32 song offsets [32]             0 = no song; command $80|n plays song n
  ...  chunks

Read out of the firmware (rtl/bupchip.hex): main at 0x88 checks the tag, the
loader at 0x880 hands +4 to the CSMP parser (0x1b48) and +8 to the CINS
parser (0x130c), and the command loop indexes the table at +12 (0x230). See
docs/BUPCHIP.md. For Rikki & Vikki the block comes to 211.8 KiB, the
"212 KiB" upstream quotes.

The output contains the game's ROM and music: keep it out of the repository.
"""
import argparse, os, struct, sys, zlib


def bps_apply(src, patch):
    """Apply a BPS patch (byuu's format). Checksums are reported, not enforced:
    a header-only patch works on any dump of the same game."""
    def num(i):
        v, s = 0, 1
        while True:
            x = patch[i]; i += 1
            v += (x & 0x7f) * s
            if x & 0x80:
                return v, i
            s <<= 7; v += s
    if patch[:4] != b"BPS1":
        sys.exit("not a BPS patch")
    i = 4
    _, i = num(i)
    tsize, i = num(i)
    msize, i = num(i)
    i += msize
    out = bytearray(tsize); o = sr = tr = 0
    while i < len(patch) - 12:
        d, i = num(i)
        cmd, n = d & 3, (d >> 2) + 1
        if cmd == 0:
            out[o:o + n] = src[o:o + n]; o += n
        elif cmd == 1:
            out[o:o + n] = patch[i:i + n]; i += n; o += n
        else:
            r, i = num(i)
            r = -(r >> 1) if r & 1 else r >> 1
            if cmd == 2:
                sr += r; out[o:o + n] = src[sr:sr + n]; sr += n; o += n
            else:
                tr += r
                for _ in range(n):
                    out[o] = out[tr]; o += 1; tr += 1
    want_src = int.from_bytes(patch[-12:-8], "little")
    if zlib.crc32(src) != want_src:
        print(f"note: source CRC {zlib.crc32(src):08x}, patch made for {want_src:08x} (fine for a header-only patch)")
    return bytes(out)


ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("game_dir")
ap.add_argument("out")
ap.add_argument("--rom")
ap.add_argument("--bps")
ap.add_argument("--list", action="store_true", help="print the song numbers")
a = ap.parse_args()

data = os.path.join(a.game_dir, "Data")
lines = [l.strip() for l in open(os.path.join(data, "FoxBox.cdf"), encoding="latin-1").read().splitlines()]
if "CORETONE" not in lines:
    sys.exit("FoxBox.cdf has no CORETONE section: not a BupChip game")
k = lines.index("CORETONE")
res = lambda p: open(os.path.normpath(os.path.join(data, p.replace("\\", "/"))), "rb").read()
smp, ins = res(lines[k + 1]), res(lines[k + 2])
names = [l for l in lines[k + 3:] if l]
songs = [res(n) for n in names]
if smp[:4] != b"CSMP" or ins[:4] != b"CINS" or any(s[:4] != b"CMUS" for s in songs):
    sys.exit("unexpected chunk tags")
if len(songs) > 32:
    sys.exit(f"{len(songs)} songs; the command byte addresses 32")

rom = open(a.rom or os.path.join(data, lines[3]), "rb").read()
if a.bps:
    rom = bps_apply(rom, open(a.bps, "rb").read())
if rom[1:10] != b"ATARI7800":
    sys.exit("image has no A78 header: pass --bps or a headered --rom")
declared = int.from_bytes(rom[49:53], "big")
if len(rom) != 128 + declared:
    sys.exit(f"header declares {declared} bytes but the image has {len(rom) - 128}; "
             "the core starts the block at 128 + declared size")

HDR = 12 + 4 * 32
body = bytearray()
def place(chunk):
    off = HDR + len(body)
    body.extend(chunk + b"\0" * (-len(chunk) % 4))
    return off
o_smp, o_ins = place(smp), place(ins)
offs = [place(s) for s in songs] + [0] * (32 - len(songs))
arsc = b"ARSC" + struct.pack("<II", o_smp, o_ins) + struct.pack("<32I", *offs) + bytes(body)
open(a.out, "wb").write(rom + arsc)
print(f"{a.out}: {len(rom)} byte cartridge + {len(arsc)} byte ARSC ({len(arsc) / 1024:.1f} KiB), {len(songs)} songs")
if a.list:
    for n, (name, s) in enumerate(zip(names, songs)):
        print(f"  {n:2d}  ${0x80 | n:02X}  {name.split(chr(92))[-1]:24s} {len(s):6d} bytes")
