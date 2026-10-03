#!/usr/bin/env python3
"""Build a synthetic ARSC block for CoreTone from the formats read out of the
firmware. It contains no game data, so it and anything made from it may be
committed.

  synth_arsc.py OUT [--voices N] [--mode loop|oneshot|reverse]

OUT ending in .a78 gets a 128-byte A78 header and 4 KiB of blank cartridge in
front, as the testbenches load a game; anything else is the bare block, which
armemu.py and cycles.py also read. The block holds:

  song 0  N channels (default 16), each one voice on a 4 KiB sine at step 1.0,
          played looped, one-shot or looped with a negative step (--mode)
  song 1  one channel that walks every channel opcode 0-12, a second one note
  song 2  data-dependent paths: a second note-on without note-off, a sample
          index past the bank (the silent sample in ROM at 0x1e38), a macro
          ending in byte 13, loop + call + op 10, a one-shot ending mid-batch
  song 3  a bad tag; song 4 no channels

Layout (offsets from each chunk's tag, chunks 4-byte aligned):

  ARSC  +4 CSMP offset, +8 CINS offset, +12 u32 song offsets [32] (0 = none)
  CSMP  u32 count (<= 256), then {u32 data offset, u32 length (16 bits used),
        u32 rate a, u32 root b} per sample; signed 8-bit samples.
        Step factor = a * 2^33 / (b * 48000); a = 48000, b = 880 gives 1.0 at A4.
  CINS  u32 count, then {u32 sample index, u32 macro offset, u32 release
        offset within the macro}; then the macros
  CMUS  u32 channels (<= 16 used), then {s8 priority (0 = off), u32 stream
        offset} per channel; then the streams

Channel ops: 0 <prio>, 1 <L><R> pan, 2 <instrument>, 3 <note> note on,
4 note off, 5 <4 x u16> pitch slide, 6 <count> loop start, 7 loop end,
8 <s32> call (relative to the byte after it), 9 return, 10 break out of a
call on every channel, 11 nop, 12 <u32> marker; 13-127 end the channel.
Macro ops: 0 stop, 1 one-shot, 2 <u16 start><u16 end> looped, 3 <vol><s16
slope>, 4 <4 x u16> pitch slide, 5 <count> loop start, 6 loop end, 7 nop.
In both, bytes >= 0x80 are a delay in 240 Hz ticks: 7 bits per byte, LSB
first, up to 4 bytes.
"""
import argparse
import math
import struct


def delay(n):
    assert 0 < n < (1 << 28)
    out = []
    while True:
        out.append(0x80 | (n & 0x7f))
        n >>= 7
        if not n:
            return bytes(out)


def u16(x):
    return struct.pack('<H', x & 0xffff)


def u32(x):
    return struct.pack('<I', x & 0xffffffff)


def chunk_csmp(samples):
    """samples: list of (signed 8-bit data, rate a, root b)."""
    ents, data = b'', b''
    off0 = 8 + 16 * len(samples)
    for d, a, b in samples:
        ents += struct.pack('<IIII', off0 + len(data), len(d), a, b)
        data += d + bytes(-len(d) % 4)
    return b'CSMP' + u32(len(samples)) + ents + data


def chunk_cins(instruments):
    """instruments: list of (sample index, macro bytes, release offset)."""
    ents, macros = b'', b''
    off0 = 8 + 12 * len(instruments)
    for si, mac, rel in instruments:
        ents += struct.pack('<III', si, off0 + len(macros), rel)
        macros += mac
    return b'CINS' + u32(len(instruments)) + ents + macros


def chunk_cmus(channels):
    """channels: list of (priority, stream bytes)."""
    tab, streams = b'', b''
    off0 = 8 + 5 * len(channels)
    for prio, s in channels:
        tab += struct.pack('<bI', prio, off0 + len(streams))
        streams += s
    return b'CMUS' + u32(len(channels)) + tab + streams


def arsc(csmp, cins, songs):
    body = bytearray()

    def place(c):
        off = 12 + 4 * 32 + len(body)
        body.extend(c + bytes(-len(c) % 4))
        return off
    o_smp, o_ins = place(csmp), place(cins)
    offs = [place(s) for s in songs] + [0] * (32 - len(songs))
    return b'ARSC' + struct.pack('<II32I', o_smp, o_ins, *offs) + bytes(body)


def sine(n, amp=100):
    return bytes(int(round(amp * math.sin(2 * math.pi * i / n))) & 0xff for i in range(n))


