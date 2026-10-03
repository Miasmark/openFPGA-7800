#!/usr/bin/env python3
"""Python model of MiSTer's BupChip: the CoreTone firmware on an ARMv4
interpreter, with the memory map of bupchip_memory.sv and the registers of
bupchip_peripheral.sv. Its PCM equals the MiSTer RTL's frame for frame.

  armemu.py GAME.a78|BLOCK.arsc [--song N] [--secs S] [--pcm OUT] [--ref REF]

Boots the firmware with the game's ARSC block (or a bare block, such as
synth_arsc.py writes), sends the song command $80|N (default 13, Misery_F)
and renders S seconds (default 4) of 200-frame batches. The FIFO is drained
200 frames at a time whenever the firmware polls with it full, so the music
does not depend on timing. Prints the boot length, the firmware's work
(average, busiest 0.1 s and worst batch, in MIPS) and the instruction mix.

--pcm writes the frames in the order the FIFO plays them from power-up (the
boot's silent prefill, then the song): 48 kHz stereo s16le, as tb_bupchip.sv
(run_bupchip.sh) writes them. --ref compares against such a file, which must
be no longer than what is rendered.

cycles.py and coverage.py import ARM, Periph, load_asset(), boot() and
render() from here.
"""
import argparse
import struct
import sys
import time
from collections import Counter

from armdec import decode, firmware

M32 = 0xffffffff
ASSET, RAM, MMIO = 0x02000000, 0x40000000, 0xE0009000
IDLE = range(0x178, 0x190)        # the main loop's poll (fw 0x178-0x18c)
POLL = 0x178
FAULT_PARK = (0xdc, 0xe8, 0x11c)  # 'b .' after writing fault 2, 1 or 3
BATCH = 200                       # frames per render batch (240 Hz)

# COND[c][NZCV] for the 4-bit flag value N<<3 | Z<<2 | C<<1 | V
COND = [[bool(f) for f in (
    [z, not z, c, not c, n, not n, v, not v, c and not z, not c or z,
     n == v, n != v, not z and n == v, z or n != v, 1, 0][cc]
    for n, z, c, v in ((f >> 3, f >> 2 & 1, f >> 1 & 1, f & 1) for f in range(16)))]
    for cc in range(16)]


class Abort(Exception):
    """An access MiSTer's bus aborts, or an encoding this model leaves out."""


class Periph:
    """bupchip_peripheral.sv as the firmware sees it. Pushed frames are kept
    in self.frames; nothing pops them (render() lowers the level instead)."""

    def __init__(self, depth=4096, cmd_depth=32):
        self.depth, self.cmd_depth = depth, cmd_depth
        self.cmds = []
        self.level = self.wm = self.enable = 0
        self.fault = None
        self.overflow = self.cmd_overflow = False
        self.frames = []

    def command(self, byte):
        if len(self.cmds) >= self.cmd_depth:
            self.cmd_overflow = True
        else:
            self.cmds.append(byte)

    def read(self, off):
        n = len(self.cmds)
        if off == 0x00:
            return 0x42555001
        if off == 0x04:
            return 0x100 | self.cmds.pop(0) if n else 0
        if off == 0x08:
            return self.cmd_overflow << 16 | (n == self.cmd_depth) << 9 | (n == 0) << 8 | n
        if off == 0x14:
            return (self.overflow << 25 | (self.level < self.wm) << 18 | (self.level == self.depth) << 17 |
                    (self.level == 0) << 16 | self.level)
        return 0

    def write(self, off, v):
        if off == 0x10:
            if self.level >= self.depth:
                self.overflow = True
            else:
                self.level += 1
                self.frames.append(v)
        elif off == 0x0C:
            if v & 1:
                self.cmd_overflow = False
            if v & 2:
                self.cmds.clear()
        elif off == 0x18:
            self.enable = v & 1
            self.wm = (v >> 16) & (2 * self.depth - 1)     # truncated, as the RTL does
            if v & 2:
                self.overflow = False
        elif off == 0x1C:
            self.fault = v & 0xff


