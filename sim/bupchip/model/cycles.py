#!/usr/bin/env python3
"""Trace-driven cycle model of the Pocket BupChip core (docs/BUPCHIP_CORE.md).
The firmware runs in armemu.py; every instruction is charged the clocks that
each candidate core would take, each core with its own clock and asset path.

  cycles.py GAME.a78|BLOCK.arsc [--song N] [--secs S] [--run CORE/ASSET ...]
            [--batches OUT.csv]
  cycles.py --synth loop|oneshot|reverse [--secs S] ...   16 voices (synth_arsc.py)
  cycles.py --loops                                       the mixer loops, statically

CORE is S1, S2 or S3 (the design's steps), S3-f1 (no load forwarding into
the multiplier), S3-f2 (no load forwarding, 2-clock MUL/MLA), S3-m10k (M10K
register file: BX 2, LDR pc 3), arm7 (ARM7TDMI cycle counts on zero-wait
memory) or ref (MiSTer's arm7tdmi_core on zero-wait memory: arm7 plus one
clock per multiply and four per asset load). ASSET is one of ASSETS below:
cache is the design's 64 x 16 B cache; stream is proposal B's two-line
stream buffer, the asset path of the RTL that measured S1's CPI.

Prints, per pair: CPI; the clock needed at 100% busy on average, in the
busiest 0.1 s, in the worst batch and in the worst batch after the
song-start one (the RTL's figure); the lowest clock at which a 1,024-frame
FIFO (watermark remapped to 824) never underruns; the lowest FIFO level at
21.477, 21.281 and 28.636 MHz; then clocks per instruction class and the
asset path's statistics. A batch runs from leaving the poll (fw 0x190) to
returning to 0x178; the command excursion counts as work. 4 s of Misery_F
with the default pairs takes about 5 minutes.
"""
import argparse
import sys
import time
from collections import Counter

from armdec import decode, firmware
from armemu import ARM, ASSET, MMIO, IDLE, BATCH, boot, classify, load_asset, render
import synth_arsc

# ---------------------------------------------------------------- cores
# Clocks per executed instruction; a condition-failed one takes 1. ldm_wb/ldm
# and stm are added to n for LDM with/without write-back and STM. ldu adds a
# clock when an instruction reads ('all') or multiplies ('mul') a register
# loaded by the instruction just before it. mul None means ARM7TDMI counts
# (MUL 1+m, MLA 2+m, UMULL 2+m, m from Rs) plus mul_extra.
S3 = dict(load=1, ldr_pc=2, store=1, store_reg=1, store_mmio=1, ldm_wb=0, ldm=0, stm=0, mul=1, umull=2,
          shift_reg=2, b=1, bx=1, ldu=None, mul_extra=0, asset_extra=0)
ARM7 = dict(S3, load=3, ldr_pc=5, store=2, store_reg=2, store_mmio=2, ldm_wb=2, ldm=2, stm=1, mul=None, umull=None,
            b=3, bx=3)
CORES = {
    'S1': dict(S3, load=2, store_reg=2, store_mmio=2, ldm_wb=2, ldm=1, mul=2, umull=3),    # B's bup_cpu.sv
    'S2': dict(S3, store_reg=2, mul=2, umull=3),
    'S3': S3,
    'S3-f1': dict(S3, ldu='mul'),
    'S3-f2': dict(S3, ldu='all', mul=2, umull=3),
    'S3-m10k': dict(S3, bx=2, ldr_pc=3),
    'arm7': ARM7,
    'ref': dict(ARM7, mul_extra=1, asset_extra=4),
}


def base_clocks(c, d, res, mmio):
    """Clocks of one instruction on core c, before load-use and asset stalls.
    res is ARM.step()'s result (0 = condition failed); mmio marks a store
    that went to the peripheral."""
    if not res:
        return 1
    k = d['kind']
    if k == 'dp':
        return c['shift_reg'] if d['op2'] == 'regshift_reg' else 1
    if k in ('xfer', 'xfer_h'):
        if d['l'] if k == 'xfer' else d['op'] != 'strh':
            return c['ldr_pc'] if d['rd'] == 15 else c['load']
        n = c['store']
        if d['regoff'] if k == 'xfer' else not d['immoff']:
            n = max(n, c['store_reg'])
        return max(n, c['store_mmio']) if mmio else n
    if k == 'ldm':
        n = bin(d['rlist']).count('1')
        return n + (c['ldm_wb'] if d['wb'] else c['ldm']) if d['l'] else n + c['stm']
    if k == 'b':
        return c['b']
    if k == 'bx':
        return c['bx']
    if k == 'mul':
        return c['mul'] or 1 + d['acc'] + c['mul_extra']
    if k == 'mull':
        return c['umull'] or 2 + c['mul_extra']
    return 1


