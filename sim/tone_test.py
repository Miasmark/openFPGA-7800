#!/usr/bin/env python3
"""Emit a 16 KiB cartridge image (hex, one byte per line) that starts a TIA
pure tone (AUDC0=4, AUDV0=15, AUDF0=<audf>) and then idles.

  tone_test.py <audf>          7800 program, image mapped at $C000-$FFFF
  tone_test.py <audf> 2600     2600 program: the same tone plus a standard
                               NTSC frame (3 VSYNC, 37 VBLANK, 192 visible,
                               30 overscan lines), repeated in every 4 KiB so
                               any bank the mapper starts in holds it.
"""
import sys

audf = int(sys.argv[1]) if len(sys.argv) > 1 else 0
mode2600 = len(sys.argv) > 2 and sys.argv[2] == "2600"
# tone_test.py <audf> 2600 pal: a PAL frame instead (3 VSYNC, 45 VBLANK,
# 228 visible, 36 overscan = 312 lines)
pal = len(sys.argv) > 3 and sys.argv[3] == "pal"
vb_lines, vis_lines, os_lines = (45, 228, 36) if pal else (37, 192, 30)


def assemble(org, items):
    """Tiny two-pass assembler: items are ints, ("label", name),
    ("abs", name) for a 16 bit address, or ("rel", name) for a branch."""
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


tone = [0xA9, 0x04, 0x85, 0x15,          # AUDC0 = 4
        0xA9, audf & 0x1F, 0x85, 0x17,   # AUDF0
        0xA9, 0x0F, 0x85, 0x19]          # AUDV0 = 15

if not mode2600:
    org = 0xC000
    prog, labels = assemble(org, [
        0x78, 0xD8,                      # SEI, CLD
        0xA9, 0x07, 0x85, 0x01,          # INPTCTRL: lock, MARIA on, BIOS out
        *tone,
        ("label", "idle"), 0x4C, ("abs", "idle"),
        ("label", "rti"), 0x40,
    ])
    img = bytearray([0xFF] * 0x4000)
    img[0:len(prog)] = prog
    for vec, name in ((0x3FFA, "rti"), (0x3FFC, None), (0x3FFE, "rti")):
        a = labels[name] if name else org
        img[vec], img[vec + 1] = a & 0xFF, a >> 8
else:
    org = 0xF000
    WSYNC = [0x85, 0x02]
    prog, labels = assemble(org, [
        0x78, 0xD8, 0xA2, 0xFF, 0x9A,    # SEI, CLD, LDX #$FF, TXS
        *tone,
        ("label", "frame"),
        0xA9, 0x02, 0x85, 0x01, 0x85, 0x00,        # VBLANK on, VSYNC on
        *WSYNC, *WSYNC, *WSYNC,
        0xA9, 0x00, 0x85, 0x00,                    # VSYNC off
        0xA2, vb_lines, ("label", "vb"), *WSYNC, 0xCA, 0xD0, ("rel", "vb"),
        0xA9, 0x00, 0x85, 0x01,                    # VBLANK off
        0xA2, vis_lines, ("label", "vis"), 0x86, 0x09, *WSYNC, 0xCA, 0xD0, ("rel", "vis"),
        0xA9, 0x02, 0x85, 0x01,                    # VBLANK on
        0xA2, os_lines, ("label", "os"), *WSYNC, 0xCA, 0xD0, ("rel", "os"),
        0x4C, ("abs", "frame"),
    ])
    bank = bytearray([0xFF] * 0x1000)
    bank[0:len(prog)] = prog
    for vec in (0xFFA, 0xFFC, 0xFFE):
        bank[vec], bank[vec + 1] = org & 0xFF, org >> 8
    img = bank * 4

sys.stdout.write("".join(f"{b:02x}\n" for b in img))