class ARM:
    """ARMv4 ARM-state interpreter (ARM7TDMI results). step() returns 0 when the
    condition fails, 1 when the instruction ran, 2 when it also moved the PC."""

    def __init__(self, asset=b'', periph=None):
        fw = firmware()
        self.rom = struct.pack('<%dI' % len(fw), *fw).ljust(0x4000, b'\0')
        self.ram = bytearray(0x4000)
        self.asset = bytes(asset) + bytes(3)       # reads may run past the last byte
        self.asset_size = len(asset)
        self.p = periph or Periph()
        self.r = [0] * 16
        self.N = self.Z = self.C = self.V = 0
        self.dec = {}                  # pc -> decoded instruction
        self.count = Counter()         # pc -> times issued
        self.steps = 0
        self.unaligned = 0

    # ---------------------------------------------------------------- memory
    def ld(self, a, size, signed=False):
        if a & (size - 1):
            self.unaligned += 1
        if a < 0x4000:
            buf, o = self.rom, a
        elif RAM <= a < RAM + 0x4000:
            buf, o = self.ram, a - RAM
        elif ASSET <= a < ASSET + self.asset_size:
            buf, o = self.asset, a - ASSET
        elif MMIO <= a < MMIO + 0x100 and size == 4:
            return self.p.read(a & 0xfc)
        else:
            raise Abort('load from %#x' % a)
        if size == 4:
            v = struct.unpack_from('<I', buf, o & ~3)[0]
            rot = (o & 3) * 8                          # unaligned LDR rotates
            return ((v >> rot) | (v << (32 - rot))) & M32 if rot else v
        if size == 2:
            if o & 1:
                raise Abort('odd halfword load from %#x' % a)
            v = buf[o] | buf[o + 1] << 8
            return v - 0x10000 & M32 if signed and v & 0x8000 else v
        v = buf[o]
        return v - 0x100 & M32 if signed and v & 0x80 else v

    def st(self, a, size, v):
        if a & (size - 1):
            self.unaligned += 1
        if RAM <= a < RAM + 0x4000:
            o = a - RAM
            if size == 4:
                struct.pack_into('<I', self.ram, o & ~3, v & M32)
            elif size == 2:
                struct.pack_into('<H', self.ram, o & ~1, v & 0xffff)
            else:
                self.ram[o] = v & 0xff
        elif MMIO <= a < MMIO + 0x100 and size == 4:
            self.p.write(a & 0xfc, v & M32)
        else:
            raise Abort('store to %#x' % a)

    # ---------------------------------------------------------------- shifter
    def shift(self, v, st, amt):
        """Barrel shifter with the amount already resolved (immediate LSR/ASR #0
        = 32; register amounts 0-255). Returns (value, carry out)."""
        if amt == 0:
            return v, self.C
        if st == 0:
            if amt < 32:
                return (v << amt) & M32, (v >> (32 - amt)) & 1
            return 0, (v & 1 if amt == 32 else 0)
        if st == 1:
            if amt < 32:
                return v >> amt, (v >> (amt - 1)) & 1
            return 0, (v >> 31 if amt == 32 else 0)
        if st == 2:
            if amt < 32:
                return ((v - (1 << 32) if v >> 31 else v) >> amt) & M32, (v >> (amt - 1)) & 1
            return (M32 if v >> 31 else 0), v >> 31
        a = amt & 31
        if a == 0:
            return v, v >> 31
        return ((v >> a) | (v << (32 - a))) & M32, (v >> (a - 1)) & 1

    def operand2(self, d, pc):
        """Data-processing operand 2 and the shifter carry."""
        f = d['op2']
        if f == 'imm':
            return d['imm'], (d['imm'] >> 31 if d['rot'] else self.C)
        rm = d['rm']
        v = self.r[rm] if rm != 15 else pc + 8
        if f == 'reg':
            return v, self.C
        if f == 'regshift_imm':
            return self.shift(v, d['st'], d['amt'])
        if f == 'rrx':
            return (v >> 1) | (self.C << 31), v & 1
        if rm == 15:
            v = pc + 12                                # register-specified shift reads PC + 12
        return self.shift(v, d['st'], self.r[d['rs']] & 0xff)

    # ---------------------------------------------------------------- execute
    def fetch(self, pc):
        if pc >= 0x4000 or pc & 3:
            raise Abort('fetch from %#x' % pc)
        d = self.dec[pc] = decode(struct.unpack_from('<I', self.rom, pc)[0], pc)
        return d

    def step(self):
        r = self.r
        pc = r[15]
        d = self.dec.get(pc) or self.fetch(pc)
        self.count[pc] += 1
        self.steps += 1
        c = d['cond']
        if c != 14 and not COND[c][self.N << 3 | self.Z << 2 | self.C << 1 | self.V]:
            r[15] = pc + 4
            return 0
        k = d['kind']
        nxt = pc + 4
        if k == 'dp':
            op = d['op']
            rn = d['rn']
            a = r[rn] if rn != 15 else pc + 8
            b, sc = self.operand2(d, pc)
            C, V = sc, self.V
            if op == 13:
                res = b
            elif op in (0, 8):
                res = a & b
            elif op in (1, 9):
                res = a ^ b
            elif op == 12:
                res = a | b
            elif op == 14:
                res = a & ~b & M32
            elif op == 15:
                res = ~b & M32
            else:                                      # the adder: x + y + carry in
                if op in (2, 10):
                    x, y, ci = a, ~b & M32, 1
                elif op == 3:
                    x, y, ci = b, ~a & M32, 1
                elif op in (4, 11):
                    x, y, ci = a, b, 0
                elif op == 5:
                    x, y, ci = a, b, self.C
                elif op == 6:
                    x, y, ci = a, ~b & M32, self.C
                else:
                    x, y, ci = b, ~a & M32, self.C
                s = x + y + ci
                res = s & M32
                C = s >> 32
                V = (~(x ^ y) & (x ^ res)) >> 31 & 1
            if d['s']:
                self.N, self.Z, self.C, self.V = res >> 31, int(res == 0), C, V
            if op < 8 or op > 11:
                if d['rd'] == 15:
                    r[15] = res & ~3
                    return 2
                r[d['rd']] = res
        elif k == 'xfer_h' or k == 'xfer':
            rn = d['rn']
            base = r[rn] if rn != 15 else pc + 8
            if k == 'xfer':
                if not d['regoff']:
                    off = d['off12']
                else:
                    v = r[d['rm']] if d['rm'] != 15 else pc + 8
                    off = (v >> 1) | (self.C << 31) if d['rrx'] else self.shift(v, d['st'], d['amt'])[0]
                size = 1 if d['b'] else 4
                load, signed = d['l'], False
            else:
                off = d['off8'] if d['immoff'] else (r[d['rm']] if d['rm'] != 15 else pc + 8)
                op = d['op']
                size = 1 if op == 'ldrsb' else 2
                load, signed = op != 'strh', op != 'ldrh'
            ea = (base + off) & M32 if d['u'] else (base - off) & M32
            addr = ea if d['p'] else base
            rd = d['rd']
            if load:
                v = self.ld(addr, size, signed)
            else:
                self.st(addr, size, r[rd] if rd != 15 else pc + 12)
            if d['wb'] or not d['p']:
                r[rn] = ea
            if load:
                if rd == 15:
                    r[15] = v & ~3
                    return 2
                r[rd] = v
        elif k == 'b':
            if d['link']:
                r[14] = pc + 4
            r[15] = d['target']
            return 2
        elif k == 'mul':
            if d['s']:
                raise Abort('MULS at %#x' % pc)
            r[d['rd']] = (r[d['rm']] * r[d['rs']] + (r[d['rn']] if d['acc'] else 0)) & M32
        elif k == 'ldm':
            if d['s']:
                raise Abort('LDM/STM with S at %#x' % pc)
            base = r[d['rn']]
            regs = [i for i in range(16) if d['rlist'] >> i & 1]
            n = 4 * len(regs)
            a = (base + (4 if d['p'] else 0)) if d['u'] else (base - n + (0 if d['p'] else 4))
            newb = (base + n if d['u'] else base - n) & M32
            if d['l']:
                vals = [self.ld((a + 4 * j) & M32, 4) for j in range(len(regs))]
                if d['wb']:
                    r[d['rn']] = newb
                for i, v in zip(regs, vals):
                    r[i] = v
                if d['rlist'] >> 15 & 1:
                    r[15] = r[15] & ~3
                    return 2
            else:
                # with write-back, a base register that is not the first in the
                # list is stored as the new base (ARM7TDMI)
                for j, i in enumerate(regs):
                    v = pc + 12 if i == 15 else newb if d['wb'] and i == d['rn'] and j else r[i]
                    self.st((a + 4 * j) & M32, 4, v)
                if d['wb']:
                    r[d['rn']] = newb
        elif k == 'bx':
            t = r[d['rm']]
            if t & 1:
                raise Abort('BX to Thumb %#x at %#x' % (t, pc))
            r[15] = t & ~3
            return 2
        elif k == 'mull':
            if d['signed'] or d['acc'] or d['s']:
                raise Abort('long multiply form at %#x' % pc)
            res = r[d['rm']] * r[d['rs']]
            r[d['rdlo']] = res & M32
            r[d['rdhi']] = res >> 32
        elif k == 'mrs':
            # CPSR: flags, then SVC mode with IRQ and FIQ masked (0xD3), where
            # the reference core starts and the firmware's 0x20-0x2c puts it
            r[d['rd']] = self.N << 31 | self.Z << 30 | self.C << 29 | self.V << 28 | 0xD3
        elif k == 'msr':
            if d['r']:
                raise Abort('MSR SPSR at %#x' % pc)
            if d['mask'] & 8:                          # CPSR_f; CPSR_c is ignored
                v = d['imm'] if d['i'] else r[d['rm']]
                self.N, self.Z, self.C, self.V = v >> 31, v >> 30 & 1, v >> 29 & 1, v >> 28 & 1
        else:
            raise Abort('%s at %#x' % (k, pc))
        r[15] = nxt
        return 1


