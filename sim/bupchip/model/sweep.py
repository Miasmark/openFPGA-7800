#!/usr/bin/env python3
"""Full-length load sweep of every song, on Unicorn (fast).

  sweep.py GAME.a78 [--songs 0-31] [--max-secs 600] [--csv DIR] [--ref DIR]

Runs CoreTone (src/fpga/mister/rtl/bupchip.hex, the user's copy) on Unicorn
with armemu.py's idle-skipping peripheral: whenever the firmware polls with
the PCM FIFO at its watermark and no command waiting, one batch (200 frames)
is drained, so every excursion out of the poll loop is one batch of real
work. Instructions are counted per batch from basic-block sizes; the poll
loop (0x178-0x18c) is not counted, as on the RTL testbenches (retired PC).

Each song plays from its command until it ends (1 s of silent batches after
its last sound) or loops: the whole machine state (registers and RAM) at a
batch boundary equals an earlier one, so everything after repeats exactly.
Otherwise it stops at --max-secs and says so.

Per song it prints the work in MIPS (average, busiest 0.1 s = 24 batches,
worst batch) and where the peaks are, and the clock ARIA needs at 100% busy:
S1 at the song's measured CPI band (1.37-1.47, here 1.47, the highest any
song showed on the RTL) and S3 at 1.03. --ref DIR compares the first 4 s of
PCM with DIR/song<N>.pcm where present (aligned on the first nonzero frame);
--pcm DIR writes every song's frames from its command, as a long reference
for the RTL testbenches (sim/bupchip/s1/pcm_check.py).
Needs the unicorn package (sim/bupchip/setup_dev.sh puts it in
sim/work/bupchip/venv). Game data and outputs stay in sim/work/.
"""
import argparse
import hashlib
import os
import struct
import sys
import time

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE, UC_HOOK_BLOCK
from unicorn.arm_const import UC_CPU_ARM_926, UC_ARM_REG_R0, UC_ARM_REG_R15, UC_ARM_REG_CPSR

ROM, ASSET, RAM, MMIO = 0x00000000, 0x02000000, 0x40000000, 0xE0009000
IDLE_LO, IDLE_HI = 0x178, 0x190     # the main loop's poll, fw 0x178-0x18c
POLL = 0x178
BATCH = 200
CPI_S1, CPI_S3 = 1.47, 1.03

HERE = os.path.dirname(os.path.abspath(__file__))
FW_HEX = os.path.join(HERE, '../../../src/fpga/mister/rtl/bupchip.hex')


def load_asset(path):
    d = open(path, 'rb').read()
    return d if d[:4] == b'ARSC' else d[128 + int.from_bytes(d[49:53], 'big'):]


class Periph:
    """bupchip_peripheral.sv as the firmware sees it (as in armemu.py)."""

    def __init__(self, depth=4096):
        self.depth = depth
        self.cmds = []
        self.level = self.wm = 0
        self.fault = None
        self.frames = []

    def read(self, uc, off, size, ud):
        if off == 0x00:
            return 0x42555001
        if off == 0x04:
            return 0x100 | self.cmds.pop(0) if self.cmds else 0
        if off == 0x08:
            n = len(self.cmds)
            return (n == 0) << 8 | n
        if off == 0x14:
            return (self.level < self.wm) << 18 | (self.level == self.depth) << 17 | (self.level == 0) << 16 | self.level
        return 0

    def write(self, uc, off, size, v, ud):
        if off == 0x10:
            if self.level < self.depth:
                self.level += 1
                self.frames.append(v & 0xffffffff)
        elif off == 0x18:
            self.wm = (v >> 16) & (2 * self.depth - 1)
        elif off == 0x1C:
            self.fault = v & 0xff