def mul_cycles(rs, signed=True):
    """ARM7TDMI multiplier early termination: 1-4 cycles from Rs."""
    for m, top in ((1, rs >> 8), (2, rs >> 16), (3, rs >> 24)):
        if top == 0 or signed and top == (0xffffffff >> (8 * m)):
            return m
    return 4


def reads(d):
    """(registers read, registers read by the multiplier)."""
    k = d['kind']
    if k == 'dp':
        s = set() if d['op'] in (13, 15) else {d['rn']}
        return s | ({d['rm']} | ({d['rs']} if d['op2'] == 'regshift_reg' else set()) if not d['i'] else set()), set()
    if k in ('xfer', 'xfer_h'):
        s = {d['rn']}
        if d['regoff'] if k == 'xfer' else not d['immoff']:
            s.add(d['rm'])
        if not (d['l'] if k == 'xfer' else d['op'] != 'strh'):
            s.add(d['rd'])
        return s, set()
    if k == 'ldm':
        return {d['rn']} | ({i for i in range(16) if d['rlist'] >> i & 1} if not d['l'] else set()), set()
    if k == 'bx':
        return {d['rm']}, set()
    if k in ('mul', 'mull'):
        s = {d['rm'], d['rs']} | ({d['rn']} if k == 'mul' and d['acc'] else set())
        return s, s
    return set(), set()


def loaded(d):
    """Registers an instruction loads (for the next one's load-use check)."""
    k = d['kind']
    if k == 'xfer' and d['l'] or k == 'xfer_h' and d['op'] != 'strh':
        return {d['rd']}
    if k == 'ldm' and d['l']:
        return {max(i for i in range(16) if d['rlist'] >> i & 1)}   # the last beat
    return set()


