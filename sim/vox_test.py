#!/usr/bin/env python3
"""Emit an AtariVox test cartridge (4 KiB 2600 image) that speaks fixed
SpeakJet code strings, for the core's AtariVox work (docs/ATARIVOX.md).

Select steps through the phrases (each has its own background colour);
fire speaks the current one. Bytes go out one a frame, in vertical blank,
on port 2's UP pin through the RIOT's DDR (8N1, 62 CPU cycles a bit,
about 19,250 baud, as the AtariVox drivers do), and only while port 2's
DOWN pin (the SpeakJet's buffer-half-full line, low when full) is high.

  vox_test.py > vox_test.bin
  vox_test.py --list            the phrases and their codes

Our own code and phrases, MIT licence.
"""
import sys

PHRASES = [
    ("Hello world", 0x44, [183, 131, 145, 164, 1, 147, 151, 145, 176]),
    ("One to five", 0x84, [147, 134, 141, 4, 192, 162, 4, 190, 148, 128, 4,
                           186, 153, 4, 186, 157, 166]),
    ("Ready", 0xC4, [148, 131, 174, 128]),
    ("Pitch steps on AW", 0x24, [22, 60, 136, 22, 90, 136, 22, 120, 136, 22, 160, 136,
                                 22, 200, 136, 31]),
    ("Speed and bend", 0x64, [21, 60, 183, 131, 145, 164, 1, 21, 127, 183, 131, 145, 164, 1,
                              31, 23, 0, 183, 131, 145, 164, 1, 23, 15, 183, 131, 145, 164, 31]),
    ("All 72 allophones", 0xA4, sum(([c, 4] for c in range(128, 200)), [])),
    ("DTMF 0-9 * #", 0xE4, list(range(240, 252))),
    ("Effects", 0x14, sum(([c, 1] for c in list(range(200, 240)) + [252, 253, 254]), [])),
]

# RAM
SEL, PTRLO, PTRHI, FIREOLD, SELOLD, TMP = 0x80, 0x81, 0x82, 0x83, 0x84, 0x85
# TIA / RIOT
VSYNC, VBLANK, WSYNC, COLUBK, INPT4 = 0x00, 0x01, 0x02, 0x09, 0x0C
SWCHA, SWACNT, SWCHB, INTIM, TIM64T = 0x280, 0x281, 0x282, 0x284, 0x296


def assemble(org, items):
    """Two-pass assembler: ints, ("label", n), ("abs", n), ("lo", n),
    ("hi", n), ("rel", n)."""
    size = lambda it: 2 if isinstance(it, tuple) and it[0] == "abs" else 0 if isinstance(it, tuple) and it[0] == "label" else 1
    labels, pc = {}, org
    for it in items:
        if isinstance(it, tuple) and it[0] == "label":
            labels[it[1]] = pc
        pc += size(it)
    out, pc = [], org
    for it in items:
        if isinstance(it, int):
            out.append(it)
        elif it[0] == "abs":
            a = labels[it[1]]; out += [a & 0xFF, a >> 8]
        elif it[0] == "lo":
            out.append(labels[it[1]] & 0xFF)
        elif it[0] == "hi":
            out.append(labels[it[1]] >> 8)
        elif it[0] == "rel":
            off = labels[it[1]] - (pc + 1); assert -128 <= off < 128, it
            out.append(off & 0xFF)
        pc += size(it)
    return bytes(out), labels


def abs_(op, a):
    return [op, a & 0xFF, a >> 8]


