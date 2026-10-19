#!/usr/bin/env python3
"""Directed tests for tb_daria's +mam estimator (docs/HARMONY_MODEL.md).

Synthetic CDFJ images built with E2's tools (mkimg/armenc/asm6502 from
../fe_dir; no game data): the 6507 writes $FF (or $FE)
to CALLFN once a frame; the ARM call at the entry $0808 is
    $0808 MOVS r0,#N ; $080A B start ; <test loop at start> ; BX LR
Each test runs with two loop counts N1 < N2; every call starts with the MAM
cold, so the difference of a call's wait states between the two images is
(N2 - N1) x the per-iteration waits worked out by hand below (steady state).
TA is also checked absolutely (prologue and epilogue included).

Per-iteration waits, by hand, configurations in the bench's order
  m1t3 m1t4 m2t3 m2t4 | m1t3_na m1t4_na m2t3_na m2t4_na | m1t3_as m1t4_as
(mode, MAMTIM; _na: an instruction miss waits for an in-flight prefetch;
_as: mode 1 with "sequential" from the address). Notation: T = MAMTIM; a
flash read started at s ends at s+T (T-1 waits); "pf X@t" = prefetch of line
X started at t, ready at t+T.

TA one-line loop: $840 SUBS r0,#1 ; $842 BNE $840 ; $844 BX LR.
  Per iteration: fetch $846 (BNE's own), N $840 (refill), S $842, S $844.
  Mode 2: line $84 is in BT after the first entry: 0. Mode 1: the N fetch
  costs a flash read: T-1. _na, mode 1: the forced read at s ends s+T, pf $85@s+T;
  the next N fetch is at s+T+3, inside that prefetch iff T > 3: T=3: 2,
  T=4: waits to s+2T, then T: 2T+T-(T+3)-1 = 4. _as: the N fetch is a
  branch target, not sequential by address either: T-1.
  -> [2,3,0,0, 2,4,0,0, 2,3]
  Absolute, N=4 (4N+6 accesses, est 4N+5): N $808 T-1; S $80A/$80C/$80E hit;
  N $840 T-1 (mode 2: a miss; prefetch $81 aborted); N-1 taken BNEs (mode 1:
  T-1 each); BX's fetch $848 hit; the sentinel T-1. m1: (N+2)(T-1), m2:
  3(T-1). _na T=4: $840 comes 3 cycles into pf $81 (4..8): 4; each BNE 4;
  sentinel 3: 4N+6 = 22; m2t4_na: 3+4+3 = 10; T=3: no prefetch in flight.
  -> [12,18,6,9, 12,22,6,10, 12,18]
TB loop crossing a line: $88C SUBS ; $88E NOP ; $890 NOP ; $892 BNE $88C.
  Mode 2: BT=$88, PB=$89 in steady state: 0. Mode 1: N $88C T-1, S $890 hits
  PB: T-1. _na mode 1: read of $88C ends e, pf $89@e; $890 at e+1 hits PB
  and re-aims to $8A, but pf $89 holds the flash to e+T; pf $8A@e+T, in
  flight at the N $88C at e+5 (to e+2T): read from e+2T: 3T-6 -> 3, 6.
  -> [2,3,0,0, 3,6,0,0, 2,3]
TC three-line loop (BT hit while PB holds another line): $8C0 SUBS, 16 NOPs,
  $8E2 BNE $8C0. Mode 2: the target line $8C hits BT (PB holds $8E); the
  prefetches of $8D and $8E start at the hit / capture and are ready 8 fetches
  later: 0. Mode 1: T-1 (the N fetch). _na: the pending prefetch ($8F) has
  completed before the N fetch (4 cycles after it started, T <= 4): same.
  -> [2,3,0,0, 2,3,0,0, 2,3]
TD sequential LDRs from a ROM table: r2 = $0C00; $900 LDR r1,[r2,#0],
  [#4] ... [#28] (8 LDRs, table lines $C0 and $C1), $910 SUBS, $912 BNE $900.
  Mode 2: DB misses on $C00 and $C10 only: 2(T-1); the target line is in BT
  and $91 in PB. Mode 1: every data read is a flash read (8), plus the N
  fetch: 9(T-1). _na T=4: the last data read (at d) restarts pf $92@d+T;
  the N $900 comes at d+T+3, in flight: 2T-4+... = 4 instead of 3: 8*3+4 = 28.
  -> [18,27,4,6, 18,28,4,6, 18,27]
TE a flash data read just before a line crossing (it aborts and restarts the
  prefetch): $940 SUBS ; $942 LDR r1,[r2,#0] ($C00) ; NOPs ; $95A LDR r1,
  [r2,#16] ($C10; its own fetch is $95E) ; $95C NOP (fetch $960: the crossing)
  ; $95E NOP ; $960 NOP ; $962 BNE $940. Mode 2: two DB misses 2(T-1); the
  second (at d) restarts pf $96@d+T, ready d+2T; I cycle; fetch $960 at
  d+T+1: waits T-2. Total 3T-4. Mode 1: plus the N fetch T-1: 4T-5. _na
  mode 1, T=4: the N $940 comes 3 cycles after pf $97 started: 4 not 3.
  -> [7,11,5,8, 7,12,5,8, 7,11]
TG N fetch after a store: $980 SUBS ; $982 STR r1,[r3,#0] (r3 = SRAM) ;
  $984 BNE $980. The fetch after the store (BNE's own, $988) is an N cycle.
  Mode 2: all hits: 0. Mode 1: N $980 and N $988 are flash reads: 2(T-1).
  _as: $988 is sequential by address: T-1. _na mode 1: $988's read (at s1,
  T <= 4: no prefetch in flight) ends s1+T, pf $99@s1+T; N $980 at s1+T
  waits for it: 2T-1. (T-1)+(2T-1) = 3T-2.
  -> [4,6,0,0, 7,10,0,0, 2,3]
TH two far targets, each a miss (no prefetch can help): $9C0 B $A00 ;
  $A00 SUBS ; $A02 BNE $9C0 ; $A04 BX LR. Both N fetches miss in both
  modes: 2(T-1). _na: $A00 is fetched 2 cycles after pf $9D started: waits
  to its end, 2T-3; $9C0 is fetched 3 cycles after pf $A1 started: T=3 none
  (T-1 = 2), T=4: 2T-4 = 4. T=3: 3+2, T=4: 5+4.
  -> [4,6,4,6, 5,9,5,9, 4,6]
TI branch target on a line's last halfword, 3-line loop: $A8E SUBS ;
  9 NOPs ; $AA2 BNE $A8E. Mode 2: BT hit on $A8 re-aims the prefetch to $A9
  at t0; S $A90 at t0+1 waits T-2. Mode 1: the N fetch T-1, then S $A90
  right at the read's end, pf $A9 just started: T-1. -> [4,6,1,2, 4,6,1,2, 4,6]
TF (cfn): TA with CALLFN $FE (checks the cfn column only; waits as TA).

  python3 -I dirtests.py IMGDIR      writes <test>_n<N>.bin for N1 and N2
SPDX-License-Identifier: MIT
"""
import os
import sys