# ---------------------------------------------------------------- asset paths
class Cache:
    """Direct-mapped read cache in front of PSRAM: one halfword per t_hw
    clocks, one fill at a time (a miss waits for the fill in flight; no
    pre-emption). A miss fills from the critical halfword and wraps; the tag
    is set when the fill starts, so a hit on a line under fill waits for its
    halfwords. A load completes once every halfword it touches has arrived
    (both for LDR): a miss costs the last needed halfword's arrival + ovh - 1
    clocks after W, a late hit its arrival + 1. After every access the next
    line is prefetched from halfword 0 if absent."""

    def __init__(self, lines=64, line=16, t_hw=5, prefetch=True, ovh=3):
        self.N, self.L, self.t_hw, self.prefetch, self.ovh = lines, line, t_hw, prefetch, ovh
        self.tag = [None] * lines
        self.ready = [[0] * (line // 2) for _ in range(lines)]
        self.free_at = 0
        self.misses = self.prefetches = self.late = self.stall = 0

    def fill(self, line, start, first):
        i, H = line % self.N, self.L // 2
        self.tag[i] = line
        for j in range(H):
            self.ready[i][(first + j) % H] = start + (j + 1) * self.t_hw
        self.free_at = start + H * self.t_hw

    def access(self, off, size, t):
        """off: offset in the asset window; t: the load's execute clock.
        Returns the stall clocks."""
        need = t + 1                                   # the data is due in W
        h0 = off & ~3 if size == 4 else off & ~1
        ready, missed = 0, False
        for h in range(h0, h0 + max(size, 2), 2):
            line = h // self.L
            i, k = line % self.N, (h % self.L) // 2
            if self.tag[i] != line:
                self.misses += 1
                missed = True
                self.fill(line, max(need + 1, self.free_at), k)
            ready = max(ready, self.ready[i][k])
        if missed:
            st = max(0, ready + self.ovh - 1 - need)
        elif ready > need:
            st = ready + 1 - need
            self.late += 1
        else:
            st = 0
        if self.prefetch:
            nl = (h0 + max(size, 2) - 2) // self.L + 1
            if self.tag[nl % self.N] != nl:
                self.prefetches += 1
                self.fill(nl, max(need + st + 1, self.free_at), 0)
        self.stall += st
        return st


class StreamBuffer:
    """Proposal B's asset path (bup_asset.sv in the study's RTL sketch):
    two 16-byte lines, critical halfword first, next line prefetched in the
    direction of travel; a demand miss waits for the halfword in flight, then
    abandons the prefetch."""

    def __init__(self, line=16, t_hw=5, ovh=2):
        self.L, self.t_hw, self.ovh = line, t_hw, ovh
        self.slots = [None, None]                      # [line, ready time per halfword]
        self.mru = 0
        self.busy_until = 0
        self.last = None
        self.dir = 1
        self.misses = self.prefetches = self.late = self.stall = 0

    def fill(self, slot, line, first, t0):
        H = self.L // 2
        rt = [0] * H
        t = max(t0, self.busy_until)
        for j in range(H):
            t += self.t_hw
            rt[(first + j) % H] = t
        self.busy_until = t
        self.slots[slot] = [line, rt]

    def access(self, off, size, t):
        now = t + 1
        line, hw = off // self.L, (off % self.L) // 2
        if self.last is not None and off != self.last and abs(off - self.last) < 4 * self.L:
            self.dir = 1 if off > self.last else -1
        self.last = off
        hit = next((s for s in (0, 1) if self.slots[s] and self.slots[s][0] == line), None)
        if hit is None:
            self.misses += 1
            hit = 1 - self.mru
            self.busy_until = min(self.busy_until, now + self.t_hw)
            self.fill(hit, line, hw, now + self.ovh)
        elif self.slots[hit][1][hw] > now:
            self.late += 1
        st = max(0, self.slots[hit][1][hw] - now)
        self.stall += st
        self.mru = hit
        nl, o = line + self.dir, 1 - hit
        if not (self.slots[o] and self.slots[o][0] == nl):
            self.prefetches += 1
            self.fill(o, nl, 0 if self.dir > 0 else self.L // 2 - 1, now + st)
        return st


ASSETS = {
    'cache': lambda: Cache(),                              # the design: 64 x 16 B, prefetch, 5 clocks
    'cache32': lambda: Cache(lines=32),
    'cache128': lambda: Cache(lines=128),
    'cache-nopf': lambda: Cache(prefetch=False),
    'cache-t4': lambda: Cache(t_hw=4),                     # a 4-clock PSRAM controller
    'nocache': lambda: Cache(lines=1, line=2, prefetch=False),
    'stream': lambda: StreamBuffer(),
    'none': lambda: None,
}
DEFAULT_RUN = ['S1/stream', 'S1/cache', 'S2/stream', 'S2/cache', 'S3/cache', 'S3-f1/cache', 'S3-f2/cache',
               'S3-m10k/cache', 'arm7/none', 'ref/none']


class Pair:
    def __init__(self, name):
        core, asset = name.split('/')
        self.name, self.core, self.asset = name, CORES[core], ASSETS[asset]()
        self.ldu = self.core['ldu']
        self.mterm = self.core['mul'] is None
        self.extra = self.core['asset_extra']
        self.now = self.mark = 0
        self.clocks = []                               # per excursion
        self.cls = Counter()


class Timed(ARM):
    """armemu's ARM with every instruction charged to each pair."""

    def __init__(self, asset, pairs):
        ARM.__init__(self, asset)
        self.pairs = pairs
        self.costs = {}
        self.info = {}
        self.assets = []
        self.mmio = False
        self.prev = set()
        self.track = False
        self.cls_count = Counter()

    def ld(self, a, size, signed=False):
        if ASSET <= a < ASSET + 0x1000000:
            self.assets.append((a - ASSET, size))
        return ARM.ld(self, a, size, signed)

    def st(self, a, size, v):
        if a >= MMIO:
            self.mmio = True
        ARM.st(self, a, size, v)

    def step(self):
        pc = self.r[15]
        d = self.dec.get(pc) or self.fetch(pc)
        info = self.info.get(pc)
        if info is None:
            r_all, r_mul = reads(d)
            info = self.info[pc] = (classify(d['w']), r_all, r_mul, loaded(d), d['kind'] in ('mul', 'mull'),
                                    pc in IDLE)
        cls, r_all, r_mul, dest, is_mul, idle = info
        rs = self.r[d['rs']] if is_mul else 0
        self.assets = []
        self.mmio = False
        res = ARM.step(self)
        key = (pc, res, self.mmio)
        costs = self.costs.get(key)
        if costs is None:
            costs = self.costs[key] = [base_clocks(p.core, d, res, self.mmio) for p in self.pairs]
        prev, assets, track = self.prev, self.assets, self.track and not idle
        for p, c in zip(self.pairs, costs):
            if p.ldu and prev and prev & (r_all if p.ldu == 'all' else r_mul):
                c += 1
            if p.mterm and is_mul and res:
                c += mul_cycles(rs, d['kind'] == 'mul')
            if assets and res:
                if p.asset:
                    for off, size in assets:
                        c += p.asset.access(off, size, p.now)
                c += p.extra * len(assets)
            p.now += c
            if idle:
                p.mark = p.now
            elif track:
                p.cls[cls] += c
        if track:
            self.cls_count[cls] += 1
        self.prev = dest if res else set()
        return res


# ---------------------------------------------------------------- the FIFO
def fifo_low(recs, clocks, f_hz, depth=1024):
    """Lowest PCM FIFO level while the firmware renders against a 48 kHz
    drain at f_hz. The watermark is remapped to depth - 200 and the boot
    prefill is the batches it takes to reach it; before each batch the
    firmware idles until the level drops below the watermark."""
    w = depth - BATCH
    level = lo = float(-(-w // BATCH) * BATCH)
    for (n, frames), c in zip(recs, clocks):
        if frames and level >= w:
            level = w - 1
        level -= 48000.0 * c / f_hz
        lo = min(lo, level)
        level += frames
    return lo


def min_clock(recs, clocks, depth=1024):
    lo, hi = 5e6, 80e6
    for _ in range(40):
        mid = (lo + hi) / 2
        lo, hi = (lo, mid) if fifo_low(recs, clocks, mid, depth) >= 0 else (mid, hi)
    return hi


# ---------------------------------------------------------------- reports
def report(recs, pairs, cls_count, synth):
    pushed = [i for i, (n, f) in enumerate(recs) if f]
    secs = len(pushed) / 240.0
    ins = sum(n for n, f in recs)
    win = min(24, len(pushed))
    print('%d batches (%.2f s), %d work instructions: %.2f MIPS average, %.2f busiest 0.1 s, %.2f worst batch'
          % (len(pushed), secs, ins, ins / secs / 1e6,
             max(sum(recs[i][0] for i in pushed[j:j + win]) for j in range(len(pushed) - win + 1)) * 240 / win / 1e6,
             max(n for n, f in recs) * 240 / 1e6))
    print('\n%-14s %6s %26s %8s %8s %18s %13s' % ('core/asset', 'CPI', 'MHz: avg / 0.1 s / worst', 'w/o start',
                                                'no-underr', 'FIFO low @21.477', 'MIPS @21.477'))
    print('%-14s %6s %26s %8s %8s %18s %13s' % ('', '', '', '', 'MHz', '/21.281/28.636', '/28.636'))
    for p in pairs:
        c = p.clocks
        cyc = sum(c)
        cpi = cyc / ins
        busy = max(sum(c[i] for i in pushed[j:j + win]) for j in range(len(pushed) - win + 1)) * 240 / win / 1e6
        rest = max(c[i] for i in pushed[1:]) if len(pushed) > 1 else c[pushed[0]]
        lows = [fifo_low(recs, c, f * 1e6) for f in (21.477, 21.281, 28.636)]
        print('%-14s %6.3f %8.2f / %5.2f / %5.2f %8.2f %8.2f %6.0f/%4.0f/%4.0f %6.1f/%5.1f' % (
            p.name, cpi, cyc / secs / 1e6, busy, max(c) * 240 / 1e6, rest * 240 / 1e6, min_clock(recs, c) / 1e6,
            lows[0], lows[1], lows[2], 21.477 / cpi, 28.636 / cpi))
    if synth:
        print('steady (last batch), MHz at 100% busy: ' + ', '.join(
            '%s %.2f' % (p.name, p.clocks[pushed[-1]] * 240 / 1e6) for p in pairs) +
            '; MIPS %.2f' % (recs[pushed[-1]][0] * 240 / 1e6))
    total = sum(cls_count.values())
    print('\nclocks per instruction, by class:')
    print('%-24s %7s ' % ('class', 'share') + ' '.join('%9s' % p.name.split('/')[0] for p in pairs))
    print('%-24s %7s ' % ('', '') + ' '.join('%9s' % p.name.split('/')[1] for p in pairs))
    for k, n in cls_count.most_common():
        print('%-24s %6.2f%% ' % (k, 100.0 * n / total) + ' '.join('%9.3f' % (p.cls[k] / n) for p in pairs))
    print('\nasset path: misses, prefetches, late hits, stall clocks (share of all clocks)')
    for p in pairs:
        a = p.asset
        if a:
            print('   %-14s %8d %8d %7d %9d (%.2f%%)' % (p.name, a.misses, a.prefetches, a.late, a.stall,
                                                      100.0 * a.stall / sum(p.clocks)))


LOOPS = {   # pcs of one iteration, branch outcomes (fw.dis:776-802 is the hot one)
    'one-shot, first voice 0xa68': (list(range(0xa68, 0xab0, 4)), {0xa6c: False, 0xaac: True}),
    'one-shot, other voices 0xb8c': (list(range(0xb8c, 0xbdc, 4)), {0xb90: False, 0xbd8: True}),
    'looped, first voice 0xb24': (list(range(0xb24, 0xb64, 4)) + list(range(0xb78, 0xb88, 4)),
                                  {0xb60: True, 0xb80: False, 0xb84: True}),
    'looped, other voices 0xc00 (hot)': (list(range(0xc00, 0xc48, 4)) + list(range(0xc5c, 0xc6c, 4)),
                                         {0xc44: True, 0xc64: False, 0xc68: True}),
    'reverse, first voice 0xc74': (list(range(0xc74, 0xcb4, 4)) + list(range(0xcc8, 0xcd8, 4)),
                                   {0xcb0: True, 0xcd0: False, 0xcd4: True}),
    'reverse, other voices 0xce0': (list(range(0xce0, 0xd28, 4)) + list(range(0xd3c, 0xd48, 4)),
                                    {0xd24: True, 0xd44: True}),
}
SAMPLE_LOADS = {0xa7c, 0xb30, 0xba8, 0xc10, 0xc80, 0xcf0}     # the ldrsb from the asset window


def loops():
    """Clocks per iteration of the six mixer loops, steady state: every asset
    load hits, multiplies terminate after one cycle (m = 1)."""
    W = firmware()
    print('%-34s %5s ' % ('loop', 'instr') + ' '.join('%7s' % c for c in CORES))
    for name, (pcs, taken) in LOOPS.items():
        row = []
        for c in CORES.values():
            prev, n = set(), 0
            for it in range(2):                        # the second pass sees the wrap-around hazards
                n = 0
                for pc in pcs:
                    d = decode(W[pc // 4], pc)
                    res = 0 if d['kind'] == 'b' and not taken.get(pc) else 1
                    r_all, r_mul = reads(d)
                    n += base_clocks(c, d, res, False) + (c['mul'] is None and d['kind'] in ('mul', 'mull'))
                    n += bool(c['ldu'] and prev & (r_all if c['ldu'] == 'all' else r_mul))
                    n += c['asset_extra'] * (pc in SAMPLE_LOADS)
                    prev = loaded(d) if res else set()
            row.append(n)
        print('%-34s %5d ' % (name, len(pcs)) + ' '.join('%7d' % x for x in row))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('game', nargs='?', help='.a78 with its ARSC block, or a bare ARSC block')
    ap.add_argument('--song', type=int, default=13)
    ap.add_argument('--secs', type=float, default=4.0)
    ap.add_argument('--synth', choices=('loop', 'oneshot', 'reverse'), help='16 synthetic voices, song 0')
    ap.add_argument('--run', nargs='+', default=DEFAULT_RUN, help='CORE/ASSET pairs (default: %(default)s)')
    ap.add_argument('--batches', help='write the clocks of every batch here (CSV)')
    ap.add_argument('--loops', action='store_true', help='print the mixer loops\' clocks per iteration')
    a = ap.parse_args()
    if a.loops:
        loops()
        return
    if not a.game and not a.synth:
        ap.error('give GAME, --synth or --loops')
    t0 = time.time()
    pairs = [Pair(n) for n in a.run]
    block = synth_arsc.build(16, a.synth) if a.synth else load_asset(a.game)
    m = Timed(block, pairs)
    nboot = boot(m)
    print('boot: %d instructions; ' % nboot + ', '.join('%s %d' % (p.name, p.now) for p in pairs) + ' clocks')
    m.track = True
    m.p.command(0x80 | (0 if a.synth else a.song))

    def on_batch(m, rec):
        for p in pairs:
            p.clocks.append(p.now - p.mark)
            p.mark = p.now
    recs = render(m, int(round(a.secs * 240)), on_batch=on_batch)
    print('%s, ' % ('16 voices, %s' % a.synth if a.synth else 'song %d' % a.song), end='')
    report(recs, pairs, m.cls_count, a.synth)
    if a.batches:
        with open(a.batches, 'w') as f:
            f.write('instructions,frames,' + ','.join(p.name for p in pairs) + '\n')
            for i, (n, fr) in enumerate(recs):
                f.write('%d,%d,' % (n, fr) + ','.join(str(p.clocks[i]) for p in pairs) + '\n')
    print('%.0f s' % (time.time() - t0))


if __name__ == '__main__':
    sys.exit(main())
