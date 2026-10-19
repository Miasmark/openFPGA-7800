#!/usr/bin/env python3
"""Reference model of the LPC2103 MAM (UM10161 chapter 4) on the ARM bus
stream that tb_daria sees, for checking the bench's +mam estimator: the
bench's Python twin (mam_check.py runs it on a +mamtrace file). It shares
the bench's reading of the manual; mymam.py is the independent model.

Input: an event stream, one call at a time, as a list of events:
  ('A', kind, addr, size, seq)   a bus access the core made, in order;
                                 kind 'F' fetch, 'R' data read, 'W' data write;
                                 seq 1 = S cycle, 0 = N cycle (mem_seq)
  ('I', n)                       n internal cycles (the retired instruction's
                                 I cycles, placed at its retire)
Configuration: mode (1 or 2), T (MAMTIM, 1..7), noabort (an instruction
fetch that misses waits for an in-flight prefetch instead of aborting it),
addrseq (classify a fetch as sequential by its address, not its S/N cycle).

Model (docs/HARMONY_MODEL.md; the bench's "MAM timing estimate" block):
  * a flash read takes T cycles: an access that starts one at time t ends at
    t+T (T-1 wait states); a latch hit takes 1 cycle;
  * three 16-byte latches: prefetch buffer (PB), branch trail (BT), data (DB);
  * after the instruction stream enters line L (by a hit, a capture or a
    flash read), the MAM prefetches line L+1 (unless that prefetch is already
    pending); a prefetch started at s is ready at s+T and is captured into PB
    when the core fetches from that line (waiting until s+T if needed); the
    next prefetch starts at the capture;
  * mode 2: an instruction fetch hitting PB or BT, or a data read hitting DB,
    takes 1 cycle; mode 1: a non-sequential instruction fetch, and every flash
    data read, costs a full flash read even when the line is latched;
  * an instruction fetch that misses (and is not the pending prefetch) starts a
    flash read at once, aborting an in-flight prefetch (noabort: waits for it);
    the line goes to BT if the fetch is non-sequential, to PB if sequential;
  * a flash data read aborts an in-flight prefetch (a completed, uncaptured one
    is lost too) and the prefetch restarts when the data read ends;
  * SRAM (0x4xxxxxxx) and MMIO take no waits; a fetch outside ROM and RAM
    (the return sentinel, standing for the driver's code in flash) costs one
    non-sequential flash read with nothing latched.
Returns per access the wait states and a category:
  br  non-sequential fetch whose address is not the next one (branch target)
  ns  non-sequential (N) fetch at the next address (after a data access)
  sx  sequential fetch into another line (line crossing)
  si  sequential fetch inside the current line
  dr  flash data read
  ot  other (sentinel)

Run on its own, it reads a tb_daria +mamraw dump and prints each call's
waits in the four primary configurations:
  python3 -I mam_model.py mamraw.txt
SPDX-License-Identifier: MIT
"""


class Mam:
    """One MAM configuration. Times are ARM7 cycles from the call's first
    access; `now` is the cycle the current access starts in."""

    def __init__(self, mode, T, noabort=False, addrseq=False, rom_size=32768, keep_done_pf=False):
        self.mode, self.T, self.noabort, self.addrseq = mode, T, noabort, addrseq
        self.rom_size = rom_size
        # sensitivity variant (not in the bench): a completed, not yet captured
        # prefetch survives a flash data read (only one in flight restarts)
        self.keep_done_pf = keep_done_pf
        self.reset()

    def warm_restart(self):
        """Sensitivity variant: start the next call with the latches as the
        last call left them (a pending prefetch has completed), time at 0."""
        self.now = 0
        self.fb = 0
        if self.pf is not None:
            self.pf = (self.pf[0], -self.T)
        self.last_ia = None

    def reset(self):
        self.now = 0
        self.pb = self.bt = self.db = None
        self.pf = None            # pending prefetch (line, start); ready at start + T
        self.fb = 0               # flash busy until (a read that is not aborted)
        self.cur = None           # line of the last fetch from flash (shared by all configs)
        self.last_ia = None       # address after the last instruction fetch

    def _drop_pf(self):
        """Forget the pending prefetch; with noabort, one in flight still
        holds the flash until it completes."""
        if self.pf is not None:
            if self.noabort and self.pf[1] <= self.now < self.pf[1] + self.T:
                self.fb = max(self.fb, self.pf[1] + self.T)
            self.pf = None

    def _iread(self, line, nonseq):
        """A flash read for an instruction fetch starting at self.now; returns
        the wait states. The next line's prefetch starts when it completes."""
        self._drop_pf()
        s = max(self.now, self.fb)
        w = s + self.T - self.now - 1
        if nonseq:
            self.bt = line
        else:
            self.pb = line
        self.fb = s + self.T
        self.pf = (line + 1, s + self.T)
        return w

    def access(self, kind, addr, size, seq):
        T = self.T
        w, cat = 0, None
        if kind == 'F':
            nxt = self.last_ia
            self.last_ia = addr + (2 if size == 1 else 4)
            if addr < self.rom_size:
                line = addr >> 4
                cur = self.cur
                self.cur = line
                s = (addr == nxt) if self.addrseq else bool(seq)
                if nxt is None or addr != nxt:
                    cat = 'br'
                elif not seq:
                    cat = 'ns'
                elif line != cur:
                    cat = 'sx'
                else:
                    cat = 'si'
                if self.mode == 1 and not s:
                    w = self._iread(line, True)
                elif line == self.pb or line == self.bt:
                    if line != cur and not (self.pf is not None and self.pf[0] == line + 1):
                        self._drop_pf()
                        self.pf = (line + 1, max(self.now, self.fb))
                elif self.pf is not None and self.pf[0] == line:
                    ready = self.pf[1] + T
                    w = max(0, ready - self.now - 1)
                    self.pb = line
                    self.pf = (line + 1, max(self.now, ready))
                else:
                    w = self._iread(line, not s)
            elif (addr >> 28) in (4, 0xE):
                pass
            else:
                # the return sentinel: the driver's code in flash, one
                # non-sequential read of a line nothing holds
                cat = 'ot'
                w = self._iread(-100, True)
        elif kind == 'R' and addr < self.rom_size:
            cat = 'dr'
            line = addr >> 4
            if not (self.mode == 2 and line == self.db):
                w = T - 1
                self.db = line
                self.fb = self.now + T
                if self.pf is not None and not (self.keep_done_pf and self.pf[1] + T <= self.now):
                    self.pf = (self.pf[0], self.now + T)
        self.now += 1 + w
        return w, cat

    def icycles(self, n):
        self.now += n