def program():
    wsync = [0x85, WSYNC]
    p = [
        ("label", "reset"),
        0x78, 0xD8, 0xA2, 0x00, 0x8A,                  # SEI CLD LDX #0 TXA
        ("label", "clr"), 0x95, 0x00, 0xE8, 0xD0, ("rel", "clr"),   # clear TIA and RAM
        0xCA, 0x9A,                                    # X = $FF, TXS
        *abs_(0x8D, SWCHA),                            # SWCHA = 0: an output bit drives low
        *abs_(0x8D, SWACNT),                           # SWACNT = 0: the line released, high
        ("label", "frame"),
        0xA9, 0x02, 0x85, VBLANK, 0x85, VSYNC, *wsync, *wsync, *wsync,
        0xA9, 0x00, 0x85, VSYNC,
        0xA9, 43, *abs_(0x8D, TIM64T),                 # vertical blank, about 37 lines
        # Select: next phrase on the press (SWCHB bit 1 falls)
        *abs_(0xAD, SWCHB), 0x29, 0x02, 0xAA,          # LDA SWCHB, AND #2, TAX
        0xC5, SELOLD, 0xF0, ("rel", "nosel"),          # unchanged?
        0x86, SELOLD, 0xE0, 0x00, 0xD0, ("rel", "nosel"),   # STX SELOLD; released -> skip
        0xE6, SEL, 0xA5, SEL, 0xC9, len(PHRASES), 0x90, ("rel", "nosel"),
        0xA9, 0x00, 0x85, SEL,
        ("label", "nosel"),
        0xA6, SEL, *abs_(0xBD, 0), 0x85, COLUBK,       # placeholder patched below: LDA colours,X
        # Fire: start the phrase on the press (INPT4 bit 7 falls)
        0xA5, INPT4, 0x29, 0x80, 0xAA,
        0xC5, FIREOLD, 0xF0, ("rel", "nofire"),
        0x86, FIREOLD, 0xE0, 0x00, 0xD0, ("rel", "nofire"),
        0xA6, SEL, *abs_(0xBD, 0), 0x85, PTRLO,        # placeholders: LDA lo,X / LDA hi,X
        *abs_(0xBD, 0), 0x85, PTRHI,
        ("label", "nofire"),
        # one byte a frame while a phrase is going and the SpeakJet has room
        0xA5, PTRHI, 0xF0, ("rel", "wait"),            # nothing to send
        *abs_(0xAD, SWCHA), 0x29, 0x02, 0xF0, ("rel", "wait"),   # buffer half full: hold
        0xA0, 0x00, 0xB1, PTRLO, 0xC9, 0xFF, 0xD0, ("rel", "go"),
        0x84, PTRHI, 0xF0, ("rel", "wait"),            # $FF: end of phrase (Y = 0)
        ("label", "go"),
        0xE6, PTRLO, 0xD0, 0x02, 0xE6, PTRHI,
        0x49, 0xFF, 0x85, TMP,                         # inverted: a set DDR bit is a 0
        0x38, 0xA0, 10,                                # start bit, then 8 data, then stop
        ("label", "bit"),
        *abs_(0xAD, SWACNT), 0x29, 0xFE, 0x69, 0x00, *abs_(0x8D, SWACNT),   # 12
        0xA2, 0x07, ("label", "dly"), 0xCA, 0xD0, ("rel", "dly"),           # 36
        0xEA, 0xEA,                                                          # 4
        0x46, TMP, 0x88, 0xD0, ("rel", "bit"),                               # 10: 62 a bit
        ("label", "wait"),
        *abs_(0xAD, INTIM), 0xD0, ("rel", "wait"),
        0x85, WSYNC, 0x85, VBLANK,                     # A = 0: picture on
        0xA2, 192, ("label", "vis"), *wsync, 0xCA, 0xD0, ("rel", "vis"),
        0xA9, 0x02, 0x85, VBLANK,
        0xA2, 30, ("label", "os"), *wsync, 0xCA, 0xD0, ("rel", "os"),
        0x4C, ("abs", "frame"),
    ]
    return p


def build():
    org = 0xF000
    prog = program()
    code, labels = assemble(org, prog)
    # tables after the code: colours, phrase pointers, phrases
    tab = len(code)
    colours = bytes(c for _, c, _ in PHRASES)
    data, ptrs = b"", []
    base = org + tab + len(colours) + 2 * len(PHRASES)
    for _, _, codes in PHRASES:
        ptrs.append(base + len(data))
        data += bytes(codes) + b"\xFF"
    lo = bytes(p & 0xFF for p in ptrs)
    hi = bytes(p >> 8 for p in ptrs)
    img = bytearray(code + colours + lo + hi + data)
    # patch the three table loads (the LDA abs,X placeholders, in order)
    addrs = [org + tab, org + tab + len(colours), org + tab + len(colours) + len(PHRASES)]
    k = 0
    for i in range(len(code) - 2):
        if img[i] == 0xBD and img[i + 1] == 0 and img[i + 2] == 0 and k < 3:
            img[i + 1], img[i + 2] = addrs[k] & 0xFF, addrs[k] >> 8
            k += 1
    assert k == 3 and len(img) < 0xFFA
    img += bytes(0x1000 - len(img))
    for vec in (0xFFA, 0xFFC, 0xFFE):
        img[vec], img[vec + 1] = labels["reset"] & 0xFF, labels["reset"] >> 8
    return bytes(img)


if __name__ == "__main__":
    if "--list" in sys.argv:
        for i, (name, col, codes) in enumerate(PHRASES):
            print(f"{i + 1}. {name} (colour ${col:02X}): {' '.join(map(str, codes))}")
    else:
        sys.stdout.buffer.write(build())
