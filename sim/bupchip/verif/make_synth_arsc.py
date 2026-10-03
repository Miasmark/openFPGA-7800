#!/usr/bin/env python3
"""Build a game-free .a78 with a synthetic ARSC block, for driving the
CoreTone firmware in simulation without Rikki & Vikki's music.

  make_synth_arsc.py OUT.a78 [--voices N] [--mode loop|oneshot|reverse]
                             [--break tag|csmp] [--arsc FILE]
  make_synth_arsc.py OUT.a78 --random SEED [--tracks N] [--events N]
  make_synth_arsc.py OUT.a78 --none

The image is a 128-byte A78 header, a 4 KiB cartridge of $FF and the block,
which starts at 128 + the header's ROM size like a real Souper image
(make_arsc.py, docs/BUPCHIP.md).

The default block (5.2 KB) uses the chunk layouts and the two bytecodes
(13 channel ops, 8 macro ops) read out of the firmware: CSMP 0x1b48, CINS
0x130c, CMUS 0x1970, the sequencer behind the tables at 0x1e3c. Its songs,
by command:
  $80  N channels (default 16), each a note on a looped 64-step sine;
       --mode oneshot or reverse (looped, the pitch sliding to a negative
       step) instead
  $81  one channel walking every channel op 0-12, a second ending in byte 13
  $82  data-dependent paths: a second note-on without note-off, a sample
       index past the bank (the firmware's silent sample at ROM 0x1e38),
       macro byte 13, loop + call + op 10, a one-shot ending mid-mix
  $83  a bad CMUS tag;  $84  no channels;  $85-$9F  no song
The firmware boots with it, plays it, and uses all 21 bytecode ops.
--break tag replaces the "ARSC" tag (the firmware writes fault 2),
--break csmp the "CSMP" tag (fault 3). --arsc also writes the bare block.

--random SEED is the parser stress test: valid outer headers and a CSMP
bank, random CINS and CMUS bodies. It rarely makes sound and may abort;
both cores must still agree. --none writes the image with no block at all,
for programs other than the firmware (the ISA tests).
"""
import argparse
import math
import random
import struct


def a78(block):
    """A78 header + a 4 KiB cartridge of $FF + the block."""
    rom = bytes([0xff]) * 4096
    h = bytearray(128)
    h[0] = 3
    h[1:17] = b"ATARI7800".ljust(16, b"\0")
    h[17:49] = b"synthetic ARSC".ljust(32, b"\0")
    h[49:53] = len(rom).to_bytes(4, "big")
    h[100:128] = b"ACTUAL CART DATA STARTS HERE"
    return bytes(h) + rom + block


def pad4(b):
    return b + bytes(-len(b) % 4)


def varint_delay(n):
    """A delay in 240 Hz ticks: bytes >= 0x80, 7 bits each, LSB first (max 4)."""
    assert 0 < n < (1 << 28)
    out = []
    while True:
        out.append(0x80 | (n & 0x7f))
        n >>= 7
        if not n:
            break
    return bytes(out)


def u16(x):
    return struct.pack("<H", x & 0xffff)


def chunk_csmp(samples):
    """samples: (s8 data, rate a, root b). Entries {data offset from the CSMP
    tag, length, a, b}; the step factor is floor(a * 2^33 / (b * 48000))."""
    ents, data = b"", b""
    off0 = 8 + 16 * len(samples)
    for d, a, b in samples:
        ents += struct.pack("<IIII", off0 + len(data), len(d), a, b)
        data += pad4(d)
    return b"CSMP" + struct.pack("<I", len(samples)) + ents + data


def chunk_cins(instruments):
    """instruments: (sample index, macro bytes, release offset in the macro)."""
    ents, macros = b"", b""
    off0 = 8 + 12 * len(instruments)
    for si, mac, rel in instruments:
        ents += struct.pack("<III", si, off0 + len(macros), rel)
        macros += mac
    return b"CINS" + struct.pack("<I", len(instruments)) + ents + macros


def chunk_cmus(channels):
    """channels: (s8 priority, stream bytes); channel i drives voice i."""
    tab, streams = b"", b""
    off0 = 8 + 5 * len(channels)
    for prio, s in channels:
        tab += struct.pack("<bI", prio, off0 + len(streams))
        streams += s
    return b"CMUS" + struct.pack("<I", len(channels)) + tab + streams