# -------------------------------------------------------------------- driver
def load_asset(path):
    """The ARSC block of a .a78 (it starts at 128 + the header's declared ROM
    size, bytes 49-52), or a bare block."""
    data = open(path, 'rb').read()
    if data[:4] == b'ARSC':
        return data
    return data[128 + int.from_bytes(data[49:53], 'big'):]


def boot(m, max_steps=3_000_000):
    """Run from reset to the first poll. Returns the instruction count, or
    raises Abort if the firmware faults (it parks on 'b .')."""
    n = 0
    while m.r[15] not in IDLE:
        m.step()
        n += 1
        if m.p.fault is not None and m.r[15] in FAULT_PARK:
            raise Abort('firmware fault %#x, parked at %#x' % (m.p.fault, m.r[15]))
        if n > max_steps:
            raise Abort('no poll after %d instructions' % n)
    return n


def render(m, batches, cmds=None, on_batch=None):
    """Run until `batches` 200-frame pushes have happened. Whenever the
    firmware polls (0x178) with the FIFO at the watermark and no command
    waiting, BATCH frames are drained. cmds maps a batch number to command
    bytes, delivered at the next poll. Returns one record per excursion out
    of the poll loop: (instructions, frames pushed); on_batch(m, rec) is
    called after each."""
    cmds = dict(cmds or {})
    step = m.step
    p, r = m.p, m.r
    recs = []
    done = 0
    while done < batches:
        if r[15] in IDLE:
            if r[15] == POLL:
                if done in cmds:
                    for c in cmds.pop(done):
                        p.command(c)
                if not p.cmds and p.level >= p.wm:
                    p.level -= BATCH
            step()
            continue
        s0, f0 = m.steps, len(p.frames)
        while r[15] != POLL:
            step()
            if p.fault is not None and r[15] in FAULT_PARK:
                raise Abort('firmware fault %#x, parked at %#x' % (p.fault, r[15]))
        rec = (m.steps - s0, len(p.frames) - f0)
        recs.append(rec)
        if on_batch:
            on_batch(m, rec)
        if rec[1]:
            done += 1
    return recs