FE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fe_dir')
sys.path.insert(0, FE_DIR)
import mkimg      # noqa: E402
import armenc     # noqa: E402

NAMES = ['m1t3', 'm1t4', 'm2t3', 'm2t4', 'm1t3_na', 'm1t4_na', 'm2t3_na', 'm2t4_na', 'm1t3_as', 'm1t4_as']


class Asm:
    """armenc.Code with a known pc (Thumb halfwords only) and org()."""

    def __init__(self, base):
        self.c = armenc.Code(base)
        self.pc = base

    def org(self, addr):
        assert addr >= self.pc and addr % 2 == 0, (hex(addr), hex(self.pc))
        while self.pc < addr:
            self.nop()

    def __getattr__(self, name):
        fn = getattr(self.c, name)

        def wrap(*a):
            if name != 'label':
                self.pc += 2
            return fn(*a)
        return wrap

    def raw(self, hw):
        self.c.h(lambda pc, L, hw=hw: hw)
        self.pc += 2


def mov_imm(a, rd, value):
    """rd = value (value = imm8 << shift) without a literal pool."""
    for sh in range(0, 25):
        if value >> sh << sh == value and (value >> sh) < 256:
            a.movs(rd, value >> sh)
            if sh:
                a.lsls(rd, rd, sh)
            return
    raise ValueError(hex(value))


def body_TA(a):
    a.org(0x840)
    a.label('loop'); a.subsi(0, 1); a.bc('ne', 'loop'); a.bx(14)


def body_TB(a):
    a.org(0x88C)
    a.label('loop'); a.subsi(0, 1); a.nop(); a.nop(); a.bc('ne', 'loop'); a.bx(14)


def body_TC(a):
    a.org(0x8C0)
    a.label('loop'); a.subsi(0, 1)
    for _ in range(16):
        a.nop()
    assert a.pc == 0x8E2
    a.bc('ne', 'loop'); a.bx(14)


def body_TD(a):
    a.org(0x8F0)
    mov_imm(a, 2, 0x0C00)
    a.b('loop')
    a.org(0x900)
    a.label('loop')
    for k in range(8):
        a.ldr(1, 2, 4 * k)
    assert a.pc == 0x910
    a.subsi(0, 1); a.bc('ne', 'loop'); a.bx(14)