def arsc(csmp, cins, songs):
    """"ARSC", CSMP offset, CINS offset, 32 song offsets (0 = none), chunks."""
    hdr = 12 + 4 * 32
    body = bytearray()

    def place(c):
        off = hdr + len(body)
        body.extend(pad4(c))
        return off
    o_s, o_i = place(csmp), place(cins)
    offs = [place(s) for s in songs] + [0] * (32 - len(songs))
    return b"ARSC" + struct.pack("<II", o_s, o_i) + struct.pack("<32I", *offs) + bytes(body)


def sine(n, amp=100):
    return bytes((int(round(amp * math.sin(2 * math.pi * i / n))) & 0xff) for i in range(n))


def build(nvoices=16, mode="loop"):
    L = 4096
    samples = [(sine(64) * (L // 64), 48000, 880),      # step 1.0 at note 69
               (sine(32) * 8, 48000, 880)]               # a 256-byte one-shot
    # Macro ops: 0 stop, 1 one-shot, 2 <start><end> loop, 3 <vol><s16 slope>,
    # 4 <4 x u16> pitch slide, 5 loop start, 6 loop end, 7 nop.
    # A: volume 127, looped over the whole sample, then idle; release stops.
    mac_loop = bytes([3, 0x7f]) + u16(0) + bytes([2]) + u16(0) + u16(L) + \
        bytes([5, 0xff]) + varint_delay(1 << 20) + bytes([6])
    mac_loop_rel = len(mac_loop)
    mac_loop += bytes([0])
    # B: one-shot.
    mac_one = bytes([3, 0x7f]) + u16(0) + bytes([1]) + bytes([5, 0xff]) + varint_delay(1 << 20) + bytes([6])
    mac_one_rel = len(mac_one)
    mac_one += bytes([0])
    # C: looped from 16; a pitch slope takes the step from +1.0 to -1.0 over
    # 8 ticks (a negative step from position 0 would wrap and read past the
    # sample: the reverse wrap test is signed start against unsigned position).
    neg = (-0x20000) & 0xffffffff
    slope = (-0x4000) & 0xffffffff
    mac_rev = bytes([3, 0x7f]) + u16(0) + bytes([4]) + u16(0) + u16(0) + u16(slope) + u16(slope >> 16) + \
        bytes([2]) + u16(16) + u16(L) + varint_delay(8) + bytes([4]) + u16(neg) + u16(neg >> 16) + \
        u16(0) + u16(0) + bytes([5, 0xff]) + varint_delay(1 << 20) + bytes([6])
    mac_rev_rel = len(mac_rev)
    mac_rev += bytes([0])
    # D: every macro op 0-7 (volume slope, pitch slope, nested loops, nop, stop).
    mac_all = bytes([7, 3, 0x40]) + u16(0x0010) + bytes([4]) + u16(0) + u16(0) + u16(0x10) + u16(0) + \
        bytes([2]) + u16(0) + u16(L) + bytes([5, 2, 5, 3]) + varint_delay(2) + bytes([6, 6, 1]) + \
        varint_delay(3) + bytes([0])
    # E: a macro that ends with byte 13.
    mac_stop13 = bytes([3, 0x7f]) + u16(0) + bytes([1]) + varint_delay(2) + bytes([13])
    instruments = [(0, mac_loop, mac_loop_rel), (0, mac_one, mac_one_rel), (0, mac_rev, mac_rev_rel),
                   (0, mac_all, len(mac_all) - 1),
                   (7, mac_one, mac_one_rel),               # 4: sample index past the bank
                   (0, mac_stop13, len(mac_stop13) - 1),    # 5
                   (1, mac_one, mac_one_rel)]               # 6: short one-shot
    # Channel ops: 0 <u8> priority, 1 <L><R> pan, 2 <instrument>, 3 <note> on,
    # 4 off, 5 <4 x u16> pitch slide, 6 <count> loop start, 7 loop end,
    # 8 <s32> call, 9 return, 10 break, 11 nop, 12 <u32> marker; 13-127 end;
    # bytes >= 0x80 are a delay.
    inst = {"loop": 0, "oneshot": 1, "reverse": 2}[mode]
    chans = []
    for _ in range(nvoices):
        s = bytes([2, inst, 1, 0x7f, 0x7f, 3, 69]) + bytes([6, 0xff]) + varint_delay(1 << 20) + bytes([7])
        chans.append((1, s))
    songs = [chunk_cmus(chans)]
    # Song 1: one channel walks every channel op 0-12, then ends (13).
    sub = bytes([11, 9])
    A = bytes([2, 3, 1, 0x60, 0x20, 3, 60]) + varint_delay(5) + bytes([5]) + u16(0x100) + u16(0) + \
        u16(0x10) + u16(0) + bytes([6, 2]) + varint_delay(2) + bytes([7, 4]) + varint_delay(2) + \
        bytes([12]) + struct.pack("<I", 0x1234)
    B = bytes([2, 0, 3, 64]) + varint_delay(1) + bytes([8]) + struct.pack("<i", 0) + bytes([10]) + \
        varint_delay(2) + bytes([0, 0])
    # The call operand is relative to the byte after it: skip B and a guard 13.
    body = A + bytes([8]) + struct.pack("<i", len(B) + 1) + B + bytes([13]) + sub
    songs.append(chunk_cmus([(1, body), (2, bytes([2, 1, 3, 72]) + varint_delay(400) + bytes([13]))]))
    # Song 2: data-dependent paths.
    sub2 = bytes([10])
    tailA = bytes([6, 2, 8]) + struct.pack("<i", 2) + bytes([7, 13]) + sub2
    chA = bytes([2, 0, 3, 60]) + varint_delay(2) + bytes([3, 62]) + varint_delay(2) + bytes([2, 4, 3, 64]) + \
        varint_delay(2) + bytes([2, 5, 3, 65]) + varint_delay(40) + tailA
    chB = bytes([2, 6, 3, 69]) + varint_delay(30) + bytes([13])
    songs.append(chunk_cmus([(1, chA), (1, chB)]))
    songs.append(b"XMUS" + bytes(8))                        # song 3: bad tag
    songs.append(b"CMUS" + struct.pack("<I", 0))            # song 4: no channels
    return arsc(chunk_csmp(samples), chunk_cins(instruments), songs)


def build_random(seed, ntracks=4, nev=256):
    R = random.Random(seed)
    waves = [bytes((int(100 * math.sin(2 * math.pi * i * (k + 1) / (256 << k))) & 0xff)
                   for i in range(256 << k)) for k in range(4)]
    csmp = b"CSMP" + struct.pack("<I", len(waves))
    off = 8 + 16 * len(waves)
    for w in waves:
        csmp += struct.pack("<IIII", off, len(w), 44100 << 16, 0x01050000)
        off += len(w)
    csmp = pad4(csmp + b"".join(waves))
    cins = pad4(b"CINS" + struct.pack("<I", 8) + bytes(R.getrandbits(8) for _ in range(256)))
    base = 8 + 5 * ntracks
    evs, toff = b"", []
    for _ in range(ntracks):
        toff.append(base + len(evs))
        evs += bytes(R.getrandbits(8) for _ in range(nev))
    cmus = pad4(b"CMUS" + struct.pack("<I", ntracks) +
                b"".join(struct.pack("<bI", 0x40, o) for o in toff) + evs)
    hdr = 12 + 4 * 32
    o_ins = hdr + len(csmp)
    o_mus = o_ins + len(cins)
    return b"ARSC" + struct.pack("<II", hdr, o_ins) + struct.pack("<32I", o_mus, *([0] * 31)) + csmp + cins + cmus


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out")
    ap.add_argument("--voices", type=int, default=16)
    ap.add_argument("--mode", choices=["loop", "oneshot", "reverse"], default="loop")
    ap.add_argument("--break", dest="brk", choices=["tag", "csmp"])
    ap.add_argument("--random", type=int, metavar="SEED")
    ap.add_argument("--tracks", type=int, default=4)
    ap.add_argument("--events", type=int, default=256)
    ap.add_argument("--none", action="store_true")
    ap.add_argument("--arsc", metavar="FILE")
    a = ap.parse_args()
    if a.none:
        block = b""
    elif a.random is not None:
        block = build_random(a.random, a.tracks, a.events)
    else:
        block = build(a.voices, a.mode)
    if a.brk == "tag":
        block = b"XRSC" + block[4:]
    elif a.brk == "csmp":
        i = block.index(b"CSMP")
        block = block[:i] + b"XSMP" + block[i + 4:]
    open(a.out, "wb").write(a78(block))
    if a.arsc:
        open(a.arsc, "wb").write(block)
    print(f"{a.out}: ARSC block of {len(block)} bytes")


if __name__ == "__main__":
    main()
