#!/usr/bin/env python3
"""Independent LPC2103 MAM wait-state model, written from UM10161 ch.4 only,
apart from the bench's code (the bench's own twin is mam_model.py).

Input: the C/A/E rows of a tb_daria +mamtrace file, plain or .gz (only access
type, address, S/N, region, category and ibefore are used; the trace's own
wait columns are only read for comparison). mymam_check.py compares it with
the bench access for access; variants.py runs other readings of the manual.

Timing convention: every bus access takes 1 cycle plus w wait cycles.  A flash
read started in cycle s delivers its line at the end of cycle s+M-1 (M=MAMTIM)
and the flash can start the next read in cycle s+M.  A demand miss presented in
cycle t with the flash free costs w = M-1.
SPDX-License-Identifier: MIT
"""
import gzip
import sys


class Cfg:
    def __init__(self, name, mode, M, seq_by='cyc', imiss_abort=True,
                 mimic_uses_flash=True, data_loses_done_pf=True,
                 pf_on_capture='t', pf_skip_if_buffered=False,
                 n_hit_mode1='mimic', cmpidx=None, nseq_capture_bt=False,
                 warm=False):
        self.nseq_capture_bt = nseq_capture_bt
        self.warm = warm
        self.cmpidx = cmpidx
        self.name = name
        self.mode = mode
        self.M = M
        self.seq_by = seq_by              # 'cyc' bus S/N, 'addr' address
        self.imiss_abort = imiss_abort    # instruction miss aborts prefetch
        self.mimic_uses_flash = mimic_uses_flash  # mode1 mimicked latch hit is a real flash op
        self.data_loses_done_pf = data_loses_done_pf
        self.pf_on_capture = pf_on_capture  # 't' or 't+1'
        self.pf_skip_if_buffered = pf_skip_if_buffered
        self.n_hit_mode1 = n_hit_mode1


class MAM:
    def __init__(self, c):
        self.c = c
        self.reset()

    def reset(self):
        self.PB = None
        self.BT = None
        self.DB = None
        self.cur = None          # line of last instruction fetch
        self.last_fa = None      # last fetch address
        self.last_fsz = None
        self.pf = None           # [line, start]
        self.hard = -10**9

    # -- helpers -----------------------------------------------------------
    # self.hard: first cycle the flash is free of demand/data reads (these
    # cannot be cancelled).  A prefetch [line, s] occupies cycles s..s+M-1;
    # one that has not started yet (s > t) is cancelled for free.
    def pf_done(self):
        return self.pf[1] + self.c.M - 1

    def start_pf(self, line, at):
        c = self.c
        if c.pf_skip_if_buffered and line in (self.PB, self.BT):
            self.pf = None
            return
        self.pf = [line, max(at, self.hard)]

    def clear_pf(self, t):
        """Something other than capturing the prefetched line needs the flash
        at cycle t (or the prefetch is retargeted); returns the first cycle
        the flash can start the new read."""
        if self.pf is None:
            return max(t, self.hard)
        s, d = self.pf[1], self.pf_done()
        self.pf = None
        if d < t or s > t:      # completed (discarded) or not started
            return max(t, self.hard)
        if self.c.imiss_abort:  # in flight: abort
            return max(t, self.hard)
        self.hard = max(self.hard, d + 1)   # in flight: it keeps the flash
        return d + 1                         # until it completes

    def demand_read(self, t):
        s = self.clear_pf(t)
        self.hard = s + self.c.M
        return s

    # -- accesses ------------------------------------------------------------
    def fetch(self, t, a, size, cyc):
        c = self.c
        M = c.M
        L = a >> 4
        fsz = 4 if size == 2 else 2
        if c.seq_by == 'cyc':
            seq = (cyc == 'S')
        else:
            seq = (self.last_fa is not None and a == self.last_fa + self.last_fsz)
        self.last_fa, self.last_fsz = a, fsz
        entering = (L != self.cur)
        self.cur = L
        inbuf = L in (self.PB, self.BT)

        if c.mode == 1 and not seq:
            # non-sequential instruction fetch: always flash-read timing
            if inbuf and not c.mimic_uses_flash:
                w = M - 1
                if entering and (self.pf is None or self.pf[0] != L + 1):
                    self._retarget(t, L + 1)
                return w
            s = self.demand_read(t)
            w = s + M - 1 - t
            self.BT = L
            self.start_pf(L + 1, s + M)
            return w

        if inbuf:
            if entering and (self.pf is None or self.pf[0] != L + 1):
                self._retarget(t, L + 1)
            return 0

        if self.pf is not None and self.pf[0] == L:
            d = self.pf_done()
            w = max(0, d - t)
            if c.nseq_capture_bt and cyc == 'N':
                self.BT = L
            else:
                self.PB = L
            self.pf = None
            if w > 0:
                nxt = d + 1
            else:
                nxt = t if c.pf_on_capture == 't' else t + 1
            nxt = max(nxt, d + 1)   # flash busy with this prefetch through cycle d
            self.start_pf(L + 1, nxt)
            return w

        # miss
        s = self.demand_read(t)
        w = s + M - 1 - t
        if seq:
            self.PB = L
        else:
            self.BT = L
        self.start_pf(L + 1, s + M)
        return w

    def _retarget(self, t, line):
        """Fetch stream entered a buffered line; prefetch should be `line`."""
        s0 = self.clear_pf(t)
        self.start_pf(line, s0)

    def data_read(self, t, a):
        c = self.c
        M = c.M
        L = a >> 4
        if c.mode == 2 and self.DB == L:
            return 0
        if c.mode == 1 and self.DB == L and not c.mimic_uses_flash:
            return M - 1
        # real flash data read at t: aborts/loses prefetch, re-initiates after
        re = None
        if self.pf is not None:
            d = self.pf_done()
            if d >= t or c.data_loses_done_pf:
                re = self.pf[0]
                self.pf = None
        self.hard = t + M
        self.DB = L
        if re is not None:
            self.start_pf(re, t + M)
        return M - 1