def classify(w):
    """Instruction class, as tb_bupchip.sv counts them."""
    if (w & 0x0fc000f0) == 0x00000090:
        return 'MUL/MLA'
    if (w & 0x0f8000f0) == 0x00800090:
        return 'UMULL'
    if (w & 0x0ffffff0) == 0x012fff10:
        return 'BX'
    if (w & 0x0e000090) == 0x00000090:
        return 'LDRH/STRH/LDRSB/LDRSH'
    if (w & 0x0fbf0fff) == 0x010f0000 or (w & 0x0db0f000) == 0x0120f000:
        return 'MRS/MSR'
    if (w >> 25) & 7 == 0 and (w >> 4) & 1:
        return 'DP shift by register'
    return ['DP register', 'DP immediate', 'LDR/STR', 'LDR/STR', 'LDM/STM', 'B/BL', 'other', 'other'][(w >> 25) & 7]


def load_figures(recs):
    """MIPS average, busiest 0.1 s (24 batches) and worst batch, from render()."""
    secs = sum(1 for n, f in recs if f) / 240.0
    ins = [n for n, f in recs]
    pushed = [n for n, f in recs if f]
    win = min(24, len(pushed))
    peak = max(sum(pushed[i:i + win]) for i in range(len(pushed) - win + 1)) * 240 / win
    return sum(ins) / secs / 1e6, peak / 1e6, max(ins) * 240 / 1e6


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('game', help='.a78 with its ARSC block, or a bare ARSC block')
    ap.add_argument('--song', type=int, default=13)
    ap.add_argument('--secs', type=float, default=4.0)
    ap.add_argument('--pcm', help='write the PCM here (s16le stereo, 48 kHz)')
    ap.add_argument('--ref', help='compare with this PCM (tb_bupchip.sv output)')
    a = ap.parse_args()
    t0 = time.time()
    m = ARM(load_asset(a.game))
    nboot = boot(m)
    prefill = len(m.p.frames)
    print('boot: %d instructions, %d silent frames queued, watermark %d' % (nboot, prefill, m.p.wm))
    m.count.clear()
    m.p.command(0x80 | a.song)
    nb = int(round(a.secs * 240))
    recs = render(m, nb)
    avg, peak, worst = load_figures(recs)
    work = sum(n for n, f in recs)
    print('song %d, %d batches (%.2f s): %d work instructions; MIPS average %.2f, busiest 0.1 s %.2f, '
          'worst batch %.2f' % (a.song, nb, nb / 240.0, work, avg, peak, worst))
    cls = Counter()
    cond = 0
    for pc, n in m.count.items():
        if pc not in IDLE:
            cls[classify(m.dec[pc]['w'])] += n
            cond += n if m.dec[pc]['cond'] != 14 else 0
    print('mix: ' + ', '.join('%s %.2f%%' % (k, 100.0 * v / work) for k, v in cls.most_common()))
    print('conditional %.1f%%, distinct work PCs %d, unaligned accesses %d, fault %s, FIFO overflow %s'
          % (100.0 * cond / work, sum(1 for pc in m.count if pc not in IDLE), m.unaligned, m.p.fault, m.p.overflow))
    frames = m.p.frames[:prefill + nb * BATCH]
    nz = sum(1 for f in frames[prefill:] if f)
    print('PCM: %d frames (%d prefill + %d song, %d non-zero); %.0f s wall time'
          % (len(frames), prefill, len(frames) - prefill, nz, time.time() - t0))
    pcm = struct.pack('<%dI' % len(frames), *frames)
    if a.pcm:
        open(a.pcm, 'wb').write(pcm)
    if a.ref:
        # The RTL may have played some prefill frames before its measurement
        # began (it does when PCM is enabled before the command arrives): try
        # skipping up to `prefill` of ours.
        ref = open(a.ref, 'rb').read()
        n = len(ref) // 4
        skip = next((k for k in range(prefill + 1) if pcm[4 * k:4 * (k + n)] == ref[:4 * n]), None)
        if skip is not None:
            print('reference %s: all %d frames equal (from our frame %d)' % (a.ref, n, skip))
            return 0
        n = min(n, len(frames))
        bad = [i for i in range(n) if pcm[4 * i:4 * i + 4] != ref[4 * i:4 * i + 4]]
        print('reference %s: %d frames; %d of the first %d equal%s' % (
            a.ref, len(ref) // 4, n - len(bad), n, ', first difference at frame %d' % bad[0] if bad else ''))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
