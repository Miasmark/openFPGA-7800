#!/usr/bin/env python3
"""Synthetic FA2 test cartridge and flash files for tb_load's +fa2prog (no game data).

  fa2_test.py image          24 KiB FA2 image (6 banks of 4 KiB) on stdout
  fa2_test.py flash SEED     256 pseudo-random bytes (random.Random(SEED))
  fa2_test.py expect [SEED]  what the program leaves in the flash, starting
                             from that file, or from a blank flash ($FF)
  fa2_test.py a78            32 KiB A78 (128-byte header) that detect2600.sv
                             takes for FA2, and that issues a save command

A 24 KiB 2600 image is detected as FA2 (detect2600.sv). mapper_fa2.sv puts
its 256-byte work RAM at $1000-$10FF (write) and $1100-$11FF (read), and
takes a flash command from work RAM byte $FF when $1FF4 is read: 1 loads the
flash into the work RAM, 2 saves the work RAM to it. $1FF4 reads with bit 6
set while the command runs and clear once it is done. The program, the same
in every bank, at $1200:

  1. load the flash (command 1) and wait;
  2. write bytes 0-254 back inverted;
  3. save (command 2) and wait: the flash then holds the inverted bytes,
     and byte 255 holds the command, 2;
  4. fill bytes 0-254 with $5A, load the flash again and wait: the work RAM
     must then hold the saved bytes again;
  5. store $A5 at $80 (RIOT RAM byte 0), the bench's signal, and loop.

The a78 image is a 7800 game that must leave the shared fa2.sav alone.
detect2600.sv classifies every image, A78s too: an A78 whose 32 KiB payload
has a zero tail (file offsets 29696-32767, header included) is BANKFA2, and
cart2600.sv then runs mapper_fa2.sv, which in 7800 mode still sees the bus
as {AB[12], AB[11:0]}. The program, at $8000 (the payload's start), stores
2 at $10FF (work RAM byte $FF: the save command) and reads $1FF4 (the flash
hotspot), then loops. Without a gate on 7800 mode that save writes the
mapper's work RAM (all $00 here) over the file.

SPDX-License-Identifier: MIT
"""
import random
import sys

ORG = 0x1200


def program():
    code, fix, lab = bytearray(), [], {}

    def op(*b):
        code.extend(b)

    def label(n):
        lab[n] = ORG + len(code)

    def bvs(n):                       # BVS back to label n
        op(0x70, 0)
        fix.append((len(code) - 1, n))

    def bne(n):
        op(0xD0, 0)
        fix.append((len(code) - 1, n))

    def command(k, n):                # LDA #k; STA $10FF; n: BIT $1FF4; BVS n
        op(0xA9, k, 0x8D, 0xFF, 0x10)
        label(n)
        op(0x2C, 0xF4, 0x1F)
        bvs(n)

    op(0x78, 0xD8, 0xA2, 0xFF, 0x9A)  # SEI; CLD; LDX #$FF; TXS
    op(0xA9, 0x00, 0x85, 0x80)        # LDA #0; STA $80
    command(1, "load1")
    op(0xA2, 0x00)                    # LDX #0
    label("inv")
    op(0xBD, 0x00, 0x11)              # LDA $1100,X
    op(0x49, 0xFF)                    # EOR #$FF
    op(0x9D, 0x00, 0x10)              # STA $1000,X
    op(0xE8, 0xE0, 0xFF)              # INX; CPX #$FF
    bne("inv")
    command(2, "save")
    op(0xA2, 0x00, 0xA9, 0x5A)        # LDX #0; LDA #$5A
    label("fill")
    op(0x9D, 0x00, 0x10)              # STA $1000,X
    op(0xE8, 0xE0, 0xFF)              # INX; CPX #$FF
    bne("fill")
    command(1, "load2")
    op(0xA9, 0xA5, 0x85, 0x80)        # LDA #$A5; STA $80
    label("end")
    op(0x4C, ORG + len(code) & 0xFF, (ORG + len(code)) >> 8)   # JMP end
    for at, n in fix:
        d = lab[n] - (ORG + at + 1)
        assert -128 <= d < 0
        code[at] = d & 0xFF
    return bytes(code)


def image():
    bank = bytearray(b"\xff" * 4096)
    p = program()
    bank[ORG - 0x1000:ORG - 0x1000 + len(p)] = p
    for v in (0xFFA, 0xFFC, 0xFFE):   # NMI, reset, IRQ: $1200
        bank[v:v + 2] = bytes((ORG & 0xFF, ORG >> 8))
    img = bytes(bank) * 6
    # detect2600.sv takes a 24 KiB image as FA2 unless it holds this pattern
    assert bytes((0xA9, 0xFD, 0x85, 0x08)) not in img
    return img


def a78():
    hdr = bytearray(128)
    hdr[0] = 4                                    # header version
    hdr[1:17] = b"ATARI7800".ljust(16)
    hdr[17:49] = b"FA2 save test (synthetic)".ljust(32, b"\0")
    hdr[49:53] = (32768).to_bytes(4, "big")       # payload size
    hdr[55] = hdr[56] = 1                         # joysticks; flags 0, NTSC
    hdr[100:128] = b"ACTUAL CART DATA STARTS HERE"
    pay = bytearray(32768)                        # $8000-$FFFF
    code = bytes((0x78, 0xD8, 0xA2, 0xFF, 0x9A,   # SEI; CLD; LDX #$FF; TXS
                  0xA9, 0x02, 0x8D, 0xFF, 0x10,   # LDA #2; STA $10FF
                  0x2C, 0xF4, 0x1F,               # BIT $1FF4
                  0x4C, 0x0D, 0x80))              # JMP $800D (itself)
    pay[:len(code)] = code
    for v in (0x7FFA, 0x7FFC, 0x7FFE):            # NMI, reset, IRQ: $8000
        pay[v:v + 2] = bytes((0x00, 0x80))
    img = bytes(hdr + pay)
    # detect2600.sv's 32 KiB FA2 rule: file bytes 29696-32767 all zero
    assert len(img) - 128 == 32768 and not any(img[29696:32768])
    return img


def flash(seed):
    return random.Random(seed).randbytes(256)


def expect(start):
    return bytes(b ^ 0xFF for b in start[:255]) + b"\x02"


def main():
    a = sys.argv[1:]
    if a == ["image"]:
        out = image()
    elif a == ["a78"]:
        out = a78()
    elif len(a) == 2 and a[0] == "flash":
        out = flash(int(a[1]))
    elif a[:1] == ["expect"] and len(a) <= 2:
        out = expect(flash(int(a[1])) if len(a) == 2 else b"\xff" * 256)
    else:
        sys.exit(__doc__)
    sys.stdout.buffer.write(out)


if __name__ == "__main__":
    main()