def body_TE(a):
    a.org(0x930)
    mov_imm(a, 2, 0x0C00)
    a.b('loop')
    a.org(0x940)
    a.label('loop'); a.subsi(0, 1); a.ldr(1, 2, 0)
    a.org(0x95A)
    a.ldr(1, 2, 16); a.nop(); a.nop(); a.nop()
    assert a.pc == 0x962
    a.bc('ne', 'loop'); a.bx(14)


def body_TG(a):
    a.org(0x970)
    mov_imm(a, 3, 0x40000000)
    mov_imm(a, 4, 0x1000)
    a.addsr(3, 3, 4)            # r3 = $40001000 (SRAM, display data area)
    a.b('loop')
    a.org(0x980)
    a.label('loop'); a.subsi(0, 1); a.str_(1, 3, 0); a.bc('ne', 'loop'); a.bx(14)


def body_TH(a):
    a.org(0x9C0)
    a.label('loop'); a.b('far')
    a.org(0xA00)
    a.label('far'); a.subsi(0, 1); a.bc('ne', 'loop'); a.bx(14)


def body_TI(a):
    a.org(0xA8E)
    a.label('loop'); a.subsi(0, 1)
    for _ in range(9):
        a.nop()
    assert a.pc == 0xAA2
    a.bc('ne', 'loop'); a.bx(14)


TESTS = {
    # name: (body, start label address, per-iteration expectation, cfn)
    'TA': (body_TA, 0x840, [2, 3, 0, 0, 2, 4, 0, 0, 2, 3], 0xFF),
    'TB': (body_TB, 0x88C, [2, 3, 0, 0, 3, 6, 0, 0, 2, 3], 0xFF),
    'TC': (body_TC, 0x8C0, [2, 3, 0, 0, 2, 3, 0, 0, 2, 3], 0xFF),
    'TD': (body_TD, 0x8F0, [18, 27, 4, 6, 18, 28, 4, 6, 18, 27], 0xFF),
    'TE': (body_TE, 0x930, [7, 11, 5, 8, 7, 12, 5, 8, 7, 11], 0xFF),
    'TG': (body_TG, 0x970, [4, 6, 0, 0, 7, 10, 0, 0, 2, 3], 0xFF),
    'TH': (body_TH, 0x9C0, [4, 6, 4, 6, 5, 9, 5, 9, 4, 6], 0xFF),
    'TI': (body_TI, 0xA8E, [4, 6, 1, 2, 4, 6, 1, 2, 4, 6], 0xFF),
    'TF': (body_TA, 0x840, [2, 3, 0, 0, 2, 4, 0, 0, 2, 3], 0xFE),
}
ABS = {('TA', 4): [12, 18, 6, 9, 12, 22, 6, 10, 12, 18]}
# per-iteration waits by category for the primary grid (m1t3, m1t4, m2t3, m2t4)
CATS = {
    'TA': {'br': [2, 3, 0, 0]},
    'TD': {'br': [2, 3, 0, 0], 'dr': [16, 24, 4, 6]},
    'TE': {'br': [2, 3, 0, 0], 'dr': [4, 6, 4, 6], 'sx': [1, 2, 1, 2]},
    'TG': {'br': [2, 3, 0, 0], 'ns': [2, 3, 0, 0]},
    'TI': {'br': [2, 3, 0, 0], 'sx': [2, 3, 1, 2]},
}
N1, N2 = 4, 8


class MImg(mkimg.Img):
    def __init__(self, arm_code):
        super().__init__('cdf', rev=2)
        self.arm_code = arm_code

    def _driver(self):
        for i in range(3):
            self.put32(0x0010 + 4 * i, 0x4A464443, 'sig')      # "CDFJ" x3: CDFJ, entry $0808
        self.put(self.entry, self.arm_code, 'arm')


def build(name, n, outdir):
    body, start, _, cfn = TESTS[name]
    a = Asm(0x0808)
    a.movs(0, n)
    a.b('start')
    a.org(start)
    a.label('start')
    body(a)
    code, labs = a.c.build()
    img = MImg(code)
    img.program(6, init='', body="""
        LDA #$%02X
        STA CALLFN
        INC M_DONE
""" % cfn)
    rom = img.build()
    # the table the LDR tests read
    rom = bytearray(rom)
    for k in range(64):
        rom[0x0C00 + 4 * k:0x0C04 + 4 * k] = ((0x11111111 * (k + 1)) & 0xFFFFFFFF).to_bytes(4, 'little')
    assert mkimg.classify(bytes(rom)) == (23, 2), mkimg.classify(bytes(rom))
    p = os.path.join(outdir, '%s_n%d.bin' % (name, n))
    with open(p, 'wb') as f:
        f.write(rom)
    return p


if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name in TESTS:
        for n in (N1, N2):
            print(build(name, n, out))