# -------------------------------------------------- instruction classes
def thumb_kind(i):
    if (i >> 13) == 0 and ((i >> 11) & 3) != 3:
        return 'T1'
    if (i >> 11) == 0b00011:
        return 'T2'
    if (i >> 13) == 0b001:
        return 'T3'
    if (i >> 10) == 0b010000:
        op = (i >> 6) & 15
        if op == 0b1101:
            return 'T4_MUL'
        if op in (0b0010, 0b0011, 0b0100, 0b0111):
            return 'T4_SHIFTREG'
        return 'T4'
    if (i >> 10) == 0b010001:
        return 'T5_BX' if ((i >> 8) & 3) == 3 else 'T5'
    if (i >> 11) == 0b01001:
        return 'LOAD'
    if (i >> 12) == 0b0101:
        if not (i >> 9) & 1:
            return 'LOAD' if (i >> 11) & 1 else 'STORE'
        return 'STORE' if ((i >> 10) & 3) == 0 else 'LOAD'
    if (i >> 13) == 0b011:
        return 'LOAD' if (i >> 11) & 1 else 'STORE'
    if (i >> 12) == 0b1000:
        return 'LOAD' if (i >> 11) & 1 else 'STORE'
    if (i >> 12) == 0b1001:
        return 'LOAD' if (i >> 11) & 1 else 'STORE'
    if (i >> 12) == 0b1010:
        return 'T12'
    if (i >> 8) == 0b10110000:
        return 'T13'
    if (i >> 12) == 0b1011 and ((i >> 9) & 3) == 2:
        return 'POP' if (i >> 11) & 1 else 'PUSH'
    if (i >> 12) == 0b1100:
        return 'POP' if (i >> 11) & 1 else 'PUSH'
    return 'OTHER'


def arm_icycles(i):
    if (i & 0x0fc000f0) == 0x00000090:
        return 2                        # MUL/MLA, m = 2 as est_arm7
    if (i & 0x0f8000f0) == 0x00800090:
        return 3
    if (i & 0x0fb00ff0) == 0x01000090:
        return 1                        # SWP
    if (i & 0x0ffffff0) == 0x012fff10:
        return 0
    if (i & 0x0e000090) == 0x00000090:
        return 1 if (i >> 20) & 1 else 0
    if (i & 0x0fbf0fff) == 0x010f0000 or (i & 0x0db0f000) == 0x0120f000:
        return 0
    c = (i >> 25) & 7
    if c == 0:
        return 1 if (i >> 4) & 1 else 0
    if c in (2, 3, 4):
        return 1 if (i >> 20) & 1 else 0
    return 0


def icycles(ins, thumb):
    if not thumb:
        return arm_icycles(ins)
    k = thumb_kind(ins & 0xFFFF)
    return {'T4_MUL': 2, 'T4_SHIFTREG': 1, 'LOAD': 1, 'POP': 1}.get(k, 0)


def read_raw(path, ncalls=None):
    """tb_daria +mamraw dump -> list of calls, each a list of events."""
    calls, cur = [], []
    with open(path) as f:
        for ln in f:
            p = ln.split()
            if p[1] == 'A':
                cur.append(('A', p[2], int(p[3], 16), int(p[4]), int(p[5])))
            elif p[1] == 'R':
                cur.append(('I', icycles(int(p[3], 16), p[4] == '1')))
            elif p[1] == 'END':
                calls.append(cur)
                cur = []
                if ncalls and len(calls) >= ncalls:
                    break
    return calls


def run_call(ev, cfg, rom_size=32768):
    m = Mam(*cfg, rom_size=rom_size)
    waits = []
    for e in ev:
        if e[0] == 'A':
            waits.append(m.access(e[1], e[2], e[3], e[4]))
        else:
            m.icycles(e[1])
    return waits, m


if __name__ == '__main__':
    import sys
    calls = read_raw(sys.argv[1])
    for ci, ev in enumerate(calls):
        nacc = sum(1 for e in ev if e[0] == 'A')
        ni = sum(e[1] for e in ev if e[0] == 'I')
        out = ['call %d acc %d I %d zw-1 %d' % (ci + 1, nacc, ni, nacc + ni - 1)]
        for cfg in ((1, 3), (1, 4), (2, 3), (2, 4)):
            w, m = run_call(ev, cfg)
            out.append('m%dt%d +%d' % (cfg[0], cfg[1], sum(x[0] for x in w)))
        print(' '.join(out))
