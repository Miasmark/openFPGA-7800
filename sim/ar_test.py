#!/usr/bin/env python3
"""Emit a Supercharger tape image (.bin, 8,448 bytes per load) for testing
the core's Supercharger loading, with or without the real BIOS.

Each load is one 256-byte page of code at $F100 (RAM bank 2, page 1), run
with control byte $10, bank configuration 4 (bank 2 at $F000, the BIOS ROM
at $F800, as configuration 0; non-zero so the check below means something).
The BIOS leaves the control byte in $80, and released games read it there;
a load that finds anything else in $80 shows a white screen instead. It
sets a background colour and a TIA tone, and draws NTSC frames.

  ar_test.py multi > ar_multi.bin
      Load 0 (red, AUDF0 7) runs 60 frames, then asks the BIOS for load 1
      the way multiload games do ($FA = 1, control byte $12, JMP $F800).
      Load 1 (green, AUDF0 14) runs for ever.
  ar_test.py tape > ar_tape.bin
      Two loads both numbered 0 (blue, AUDF0 3; then yellow, AUDF0 20), both
      running for ever, as on Party Mix's tape. After the first has loaded,
      a reset should load the second: the tape stays where it stopped.
  ar_test.py full > ar_full.bin
      One load of all 24 pages (pseudo-random bytes, the code in page 1 of
      bank 2; magenta, AUDF0 5), for checking every RAM byte after a load
      (tb_load +ardump=FILE, then ar_test.py check FILE ar_full.bin).

The TIA tone is there for the simulation (tb_load +arprobe logs the
COLUBK and AUDF0 writes); the colour is for a screen.
"""
import sys

COLUBK, AUDC0, AUDF0, AUDV0, WSYNC, VSYNC, VBLANK = 0x09, 0x15, 0x17, 0x19, 0x02, 0x00, 0x01
ORG = 0xF100
PAGE_MAP = (1 << 2) | 2      # page 1 of RAM bank 2: $F100 in bank configuration 4
CONTROL = 0x10               # bank configuration 4, writes off, ROM on


def assemble(org, items):
    """Two-pass assembler: ints, ("label", n), ("abs", n), ("rel", n)."""
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
    return bytes(out)


def program(colour, audf, next_load=None):
    """Colour and tone, then frames: for ever, or 60 of them and then a
    request for load next_load."""
    sta_wsync = [0x85, WSYNC]
    items = [
        0x78, 0xD8, 0xA2, 0xFF, 0x9A,                  # SEI, CLD, LDX #$FF, TXS
        0xA9, 0x04, 0x85, AUDC0,
        0xA9, audf, 0x85, AUDF0,
        0xA9, 0x0F, 0x85, AUDV0,
        0xA9, colour,
        0xA6, 0x80, 0xE0, CONTROL, 0xF0, 0x02,         # LDX $80, CPX #CONTROL, BEQ +2
        0xA9, 0x0E,                                    # LDA #$0E: white, $80 is wrong
        0x85, COLUBK,
        0xA0, 60,                                      # LDY #60 (frames before a multiload)
        ("label", "frame"),
        0xA9, 0x02, 0x85, VBLANK, 0x85, VSYNC,
        *sta_wsync, *sta_wsync, *sta_wsync,
        0xA9, 0x00, 0x85, VSYNC,
        0xA2, 37, ("label", "vb"), *sta_wsync, 0xCA, 0xD0, ("rel", "vb"),
        0xA9, 0x00, 0x85, VBLANK,
        0xA2, 192, ("label", "vis"), *sta_wsync, 0xCA, 0xD0, ("rel", "vis"),
        0xA9, 0x02, 0x85, VBLANK,
        0xA2, 30, ("label", "os"), *sta_wsync, 0xCA, 0xD0, ("rel", "os"),
    ]
    if next_load is None:
        items += [0x4C, ("abs", "frame")]
    else:
        items += [
            0x88, 0xD0, ("rel", "far"),                # DEY, BNE (via a JMP: the frame loop is long)
            0xA9, 0x00, 0x85, AUDV0,                   # silence
            0xA9, next_load, 0x85, 0xFA,               # load number for the BIOS
            0xAD, 0x12, 0xF0,                          # LDA $F012: control byte $12 ...
            0xAD, 0xF8, 0xFF,                          # LDA $FFF8: ... set (BIOS ROM at $F800, writes on)
            0x4C, 0x00, 0xF8,                          # JMP $F800: the BIOS's multiload entry
            ("label", "far"), 0x4C, ("abs", "frame"),
        ]
    code = assemble(ORG, items)
    assert len(code) <= 256
    return code


# Page map order of released full loads: bank 0, then 1, then 2.
FULL_MAP = [(p << 2) | b for b in range(3) for p in range(8)]


def load_image(load_number, code, full=False):
    page = bytearray(code) + bytearray(256 - len(code))
    pages = bytearray(8192)
    if full:
        import random
        rnd = random.Random(2600)
        maps = FULL_MAP
        for j, m in enumerate(maps):
            pages[j * 256:(j + 1) * 256] = page if m == PAGE_MAP else bytes(rnd.randrange(256) for _ in range(256))
    else:
        maps = [PAGE_MAP]
        pages[0:256] = page
    h = bytearray(256)
    h[0], h[1] = ORG & 0xFF, ORG >> 8                  # start address
    h[2] = CONTROL                                     # control byte
    h[3] = len(maps)                                   # page count
    h[5] = load_number
    h[6], h[7] = 0x24, 0x02                            # as in released images
    h[4] = (0x55 - sum(h[0:8])) & 0xFF                 # header checksum: bytes 0-7 sum to $55
    for j, m in enumerate(maps):                       # page map, and checksums: page + map + this = $55
        h[16 + j] = m
        h[64 + j] = (0x55 - sum(pages[j * 256:(j + 1) * 256]) - m) & 0xFF
    return bytes(pages + h)


def check(dump_path, image_path):
    """Compare a 6 KiB RAM dump (bank 0, 1, 2) with the image's first load."""
    ram, img = open(dump_path, "rb").read(), open(image_path, "rb").read()
    h = img[8192:8448]
    bad = 0
    for j in range(h[3]):
        m = h[16 + j]
        at = (m & 3) * 2048 + ((m >> 2) & 7) * 256
        bad += sum(a != b for a, b in zip(ram[at:at + 256], img[j * 256:(j + 1) * 256]))
    print(f"ARCHECK {h[3]} pages, {bad} of {h[3] * 256} RAM bytes differ from the image")


mode = sys.argv[1] if len(sys.argv) > 1 else "multi"
if mode == "multi":
    img = load_image(0, program(0x44, 7, next_load=1)) + load_image(1, program(0xC4, 14))
elif mode == "full":
    img = load_image(0, program(0x54, 5), full=True)
elif mode == "check":
    check(sys.argv[2], sys.argv[3]); sys.exit()
elif mode == "tape":
    img = load_image(0, program(0x84, 3)) + load_image(0, program(0x1E, 20))
else:
    sys.exit("usage: ar_test.py multi|tape|full > image.bin, or check DUMP IMAGE")
sys.stdout.buffer.write(img)