def run(path, cfgs, ncalls=None):
    """Returns {call: (theirs_list, mine_list, est)} ."""
    res = {}
    models = [MAM(c) for c in cfgs]
    t = [0] * len(cfgs)
    mine = None
    theirs = None
    call = None
    acc_rows = []
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rt') as f:
        for line in f:
            if line.startswith('#'):
                continue
            p = line.split()
            if not p:
                continue
            k = p[0]
            if k == 'C':
                call = int(p[1])
                for i, m in enumerate(models):
                    if cfgs[i].warm and mine is not None:
                        # keep latches; flash idle and time restarted
                        m.pf = None
                        m.hard = -10**9
                        m.cur = None
                        m.last_fa = None
                    else:
                        m.reset()
                t = [0] * len(cfgs)
                mine = [0] * len(cfgs)
                theirs = [0] * 10
                diffs = []
            elif k == 'A':
                opx, addr, size, cyc, region, cat = p[2], int(p[3], 16), int(p[4]), p[5], p[6], p[7]
                ib = int(p[8])
                tw = [int(x) for x in p[9:19]]
                for i in range(10):
                    theirs[i] += tw[i]
                for i, m in enumerate(models):
                    t[i] += ib
                    if region == 'rom':
                        if opx == 'F':
                            w = m.fetch(t[i], addr, size, cyc)
                        elif opx == 'R':
                            w = m.data_read(t[i], addr)
                        else:
                            w = 0
                    elif region in ('oth', 'mmio'):
                        # the return sentinel stands for driver code in flash:
                        # a non-sequential read of a line nothing holds
                        w = m.demand_read(t[i]) + cfgs[i].M - 1 - t[i] if region == 'oth' else 0
                    else:
                        w = 0
                    mine[i] += w
                    t[i] += 1 + w
                    if cfgs[i].cmpidx is not None and w != tw[cfgs[i].cmpidx]:
                        diffs.append((i, int(p[1]), opx, p[3], cyc, cat, w, tw[cfgs[i].cmpidx]))
            elif k == 'E':
                ew = [int(x) for x in p[8:18]]
                assert ew == theirs, (call, ew, theirs)
                res[call] = (list(theirs), list(mine), int(p[7]), diffs)
                if ncalls and call >= ncalls:
                    break
    return res
