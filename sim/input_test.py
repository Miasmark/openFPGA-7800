#!/usr/bin/env python3
"""Emit a 4 KiB 2600 image (binary, to stdout) that reads the controller
ports every frame the way paddle, driving and light-gun games do, and writes
what it saw to RIOT RAM, where tb_load's +inputtest watches the writes:

  $90-$93  paddles 0-3: visible lines (of 192) before INPT0-3 read charged,
           after the pots were dumped in vertical blank
  $94      light gun: visible lines before INPT4 went low (latched, so a
           short sensor pulse between reads still counts); 192 = no hit
  $95      SWCHA (driving controller gray code in bits 5:4 / 1:0; light-gun
           trigger on bit 4 / 0)
  $96      INPT4, $97 INPT5 (driving controller buttons)
  $98      frame counter (written last: the frame's results are complete)
"""
import sys

WSYNC = [0x85, 0x02]


def assemble(org, items):
    """Same tiny two-pass assembler as tone_test.py."""
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
            a = labels[it[1]]; out += [a & 0xFF, a >> 8]; pc += 2
        elif it[0] == "rel":
            off = labels[it[1]] - (pc + 1); assert -128 <= off < 128
            out.append(off & 0xFF); pc += 1
    return bytes(out), labels


def count_low(reg, var):
    # lda reg / bmi +2 / inc var: count the lines where bit 7 is still clear
    return [0xA5, reg, 0x30, 0x02, 0xE6, var]


org = 0xF000
items = [
    0x78, 0xD8, 0xA2, 0xFF, 0x9A,                  # SEI, CLD, LDX #$FF, TXS
    0xA9, 0x00, 0xA2, 0x7F,                        # clear RAM $80-$FF
    ("label", "clr"), 0x95, 0x80, 0xCA, 0x10, ("rel", "clr"),
    ("label", "frame"),
    0xA9, 0x82, 0x85, 0x01, 0x85, 0x00,            # VBLANK: blank, dump pots, latch off; VSYNC on
    *WSYNC, *WSYNC, *WSYNC,
    0xA9, 0x00, 0x85, 0x00,                        # VSYNC off
    0x85, 0x80, 0x85, 0x81, 0x85, 0x82, 0x85, 0x83, 0x85, 0x84,
    0xA2, 37, ("label", "vb"), *WSYNC, 0xCA, 0xD0, ("rel", "vb"),
    0xA9, 0x40, 0x85, 0x01,                        # VBLANK: show, pots charge, INPT4/5 latched
    0xA2, 192,
    ("label", "vis"), *WSYNC,
    *count_low(0x08, 0x80), *count_low(0x09, 0x81),
    *count_low(0x0A, 0x82), *count_low(0x0B, 0x83),
    0xA5, 0x0C, 0x10, 0x02, 0xE6, 0x84,            # INPT4 high (no light yet): count
    0xCA, 0xD0, ("rel", "vis"),
    0xA9, 0x82, 0x85, 0x01,                        # blank, dump
    0xA5, 0x80, 0x85, 0x90, 0xA5, 0x81, 0x85, 0x91,
    0xA5, 0x82, 0x85, 0x92, 0xA5, 0x83, 0x85, 0x93,
    0xA5, 0x84, 0x85, 0x94,
    0xAD, 0x80, 0x02, 0x85, 0x95,                  # SWCHA
    0xA9, 0x00, 0x85, 0x01,                        # latch off, so INPT4/5 read live
    0xA5, 0x0C, 0x85, 0x96, 0xA5, 0x0D, 0x85, 0x97,
    0xA9, 0x82, 0x85, 0x01,
    0xE6, 0x99, 0xA5, 0x99, 0x85, 0x98,            # frame count
    0xA2, 28, ("label", "os"), *WSYNC, 0xCA, 0xD0, ("rel", "os"),
    0x4C, ("abs", "frame"),
]
prog, labels = assemble(org, items)
img = bytearray([0xFF] * 0x1000)
img[0:len(prog)] = prog
for vec in (0xFFA, 0xFFC, 0xFFE):
    img[vec], img[vec + 1] = org & 0xFF, org >> 8
sys.stdout.buffer.write(bytes(img))
