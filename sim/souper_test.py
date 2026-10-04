#!/usr/bin/env python3
"""Build a game-free Souper cartridge that sends one BupChip command, for the
whole-core BupChip test in run_sim.sh (tb_load.sv +bupfw).

  souper_test.py OUT.a78 --arsc BLOCK [--cmd 0x80] [--delay-ms 30]

The image is an A78 header (cartridge type 0x1000: the Souper mapper), a
512 KiB ROM and the ARSC block (BLOCK, e.g. make_synth_arsc.py --arsc), which
starts at 128 + the declared ROM size like a real Souper image (BUPCHIP.md).
The 512 KiB are needed because the Souper mapper fetches $C000-$FFFF from the
last 16 KiB bank. The program there locks the console in 7800 mode, waits
--delay-ms (the BupChip firmware boots in about 3 ms once the cartridge has
loaded), then writes the command to $8007 twice, as a game does (cart.sv
publishes the byte on the second write), and idles.
"""
import argparse

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--arsc", required=True, help="the ARSC block to append")
ap.add_argument("--cmd", default="0x80", help="the command byte ($80 | n plays song n)")
ap.add_argument("--delay-ms", type=float, default=30.0)
a = ap.parse_args()


def assemble(org, items):
    """Two-pass assembler as in tone_test.py: ints, ("label", name),
    ("abs", name) for a 16 bit address, ("rel", name) for a branch."""
    labels, pc = {}, org
    for it in items:
        if isinstance(it, tuple) and it[0] == "label":
            labels[it[1]] = pc
        else:
            pc += 2 if isinstance(it, tuple) and it[0] == "abs" else 1
    out, pc = [], org
    for it in items:
        if isinstance(it, int):
            out.append(it); pc += 1
        elif it[0] == "abs":
            v = labels[it[1]]; out += [v & 0xFF, v >> 8]; pc += 2
        elif it[0] == "rel":
            off = labels[it[1]] - (pc + 1); assert -128 <= off < 128
            out.append(off & 0xFF); pc += 1
    return bytes(out), labels


# The delay: 256 x (DEX, BNE) plus the outer loop is about 1,287 cycles per
# pass at 1.79 MHz.
passes = max(1, min(255, round(a.delay_ms * 1789.77 / 1287)))
cmd = int(a.cmd, 0) & 0xFF
org = 0xC000
prog, labels = assemble(org, [
    0x78, 0xD8,                          # SEI, CLD
    0xA9, 0x07, 0x85, 0x01,              # INPTCTRL: lock, MARIA on, BIOS out
    0xA0, passes,                        # LDY #passes
    ("label", "outer"), 0xA2, 0x00,      # LDX #0
    ("label", "inner"), 0xCA, 0xD0, ("rel", "inner"),   # DEX, BNE
    0x88, 0xD0, ("rel", "outer"),        # DEY, BNE
    0xA9, cmd,                           # LDA #cmd
    0x8D, 0x07, 0x80,                    # STA $8007
    0x8D, 0x07, 0x80,                    # STA $8007
    ("label", "idle"), 0x4C, ("abs", "idle"),
    ("label", "rti"), 0x40,
])
rom = bytearray([0xFF] * 0x80000)
last = 0x7C000                           # the fixed bank, $C000-$FFFF
rom[last:last + len(prog)] = prog
for vec, name in ((0x3FFA, "rti"), (0x3FFC, None), (0x3FFE, "rti")):
    v = labels[name] if name else org
    rom[last + vec], rom[last + vec + 1] = v & 0xFF, v >> 8

hdr = bytearray(128)
hdr[0] = 3                               # header version
hdr[1:17] = b"ATARI7800".ljust(16, b"\0")
hdr[17:49] = b"Pocket BupChip test".ljust(32, b"\0")
hdr[49:53] = len(rom).to_bytes(4, "big")  # ROM size: the block starts after it
hdr[53:55] = (0x1000).to_bytes(2, "big")  # cartridge type: bit 12, Souper
hdr[55] = 1; hdr[56] = 1                 # joysticks
hdr[57] = 0                              # NTSC
hdr[100:128] = b"ACTUAL CART DATA STARTS HERE"
block = open(a.arsc, "rb").read()
with open(a.out, "wb") as f:
    f.write(bytes(hdr) + bytes(rom) + block)
print(f"{a.out}: {128 + len(rom) + len(block)} bytes; command ${cmd:02X} after "
      f"{passes} delay passes (~{passes * 1287 / 1789.77:.1f} ms)")