class Song:
    def __init__(self, fw, asset, song, max_batches):
        self.p = Periph()
        uc = self.uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
        uc.ctl_set_cpu_model(UC_CPU_ARM_926)
        uc.mem_map(ROM, 0x4000)
        uc.mem_write(ROM, fw.ljust(0x4000, b'\0'))
        n = (len(asset) + 4 + 0xfff) & ~0xfff
        uc.mem_map(ASSET, n)
        uc.mem_write(ASSET, asset)
        uc.mem_map(RAM, 0x4000)
        uc.mmio_map(MMIO, 0x1000, self.p.read, None, self.p.write, None)
        self.song, self.max_batches = song, max_batches
        self.work = 0           # instructions outside the poll loop since the last poll
        self.booted = False
        self.recs = []          # per excursion: (instructions, frames pushed)
        self.batches = 0
        self.seen = {}          # state hash -> batch number
        self.loop = None        # (first batch, period) once the state repeats
        self.silent = 0
        self.ended_at = None
        self.started = False    # first nonzero frame pushed
        uc.hook_add(UC_HOOK_BLOCK, self.on_block)
        uc.hook_add(UC_HOOK_CODE, self.on_poll, begin=POLL, end=POLL)

    def on_block(self, uc, addr, size, ud):
        if not (IDLE_LO <= addr < IDLE_HI):
            self.work += size >> 2

    def on_poll(self, uc, addr, size, ud):
        p = self.p
        if not self.booted:
            self.booted = True
            self.boot_ins = self.work
            self.work = 0
            self.prefill = len(p.frames)
            p.cmds.append(0x80 | self.song)
            return
        if self.work:
            f0 = getattr(self, 'f0', self.prefill)
            pushed = len(p.frames) - f0
            self.f0 = len(p.frames)
            self.recs.append((self.work, pushed))
            self.work = 0
            if pushed:
                self.batches += 1
                fr = p.frames[-pushed:]
                if any(fr):
                    self.started = True
                    self.silent = 0
                elif self.started:
                    self.silent += 1
                if self.started and self.silent >= 240 and self.ended_at is None:
                    self.ended_at = self.batches - 240
                    uc.emu_stop()
                    return
                if self.started and self.loop is None:
                    h = hashlib.blake2b(bytes(uc.mem_read(RAM, 0x4000)), digest_size=16)
                    h.update(struct.pack('<16I', *[uc.reg_read(r) for r in range(UC_ARM_REG_R0, UC_ARM_REG_R0 + 13)],
                                         uc.reg_read(UC_ARM_REG_R0 + 13), uc.reg_read(UC_ARM_REG_R0 + 14),
                                         uc.reg_read(UC_ARM_REG_CPSR)))
                    k = h.digest()
                    if k in self.seen:
                        self.loop = (self.seen[k], self.batches - self.seen[k])
                        uc.emu_stop()
                        return
                    self.seen[k] = self.batches
                if self.batches >= self.max_batches:
                    uc.emu_stop()
                    return
        if p.fault is not None:
            uc.emu_stop()
            return
        if not p.cmds and p.level >= p.wm:
            p.level -= BATCH

    def run(self):
        self.uc.emu_start(ROM, 0xFFFFFFFF)
        return self


def figures(recs):
    pushed = [n for n, f in recs if f]
    allw = [n for n, f in recs]
    secs = len(pushed) / 240.0
    win = min(24, len(pushed))
    best, at = 0, 0
    s = sum(pushed[:win])
    best, at = s, 0
    for i in range(win, len(pushed)):
        s += pushed[i] - pushed[i - win]
        if s > best:
            best, at = s, i - win + 1
    # the worst batch after the song's first (its start-up work, absorbed by the FIFO)
    wb = max(range(1, len(pushed)), key=lambda i: pushed[i]) if len(pushed) > 1 else 0
    return (sum(allw) / secs / 1e6, best * 240 / win / 1e6, at / 240.0, pushed[wb] * 240 / 1e6, wb / 240.0, secs,
            pushed[0] * 240 / 1e6 if pushed else 0.0)


