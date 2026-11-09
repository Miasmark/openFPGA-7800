#!/usr/bin/env python3
"""Tables for cc_test.asm: the closed caption line's waveform as MARIA
320D pixels, and the caption sequence with parity.

EIA-608 line 21: 7 cycles of clock run-in from 10.5 us after the leading
edge of sync, then start bits 0 0 1, then two bytes, each 7 bits LSB first
and an odd parity bit. One bit is 1/32 of a line: 454 / 32 = 14.1875 MARIA
clocks. MARIA can draw only columns PIX0_COL to PIX0_COL + 319, so the run-in
starts 18 clocks late (about 5.7 of its 7 cycles show), and the last two
bits (the second byte's bit 6 and parity, columns 415-444) fall in the
right border, where the cart puts them with two BACKGRND writes.

A second set (cc4_*) is for the cart's playfield grid mode: the same
waveform at the standard rate, with every edge rounded to a grid of 8 MARIA
clocks from the picture's first pixel (4 TIA colour clocks: the 2600's
playfield pixel), to find out whether a 2600 could send captions with
playfield graphics. An edge moves at most 4 clocks, under the half bit
(7.1) that keeps each bit's centre, where the decoder samples, in its bit.
The run-in cannot keep its rate on that grid (a pulse and a gap take two
slots, 16 clocks, more than a cycle's 14.19), so it is 8-clock pulses every
16 clocks, ending at the first start bit. The border bits are on the grid
already (columns 413 and 429).
(An earlier experiment, 8-clock bits at 895 kbit/s, did not decode on the
owner's Samsung CRT, 2026-11-09: its decoder samples at a fixed rate.)

Usage: cc_tables.py PIX0_COL > cc_tables.inc
"""
import sys

PIX0_COL = int(sys.argv[1]) if len(sys.argv) > 1 else 93
T = 454 / 32                  # one bit, in MARIA clocks
RUNIN = 75.0                  # 10.5 us after sync, in MARIA clocks (10.5 / 63.41 * 454)
D0 = RUNIN + 7 * T            # the first start bit

def waveform(T, D0, nbits):
    """base bitmap (run-in, start bits) and masks for data bits 3..nbits+2"""
    px = [0] * 320
    def high(a, b):
        for c in range(round(a), round(b)):
            p = c - PIX0_COL
            if 0 <= p < 320:
                px[p] = 1
    def cell(k):
        return D0 + k * T
    r0 = D0 - 7 * T
    for j in range(7):                      # run-in: a cycle a bit, high
        s0 = r0 + j * T                     # in its middle half
        high(s0 + T / 4, s0 + 3 * T / 4)
    high(cell(2), cell(3))                  # start bits 0 0 1
    base = [sum(px[8 * i + b] << (7 - b) for b in range(8)) for i in range(40)]
    masks = []
    for k in range(3, 3 + nbits):
        m = {}
        for c in range(round(cell(k)), round(cell(k + 1))):
            p = c - PIX0_COL
            if 0 <= p < 320:
                m[p // 8] = m.get(p // 8, 0) | (0x80 >> (p % 8))
        items = sorted(m.items()) + [(0xFF, 0)] * 3
        assert len(m) <= 3
        masks.append(items[:3])
    return base, masks

base, masks = waveform(T, D0, 14)          # bits 17-18 go in the border

def waveform_grid(nbits):
    """the playfield grid version: edges on 8-clock slots from PIX0_COL"""
    G = 8
    def g(c):
        return PIX0_COL + G * int((c - PIX0_COL) / G + 0.5)
    def cell(k):
        return D0 + k * T
    px = [0] * 320
    def high(a, b):
        for c in range(a, b):
            if 0 <= c - PIX0_COL < 320:
                px[c - PIX0_COL] = 1
    end = g(cell(0))                        # run-in: 8 high, 8 low, ending
    for j in range(1, 8):                   # (low) at the first start bit
        a = end - 16 * j
        if a >= PIX0_COL:
            high(a, a + 8)
    high(g(cell(2)), g(cell(3)))            # start bits 0 0 1
    base = [sum(px[8 * i + b] << (7 - b) for b in range(8)) for i in range(40)]
    masks = []
    for k in range(3, 3 + nbits):
        m = {}
        for c in range(g(cell(k)), g(cell(k + 1))):
            p = c - PIX0_COL
            if 0 <= p < 320:
                m[p // 8] = m.get(p // 8, 0) | (0x80 >> (p % 8))
        items = sorted(m.items()) + [(0xFF, 0)] * 3
        assert len(m) <= 3
        masks.append(items[:3])
    return base, masks

base4, masks4 = waveform_grid(14)

def par(c):                   # odd parity in bit 7
    return c | (0x80 if bin(c).count("1") % 2 == 0 else 0)

# The sequence, one byte pair a frame (pop-on): RCL, ENM, PAC row 15, the
# text, EOC, each control code twice as broadcasters send them, then nulls.
# A first byte of $14 marked MISC becomes $15 for CC3 at run time.
MISC = 0x100
seq = []
def ctrl(a, b, misc=True):
    for _ in range(2):
        seq.append(((MISC if misc else 0) | a, b))
ctrl(0x14, 0x20)              # RCL: resume caption loading
ctrl(0x14, 0x2E)              # ENM: erase non-displayed memory
ctrl(0x14, 0x60, misc=False)  # PAC: row 15, white, indent 0
TEXT = "ATARI 7800 CAPTION #"  # '#' is the counter, 0-9
assert len(TEXT) % 2 == 0
for i in range(0, len(TEXT), 2):
    seq.append((ord(TEXT[i]), ord(TEXT[i + 1])))
COUNTER = len(seq) - 1        # its second byte is the counter
ctrl(0x14, 0x2F)              # EOC: end of caption (show it)
NULLS = 120                   # about 2 s of nulls before the next caption

print("; cc_tables.inc: generated by cc_tables.py %d; do not edit" % PIX0_COL)
print("PIX0_COL = %d" % PIX0_COL)
print("SEQ_LEN  = %d" % len(seq))
print("SEQ_CNT  = %d          ; the entry whose second byte is the counter" % COUNTER)
print("SEQ_NULL = %d" % NULLS)
print("cc_base")
for i in range(0, 40, 8):
    print("\tdc.b " + ", ".join("$%02X" % v for v in base[i:i + 8]))
for n in range(3):
    print("cc_mi%d\tdc.b " % n + ", ".join("$%02X" % m[n][0] for m in masks))
    print("cc_mm%d\tdc.b " % n + ", ".join("$%02X" % m[n][1] for m in masks))
print("; the playfield grid mode")
print("cc4_base")
for i in range(0, 40, 8):
    print("\tdc.b " + ", ".join("$%02X" % v for v in base4[i:i + 8]))
for n in range(3):
    print("cc4_mi%d\tdc.b " % n + ", ".join("$%02X" % m[n][0] for m in masks4))
    print("cc4_mm%d\tdc.b " % n + ", ".join("$%02X" % m[n][1] for m in masks4))
print("; first byte (bit 0 of seq_misc: a misc code, $15 for CC3), second byte")
print("seq_a\tdc.b " + ", ".join("$%02X" % par(a & 0xFF) for a, _ in seq))
print("seq_b\tdc.b " + ", ".join("$%02X" % par(b) for _, b in seq))
print("seq_misc dc.b " + ", ".join("%d" % (1 if a & MISC else 0) for a, _ in seq))
print("par_15\tdc.b $%02X" % par(0x15))
print("par_dig\tdc.b " + ", ".join("$%02X" % par(0x30 + d) for d in range(10)))
