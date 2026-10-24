#!/usr/bin/env python3
"""Build a game-free 7800 cartridge that reads POKEY, for run_sim.sh's POKEY
read section (tb_load.sv +pokeyrd).

  pokey_read_test.py OUT.a78 [--base 450|4000]

The image is an A78 header (cartridge type 0x0040: POKEY at $450, or
0x0001: POKEY at $4000) and a 16 KiB ROM at $C000-$FFFF. The program locks
the console in 7800 mode, takes POKEY out of init (SKCTL = 3; the adapter
already leaves it so) and then reads, storing each value in RAM:
  $2210-$2237  RANDOM ($A) 40 times, one read every 16 CPU cycles;
  $2240        IRQST ($E) with IRQEN = 0: bit 0 is 1;
  $2241        IRQST after timer 1 (AUDF1 = 0, 64 kHz clock, STIMER) has
               run out with IRQEN = 1: bit 0 is 0 (SEI keeps the CPU from
               taking the interrupt);
  $2242        IRQST once IRQEN = 0 again: bit 0 is 1.
Last it writes $A5 to $2200 and idles. A POKEY whose reads return the
precharged bus (2.2.2's read fix, READ_WHOLE_CYCLE, undone) gives $FF for
every one of them.
"""
import argparse

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--base", default="450", choices=("450", "4000"), help="where POKEY sits (hex)")
a = ap.parse_args()
P = int(a.base, 16)
cart_type = {0x450: 0x0040, 0x4000: 0x0001}[P]


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


def w(addr):
    return [addr & 0xFF, addr >> 8]


def sta(addr):
    return [0x8D, *w(addr)]


def lda(addr):
    return [0xAD, *w(addr)]


AUDF1, AUDC1, AUDCTL, STIMER, RANDOM, IRQEN, SKCTL = P + 0, P + 1, P + 8, P + 9, P + 0xA, P + 0xE, P + 0xF
IRQST = IRQEN
N = 40
org = 0xC000
prog, labels = assemble(org, [
    0x78, 0xD8,                          # SEI, CLD
    0xA9, 0x07, 0x85, 0x01,              # INPTCTRL: lock, MARIA on, BIOS out
    0xA2, 0xFF, 0x9A,                    # LDX #$FF, TXS
    0xA9, 0x00, *sta(0x2200),            # the done marker cleared
    0xA9, 0x03, *sta(SKCTL),             # SKCTL = 3: out of init
    0xA9, 0x00, *sta(AUDCTL),            # AUDCTL = 0: 64 kHz clock
    *sta(IRQEN),                         # IRQEN = 0
    0xA2, 0x00,                          # LDX #0
    ("label", "rnd"),
    *lda(RANDOM),                        # LDA RANDOM
    0x9D, *w(0x2210),                    # STA $2210,X
    0xE8, 0xE0, N, 0xD0, ("rel", "rnd"),  # INX, CPX #N, BNE
    *lda(IRQST), *sta(0x2240),           # IRQST, idle
    0xA9, 0x00, *sta(AUDF1), *sta(AUDC1),  # timer 1: AUDF1 = 0, silent
    0xA9, 0x01, *sta(IRQEN),             # IRQEN = 1: timer 1
    *sta(STIMER),                        # STIMER
    0xA2, 0x00,                          # about 1,280 cycles: timer 1 runs
    ("label", "wait"), 0xCA, 0xD0, ("rel", "wait"),   # out every 28
    *lda(IRQST), *sta(0x2241),           # IRQST, timer 1 fired
    0xA9, 0x00, *sta(IRQEN),             # IRQEN = 0 clears it
    *lda(IRQST), *sta(0x2242),           # IRQST, cleared
    0xA9, 0xA5, *sta(0x2200),            # done
    ("label", "idle"), 0x4C, ("abs", "idle"),
    ("label", "rti"), 0x40,
])
rom = bytearray([0xFF] * 0x4000)
rom[0:len(prog)] = prog
for vec, name in ((0x3FFA, "rti"), (0x3FFC, None), (0x3FFE, "rti")):
    v = labels[name] if name else org
    rom[vec], rom[vec + 1] = v & 0xFF, v >> 8
# $FFF8/$FFF9 as a 7800 cartridge has them: the BIOS (when one runs) takes
# the image for a 7800 one, starting at $C000
rom[0x3FF8], rom[0x3FF9] = 0xFF, 0xC7

hdr = bytearray(128)
hdr[0] = 3                                   # header version
hdr[1:17] = b"ATARI7800".ljust(16, b"\0")
hdr[17:49] = b"POKEY read test".ljust(32, b"\0")
hdr[49:53] = len(rom).to_bytes(4, "big")     # ROM size
hdr[53:55] = cart_type.to_bytes(2, "big")
hdr[55] = 1; hdr[56] = 1                     # joysticks
hdr[57] = 0                                  # NTSC
hdr[100:128] = b"ACTUAL CART DATA STARTS HERE"
open(a.out, "wb").write(bytes(hdr) + rom)