def compare_ref(frames, path):
    d = open(path, 'rb').read()
    ref = list(struct.unpack('<%dI' % (len(d) // 4), d[:len(d) // 4 * 4]))
    try:
        a = next(i for i, v in enumerate(frames) if v)
        b = next(i for i, v in enumerate(ref) if v)
    except StopIteration:
        return 'no nonzero frame'
    n = min(len(frames) - a, len(ref) - b, 4 * 48000 - b)
    bad = sum(1 for i in range(n) if frames[a + i] != ref[b + i])
    return '%d of %d frames differ' % (bad, n)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('game')
    ap.add_argument('--songs', default='0-31')
    ap.add_argument('--max-secs', type=float, default=600.0)
    ap.add_argument('--csv', help='write per-batch instruction counts to DIR/song<N>.csv')
    ap.add_argument('--ref', help='compare the first 4 s of PCM with DIR/song<N>.pcm')
    ap.add_argument('--pcm', help='write each song\'s frames, from its command, to DIR/song<N>.pcm')
    ap.add_argument('--fw', default=FW_HEX)
    a = ap.parse_args()
    if not os.path.exists(a.fw):
        sys.exit('sweep.py: no firmware at %s (docs/BUPCHIP.md, "Firmware: bupchip.bin")' % a.fw)
    fw = b''.join(struct.pack('<I', int(l, 16)) for l in open(a.fw) if l.strip())
    asset = load_asset(a.game)
    songs = []
    for part in a.songs.split(','):
        lo, _, hi = part.partition('-')
        songs += list(range(int(lo), int(hi or lo) + 1))
    print('MIPS of work: average, busiest 0.1 s, worst batch after the first (and the first, the start-up batch);')
    print('MHz: the clock ARIA needs at 100%% busy for the worst batch, S1 at CPI %.2f and S3 at %.2f' % (CPI_S1, CPI_S3))
    print('%-4s %8s  %7s %7s %7s %7s  %-14s %-14s  %6s %6s  %s' % (
        'song', 'length', 'avg', 'peak.1s', 'worst', 'first', 'peak 0.1 s at', 'worst at', 'S1 MHz', 'S3 MHz', 'end / notes'))
    for n in songs:
        t0 = time.time()
        s = Song(fw, asset, n, int(a.max_secs * 240)).run()
        if s.p.fault is not None:
            print('%-4d firmware fault %#x' % (n, s.p.fault))
            continue
        avg, peak, peak_at, worst, worst_at, secs, first = figures(s.recs)
        if s.loop:
            end = 'loops: state at %.2f s repeats after %.2f s' % (s.loop[0] / 240.0, s.loop[1] / 240.0)
        elif s.ended_at is not None:
            end = 'ends at %.2f s' % (s.ended_at / 240.0)
        else:
            end = 'still playing at --max-secs'
        if a.ref and os.path.exists(os.path.join(a.ref, 'song%d.pcm' % n)):
            end += '; PCM vs ref: ' + compare_ref(s.p.frames[s.prefill:], os.path.join(a.ref, 'song%d.pcm' % n))
        print('%-4d %7.1fs  %7.2f %7.2f %7.2f %7.2f  %8.2f s     %8.2f s      %6.2f %6.2f  %s  [%.0f s]' % (
            n, secs, avg, peak, worst, first, peak_at, worst_at, worst * CPI_S1, worst * CPI_S3, end, time.time() - t0), flush=True)
        if a.pcm:
            os.makedirs(a.pcm, exist_ok=True)
            fr = s.p.frames[s.prefill:]
            with open(os.path.join(a.pcm, 'song%d.pcm' % n), 'wb') as f:
                f.write(struct.pack('<%dI' % len(fr), *fr))
        if a.csv:
            os.makedirs(a.csv, exist_ok=True)
            with open(os.path.join(a.csv, 'song%d.csv' % n), 'w') as f:
                f.write('batch,instructions\n')
                for i, (w, fr) in enumerate([r for r in s.recs if r[1]]):
                    f.write('%d,%d\n' % (i, w))


if __name__ == '__main__':
    main()