def build(voices=16, mode='loop'):
    L = 4096
    samples = [(sine(64) * (L // 64), 48000, 880),      # 0: step 1.0 at note 69
               (sine(32) * 8, 48000, 880)]              # 1: 256 bytes
    hold = bytes([5, 0xff]) + delay(1 << 20) + bytes([6])   # wait for ever
    # looped over the whole sample; release stops the voice
    loop = bytes([3, 0x7f]) + u16(0) + bytes([2]) + u16(0) + u16(L) + hold
    one = bytes([3, 0x7f]) + u16(0) + bytes([1]) + hold
    # looped from 16 with the step slid from +1.0 to -1.0 over 8 ticks (a
    # negative step from position 0 would read before the sample)
    neg, slope = -0x20000, -0x4000
    rev = (bytes([3, 0x7f]) + u16(0) + bytes([4]) + u16(0) + u16(0) + u16(slope) + u16(slope >> 16) +
           bytes([2]) + u16(16) + u16(L) + delay(8) + bytes([4]) + u16(neg) + u16(neg >> 16) + u16(0) + u16(0) +
           hold)
    # every macro op: volume and pitch slides, nested loops, nop, stop
    every = (bytes([7, 3, 0x40]) + u16(0x10) + bytes([4]) + u16(0) + u16(0) + u16(0x10) + u16(0) +
             bytes([2]) + u16(0) + u16(L) + bytes([5, 2, 5, 3]) + delay(2) + bytes([6, 6, 1]) + delay(3) + bytes([0]))
    stop13 = bytes([3, 0x7f]) + u16(0) + bytes([1]) + delay(2) + bytes([13])
    instruments = [(0, loop + b'\0', len(loop)), (0, one + b'\0', len(one)), (0, rev + b'\0', len(rev)),
                   (0, every, len(every) - 1),
                   (7, one + b'\0', len(one)),          # 4: sample index past the bank
                   (0, stop13, len(stop13) - 1),        # 5: macro ends with byte 13
                   (1, one + b'\0', len(one))]          # 6: short one-shot
    inst = {'loop': 0, 'oneshot': 1, 'reverse': 2}[mode]
    song0 = chunk_cmus([(1, bytes([2, inst, 1, 0x7f, 0x7f, 3, 69, 6, 0xff]) + delay(1 << 20) + bytes([7]))] * voices)
    # song 1: every channel op; the call skips B and a guard 13 to land on 'sub'
    sub = bytes([11, 9])
    A = (bytes([2, 3, 1, 0x60, 0x20, 3, 60]) + delay(5) + bytes([5]) + u16(0x100) + u16(0) + u16(0x10) + u16(0) +
         bytes([6, 2]) + delay(2) + bytes([7, 4]) + delay(2) + bytes([12]) + u32(0x1234))
    B = bytes([2, 0, 3, 64]) + delay(1) + bytes([8]) + u32(0) + bytes([10]) + delay(2) + bytes([0, 0])
    song1 = chunk_cmus([(1, A + bytes([8]) + u32(len(B) + 1) + B + bytes([13]) + sub),
                        (2, bytes([2, 1, 3, 72]) + delay(400) + bytes([13]))])
    # song 2: data-dependent paths
    chA = (bytes([2, 0, 3, 60]) + delay(2) + bytes([3, 62]) + delay(2) + bytes([2, 4, 3, 64]) + delay(2) +
           bytes([2, 5, 3, 65]) + delay(40) + bytes([6, 2, 8]) + u32(2) + bytes([7, 13, 10]))
    chB = bytes([2, 6, 3, 69]) + delay(30) + bytes([13])
    song2 = chunk_cmus([(1, chA), (1, chB)])
    songs = [song0, song1, song2, b'XMUS' + bytes(8), b'CMUS' + u32(0)]
    return arsc(chunk_csmp(samples), chunk_cins(instruments), songs)


def a78(block, title=b'synthetic ARSC'):
    """Wrap a block as a .a78: header, 4 KiB of blank cartridge, then the block."""
    rom = b'\xff' * 4096
    h = bytearray(128)
    h[0] = 3
    h[1:17] = b'ATARI7800'.ljust(16, b'\0')
    h[17:49] = title.ljust(32, b'\0')
    h[49:53] = len(rom).to_bytes(4, 'big')
    h[100:128] = b'ACTUAL CART DATA STARTS HERE'
    return bytes(h) + rom + block


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('out')
    ap.add_argument('--voices', type=int, default=16)
    ap.add_argument('--mode', choices=('loop', 'oneshot', 'reverse'), default='loop')
    a = ap.parse_args()
    block = build(a.voices, a.mode)
    open(a.out, 'wb').write(a78(block) if a.out.endswith('.a78') else block)
    print('%s: ARSC block %d bytes' % (a.out, len(block)))
