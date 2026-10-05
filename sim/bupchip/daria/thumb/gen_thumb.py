#!/usr/bin/env python3
"""Random Thumb test for DARIA (docs/DARIA_CORE.md, "The CPU: Thumb",
"Verification", the "Random streams" row), as assembler on stdout.

  gen_thumb.py SEED [OPS] > T.S      OPS operations (default 300)
  gen_thumb.py --image OUT.a78        the image the tests run with: a blank
                                      cartridge and 4 KiB of asset bytes

The same SEED and OPS always give the same program. run_random.sh links it
with verif/isa/link.ld, runs it on the reference (tb_ref_trace.sv) and on
Unicorn (thumb_iss.py), compares the RAM, then runs DARIA in lockstep.

Layout. An ARM start-up fills RAM from a ROM table, sets SP and random NZCV
and BXes into the Thumb body, which loads the registers from the table
(LDMIA r0, {r0-r7}: the base in the list). The body is OPS operations,
weighted like the demos' traced mix: data processing ~40% (F1-F5, F12, F13,
MUL with Rd = Rm among them, and the flag corners of "What the reference
does"), single loads ~22% and stores ~10% (F6-F11, every size and sign,
from the ROM table, the code, RAM, the stack and the asset window, mostly
near a pointer a register already holds), conditional branches ~15% (skips,
if/else, flag captures), B ~7% (over dead code, literal pools and
functions), BL ~2% (leaf functions placed before and after the call,
returning with BX LR, MOV PC, POP {pc} or POP + BX), BX ~1% (to Thumb
labels through low and high registers, BX PC into inline ARM code, calls
into ARM functions through a BX veneer, which may call Thumb back with
MOV LR, PC + BX), computed jumps (MOV pc, ADD pc, POP {pc}), PUSH/POP and
LDMIA/STMIA. thumb_iss.py --cover prints the mix that results.

Signature. Every 10-20 operations the low registers written since the last
dump go to the signature, mostly with STMIA rS!, else one STR each;
sometimes r8-r12, SP and LR too (moved through the low registers, which
LDMIA t, {..., t, ...} then reloads). A flag capture is a Bcc over a
STR rS, [rS, #k] to a fresh word, so the word is rS or 0. The end dumps
every register, captures every condition, reads IDENT and writes the
FAULT register (0xE000901C) with 0xAA, from Thumb or from ARM.

Memory: ROM 0-0x3FFF (the table at 0x20, then the code), RAM 0x40000000:
the signature (8 KiB), the data area at 0x40002000 (1 KiB), the stack
area 0x40003400-0x40003BFF (SP between 0x40003600 and 0x40003800, so
LDR/STR [SP, #1020] stays inside it); the assets at 0x02000000 (4 KiB).
run_random.sh compares all 16 KiB of RAM, so every store is checked.

Kept inside the subset where ARMv4T (the reference, DARIA) and ARMv5TE
(Unicorn's ARM926) agree, and where DARIA runs rather than halts:
  - branches go forward only, so every program ends; calls are not recursive;
  - no read of C (Bcc CS/CC/HI/LS, ADC, SBC; in ARM code also those
    conditions, ADC/SBC/RSC and RRX) after a Thumb MUL until an instruction
    that surely writes C (DARIA halts with code 8; the reference's C after
    MUL is its multiplier's);
  - POP {pc} only of odd values (ARMv5 would switch to ARM on an even one);
    functions called from ARM return with BX;
  - BX PC only from a word-aligned address; no lone BL halves;
  - word accesses aligned, halfword accesses even (LDRB/LDRSB/STRB any);
  - STMIA with the base in the list only when it is the lowest register
    (QEMU stores the old base otherwise), LDMIA with the base in the list
    allowed (the loaded value wins on both);
  - F5 ADD/CMP/MOV always with a high register (H1 = H2 = 0 halts),
    ARM code inside ARIA's subset (no PC destinations, no MULS).
Register roles: one low register (per seed) is the signature pointer rS;
the other low registers, r8-r12 and LR are data; SP is the stack pointer.

SPDX-License-Identifier: MIT
"""
import random
import sys

M = 0xFFFFFFFF
SIG, SIG_SIZE = 0x40000000, 0x2000
DATA, DATA_SIZE = 0x40002000, 0x400
STK_LO, STK_HI = 0x40003400, 0x40003C00     # filled from the table
SP0, SP_MIN, SP_MAX = 0x40003800, 0x40003600, 0x40003800
ASSET, ASSET_SIZE = 0x02000000, 0x1000
MMIO = 0xE0009000
RTAB, RTAB_WORDS = 0x20, 256                # ROM table, right after the vectors
CONDS = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]
CREAD = {"cs", "cc", "hi", "ls"}
F4OPS = ["ands", "eors", "lsls", "lsrs", "asrs", "adcs", "sbcs", "rors",
         "tst", "negs", "cmp", "cmn", "orrs", "bics", "mvns"]   # MUL: op_mul
SPECIAL = [0, 1, 2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFFFFFE, 0x80000001,
           31, 32, 33, 0xFF, 0x100, 0xFFFF, 0x10000, 0x55555555, 0xAAAAAAAA]
HI = [8, 9, 10, 11, 12]
# C state of a context: "known" (C may be read), "pass" (a function that
# has not touched C yet: its caller's), "unk" (a MUL since the last writer).
# Merging two paths takes the worse: unk > pass > known.
CRANK = {"known": 0, "pass": 1, "unk": 2}


def rn(r):
    return {13: "sp", 14: "lr", 15: "pc"}.get(r, f"r{r}")


def rlist(regs):
    return "{" + ", ".join(rn(r) for r in sorted(regs)) + "}"


def a78(assets):
    """A 128-byte A78 header, a 4 KiB cartridge of $FF, then the asset bytes
    (the layout of make_synth_arsc.py; the asset window starts after the
    cartridge)."""
    h = bytearray(128)
    h[0] = 3
    h[1:17] = b"ATARI7800".ljust(16, b"\0")
    h[17:49] = b"DARIA thumb random".ljust(32, b"\0")
    h[49:53] = (4096).to_bytes(4, "big")
    h[100:128] = b"ACTUAL CART DATA STARTS HERE"
    return bytes(h) + bytes([0xFF]) * 4096 + assets


class Ctx:
    """One stream of code: the Thumb main body, a Thumb function, or an ARM
    function. known holds the registers whose values the generator knows
    (pointers, small constants), written the registers it has written."""

    def __init__(self, kind, cstate):
        self.kind = kind
        self.lines = []
        self.pos = 0
        self.known = {}
        self.cstate = cstate
        self.written = set()
        self.depth = 0
        self.arm = kind == "arm"
        self.lit_first = None
        self.nlit = 0


class Func:
    def __init__(self, name, lines, size, clobber, cstate, arm_callable):
        self.name, self.lines, self.size = name, lines, size
        self.clobber, self.cstate, self.arm_callable = clobber, cstate, arm_callable
        self.placed = False


class Gen:
    def __init__(self, seed, nops):
        self.R = random.Random(seed)
        self.seed, self.nops = seed, nops
        self.rS = self.R.randrange(8)
        self.sp = SP0
        self.sig_used = 0           # bytes of the signature reserved
        self.sig_rbase = 0          # rS = SIG + sig_rbase
        self.nlab = 0
        self.funcs = []             # every function made (Thumb and ARM)
        self.pending = []           # blocks waiting for a dead region
        self.veneers = {}           # register -> veneer Func
        self.dirty = set()          # registers written since the last dump
        self.main = Ctx("main", "known")
        self.c = self.main

    # ---- emission -----------------------------------------------------------------
    def ins(self, s, size=2):
        self.c.lines.append("\t" + s)
        self.c.pos += size

    def hword(self, v, what):
        self.ins(f".hword\t{v:#06x}\t@ {what}")

    def lab(self, name):
        self.c.lines.append(f"{name}:")

    def raw(self, s, size=0):
        self.c.lines.append("\t" + s)
        self.c.pos += size

    def label(self, p="L"):
        self.nlab += 1
        return f"{p}{self.nlab}"

    def lit(self):
        if self.c.lit_first is None:
            self.c.lit_first = self.c.pos
        self.c.nlit += 1

    def ldr_lit(self, r, value, comment=""):
        """LDR r, =value (F6 in Thumb). value may be an expression string."""
        self.lit()
        v = value if isinstance(value, str) else f"{value & M:#010x}"
        self.ins(f"ldr\t{rn(r)}, ={v}{comment}", 4 if self.c.arm else 2)
        self.wr(r, value if isinstance(value, int) else None)

    def ltorg(self):
        if self.c.nlit:
            self.raw(".ltorg", 4 * self.c.nlit + 2)
        self.c.lit_first, self.c.nlit = None, 0

    def pool_due(self):
        c = self.c
        return c.lit_first is not None and (c.pos - c.lit_first) + 4 * c.nlit > 720

    # ---- state ----------------------------------------------------------------------
    def wr(self, r, v=None):
        if v is None:
            self.c.known.pop(r, None)
        else:
            self.c.known[r] = v & M
        self.c.written.add(r)
        if self.c is self.main:
            self.dirty.add(r)

    def kv(self, r):
        if r == 13 and self.c.kind == "main":
            return self.sp
        return self.c.known.get(r)

    def c_write(self):
        self.c.cstate = "known"

    def c_ok(self):
        return self.c.cstate == "known"

    def snapshot(self):
        return dict(self.c.known), self.c.cstate

    def merge(self, snap):
        """After a forward branch: keep what both paths agree on."""
        known0, cstate0 = snap
        self.c.known = {r: v for r, v in self.c.known.items() if known0.get(r) == v}
        if CRANK[cstate0] > CRANK[self.c.cstate]:
            self.c.cstate = cstate0

    def call_effect(self, f):
        for r in f.clobber:
            self.wr(r)
        self.wr(14)
        if f.cstate != "pass":
            self.c.cstate = f.cstate

    # ---- registers ----------------------------------------------------------------
    def data_lo(self):
        return [r for r in range(8) if r != self.rS]

    def is_ptr(self, r):
        v = self.c.known.get(r)
        return v is not None and (RTAB <= v < 0x4000 or ASSET <= v < ASSET + ASSET_SIZE or
                                  0x40000000 <= v < 0x40004000)

    def rd(self):
        """A destination: mostly not a register that holds a pointer, so
        bases live on, as compiled code keeps them."""
        regs = self.data_lo()
        free = [r for r in regs if not self.is_ptr(r)]
        return self.R.choice(free if free and self.R.random() < 0.75 else regs)

    def rs(self):
        return self.R.randrange(8)

    def hi_w(self):
        """High registers this context may write."""
        return HI + ([14] if self.c.kind == "main" else [])

    def hi_r(self):
        return HI + [13, 14, 15]

    # ---- data processing ------------------------------------------------------------
    def op_dp(self):
        k = self.R.random()
        if k < 0.15:
            self.f1()
        elif k < 0.30:
            self.f2()
        elif k < 0.46:
            self.f3()
        elif k < 0.78:
            self.f4()
        elif k < 0.92:
            self.f5()
        elif k < 0.97 or self.c.kind != "main" or self.c.depth:
            self.f12()
        else:
            self.f13()

    def f1(self):
        op = self.R.choice(["lsls", "lsrs", "asrs"])
        d, s = self.rd(), self.rs()
        if op == "lsls":
            n = 0 if self.R.random() < 0.12 else self.R.randrange(1, 32)
        else:
            n = 32 if self.R.random() < 0.15 else self.R.randrange(1, 32)
        v = self.kv(s)
        self.ins(f"{op}\t{rn(d)}, {rn(s)}, #{n}")
        self.wr(d, (v << n) if op == "lsls" and v is not None else None)
        if n:
            self.c_write()

    def f2(self):
        sub = self.R.random() < 0.5
        op = "subs" if sub else "adds"
        d, s = self.rd(), self.rs()
        vs = self.kv(s)
        if self.R.random() < 0.5:
            n = self.rs()
            vn = self.kv(n)
            self.ins(f"{op}\t{rn(d)}, {rn(s)}, {rn(n)}")
            v = None if vs is None or vn is None else (vs - vn if sub else vs + vn)
        else:
            imm = 0 if self.R.random() < 0.2 else self.R.randrange(8)
            if d == s:      # GAS would pick F3 for Rd = Rs
                self.hword(0x1C00 | sub << 9 | imm << 6 | s << 3 | d, f"{op} {rn(d)}, {rn(s)}, #{imm} (F2)")
            else:
                self.ins(f"{op}\t{rn(d)}, {rn(s)}, #{imm}")
            v = None if vs is None else (vs - imm if sub else vs + imm)
        self.wr(d, v)
        self.c_write()

    def imm8(self):
        k = self.R.random()
        if k < 0.15:
            return self.R.choice([0, 1, 0x7F, 0x80, 0xFF])
        return self.R.randrange(256)

    def f3(self):
        op = self.R.choice(["movs", "cmp", "adds", "subs"])
        imm = self.imm8()
        if op == "cmp":
            self.ins(f"cmp\t{rn(self.rs())}, #{imm}")
            self.c_write()
            return
        d = self.rd()
        v = self.kv(d)
        self.ins(f"{op}\t{rn(d)}, #{imm}")
        if op == "movs":
            self.wr(d, imm)
        else:
            self.wr(d, None if v is None else (v + imm if op == "adds" else v - imm))
            self.c_write()

    def shift_amount(self):
        k = self.R.random()
        if k < 0.15:
            return 0
        if k < 0.35:
            return 32
        if k < 0.5:
            return self.R.choice([31, 33, 0xFF, 64])
        return self.R.randrange(1, 32)

    def f4(self, op=None):
        ops = [o for o in F4OPS if self.c_ok() or o not in ("adcs", "sbcs")]
        op = op or self.R.choice(ops)
        s = self.rs()
        if op in ("lsls", "lsrs", "asrs", "rors") and self.R.random() < 0.5 and s != self.rS:
            amt = self.shift_amount()
            self.ins(f"movs\t{rn(s)}, #{amt}")
            self.wr(s, amt)
        if op in ("tst", "cmp", "cmn"):
            self.ins(f"{op}\t{rn(self.rs())}, {rn(s)}")
            self.c_write() if op != "tst" else None
            return
        d = self.rd()
        vs = self.kv(s)
        self.ins(f"{op}\t{rn(d)}, {rn(s)}")
        if op == "negs":
            self.wr(d, None if vs is None else -vs)
            self.c_write()
        else:
            self.wr(d)
        if op in ("adcs", "sbcs"):
            self.c_write()
        if op in ("lsls", "lsrs", "asrs", "rors") and vs is not None and vs & 0xFF:
            self.c_write()

    def f5(self):
        op = self.R.choice(["add", "mov", "cmp"])
        combo = self.R.choice(["lohi", "hilo", "hihi"])
        if op == "cmp":
            d = self.rs() if combo == "lohi" else self.R.choice(self.hi_r())
            m = self.rs() if combo == "hilo" else self.R.choice(self.hi_r())
            if 15 in (d, m) or 13 in (d, m):
                h1, h2 = d >> 3, m >> 3
                self.hword(0x4500 | h1 << 7 | h2 << 6 | (m & 7) << 3 | (d & 7), f"cmp {rn(d)}, {rn(m)}")
            else:
                self.ins(f"cmp\t{rn(d)}, {rn(m)}")
            self.c_write()
            return
        d = self.rd() if combo == "lohi" else self.R.choice(self.hi_w())
        m = self.rs() if combo == "hilo" else self.R.choice(self.hi_r())
        vd, vm = self.kv(d), self.kv(m)
        self.ins(f"{op}\t{rn(d)}, {rn(m)}")
        if op == "mov":
            self.wr(d, vm)
        else:
            self.wr(d, None if vd is None or vm is None else vd + vm)

    def f12(self):
        d = self.rd()
        k = 4 * self.R.randrange(256)
        if self.R.random() < 0.5:
            self.ins(f"add\t{rn(d)}, sp, #{k}")
            v = self.kv(13)
            self.wr(d, None if v is None else v + k)
        else:
            self.ins(f"add\t{rn(d)}, pc, #{k}")
            self.wr(d)

    def f13(self):
        lo = (SP_MIN - self.sp) // 4
        hi = (SP_MAX - self.sp) // 4
        n = self.R.randrange(max(lo, -127), min(hi, 127) + 1)
        if n >= 0:
            self.ins(f"add\tsp, #{4 * n}")
        else:
            self.ins(f"sub\tsp, #{-4 * n}")
        self.sp += 4 * n

    def op_corner(self):
        """A flag corner (docs/DARIA_CORE.md, "What the reference does"),
        often captured straight away."""
        R = self.R
        d, s = R.sample(self.data_lo(), 2)
        k = R.randrange(10)
        keeps_c = False             # every recipe but the shift by 0 writes C
        if k == 0:                  # NEG 0: C = 1
            self.ins(f"movs\t{rn(s)}, #0")
            self.ins(f"negs\t{rn(d)}, {rn(s)}")
            self.wr(s, 0)
            self.wr(d, 0)
        elif k == 1:                # NEG 0x80000000: N and V
            self.ldr_lit(s, 0x80000000)
            self.ins(f"negs\t{rn(d)}, {rn(s)}")
            self.wr(d, 0x80000000)
        elif k == 2:                # ROR, LSL, LSR, ASR by 32 (C from bit 31 or 0)
            self.ins(f"movs\t{rn(s)}, #32")
            self.wr(s, 32)
            self.ins(f"{R.choice(['rors', 'lsls', 'lsrs', 'asrs'])}\t{rn(d)}, {rn(s)}")
            self.wr(d)
        elif k == 3 and self.c_ok():    # a register shift by 0 keeps C
            keeps_c = True
            self.ins(f"movs\t{rn(s)}, #0")
            self.wr(s, 0)
            self.ins(f"{R.choice(['rors', 'lsls', 'lsrs', 'asrs'])}\t{rn(d)}, {rn(s)}")
            self.wr(d)
        elif k == 4:                # ADDS/SUBS overflow
            v, op, imm = R.choice([(0x7FFFFFFF, "adds", 1), (0x80000000, "subs", 1),
                                   (0xFFFFFFFF, "adds", 1), (0x7FFFFFF0, "adds", 0x7F)])
            self.ldr_lit(d, v)
            self.ins(f"{op}\t{rn(d)}, #{imm}")
            self.wr(d)
        elif k == 5:                # ADDS Rd, Rs, #0: C = V = 0
            self.ins(f"adds\t{rn(d)}, {rn(s)}, #0")
            self.wr(d)
        elif k == 6:                # CMP equal, CMN to zero
            if R.random() < 0.5:
                self.ins(f"cmp\t{rn(d)}, {rn(d)}")
            else:
                self.ins(f"negs\t{rn(s)}, {rn(d)}")
                self.ins(f"cmn\t{rn(d)}, {rn(s)}")
                self.wr(s)
        elif k == 7 and self.c_ok():    # ADC/SBC across the wrap
            self.ldr_lit(d, R.choice([0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0]))
            self.ins(f"{R.choice(['adcs', 'sbcs'])}\t{rn(d)}, {rn(s)}")
            self.wr(d)
        elif k == 8:                # MOVS #imm keeps C and V after an overflow
            self.ldr_lit(d, 0x7FFFFFFF)
            self.ins(f"adds\t{rn(d)}, #1")
            self.ins(f"movs\t{rn(s)}, #{R.choice([0, 0x80, 0xFF])}")
            self.wr(d)
            self.wr(s)
        else:                       # CMP of corner values through high registers
            self.ldr_lit(d, R.choice(SPECIAL))
            h = R.choice(HI)
            self.ins(f"mov\t{rn(h)}, {rn(d)}")
            self.wr(h)
            self.ldr_lit(d, R.choice(SPECIAL))
            self.ins(f"cmp\t{rn(d)}, {rn(h)}")
        if not keeps_c:
            self.c_write()
        if R.random() < 0.5:
            self.op_capture()

    def op_const(self):
        """A constant through the literal pool (F6), often a corner value."""
        d = self.rd()
        v = self.R.choice(SPECIAL) if self.R.random() < 0.5 else self.R.getrandbits(32)
        self.ldr_lit(d, v)

    def op_mul(self):
        d = self.rd()
        m = d if self.R.random() < 0.25 else self.rs()
        if self.R.random() < 0.2:
            self.ldr_lit(d, self.R.choice(SPECIAL + [self.R.getrandbits(32)]))
        if self.R.random() < 0.15 and m not in (d, self.rS):
            v = self.R.choice([0, 1, 2, 0x7F, 0xFF])
            self.ins(f"movs\t{rn(m)}, #{v}")
            self.wr(m, v)
        self.ins(f"muls\t{rn(d)}, {rn(m)}")
        self.wr(d)
        self.c.cstate = "unk"

    # ---- loads and stores ---------------------------------------------------------
    SIZES = {"w": (4, "ldr", "str"), "h": (2, "ldrh", "strh"), "sh": (2, "ldrsh", None),
             "b": (1, "ldrb", "strb"), "sb": (1, "ldrsb", None)}

    def pick_addr(self, region, align):
        R = self.R
        if region == "data":
            a = DATA + R.randrange(DATA_SIZE)
        elif region == "rom":
            a = RTAB + R.randrange(4 * RTAB_WORDS)
        elif region == "asset":
            a = ASSET + (R.randrange(128) if R.random() < 0.2 else R.randrange(ASSET_SIZE))
        elif region == "sig":
            a = SIG + R.randrange(min(SIG_SIZE, self.sig_used + 64))
        else:   # stack, in the main body: around SP, inside the filled area
            a = max(STK_LO, self.sp - 64) + R.randrange(1024)
        return a & ~(align - 1)

    def bounds(self, region):
        return {"data": (DATA, DATA + DATA_SIZE), "rom": (RTAB, RTAB + 4 * RTAB_WORDS),
                "asset": (ASSET, ASSET + ASSET_SIZE), "sig": (SIG, SIG + min(SIG_SIZE, self.sig_used + 64)),
                "stack": (STK_LO, STK_HI)}[region]

    def set_base(self, a, align, imm_max, avoid=()):
        """Make some low register hold a base b with a - b in [0, imm_max],
        aligned like a. Returns (register, offset)."""
        R = self.R
        cands = [r for r, v in self.c.known.items()
                 if r < 8 and r not in avoid and 0 <= a - v <= imm_max and (a - v) % align == 0]
        if cands and R.random() < 0.7:
            b = R.choice(cands)
            return b, a - self.kv(b)
        regs = [r for r in self.data_lo() if r not in avoid]
        free = [r for r in regs if not self.is_ptr(r)]
        b = R.choice(free if free and R.random() < 0.75 else regs)
        starts = [s for s in (ASSET, SIG) if 0 <= a - s <= imm_max and (a - s) % align == 0]
        off = a - starts[0] if starts and R.random() < 0.5 else align * R.randrange(imm_max // align + 1)
        base = a - off
        k = R.random()
        near = [r for r, v in self.c.known.items() if r < 8 and 0 < abs(base - v) <= 255]
        if self.c.kind == "main" and STK_LO <= base < STK_HI and k < 0.5 and 0 <= base - self.sp <= 1020 \
                and (base - self.sp) % 4 == 0:
            if base == self.sp and R.random() < 0.4:
                self.ins(f"mov\t{rn(b)}, sp")
            else:
                self.ins(f"add\t{rn(b)}, sp, #{base - self.sp}")
            self.wr(b, base)
        elif base in (ASSET, SIG) and k < 0.6:
            self.ins(f"movs\t{rn(b)}, #1")
            self.ins(f"lsls\t{rn(b)}, {rn(b)}, #{25 if base == ASSET else 30}")
            self.wr(b, base)
            self.c_write()
        elif near and k < 0.6:
            q = R.choice(near)
            d = base - self.kv(q)
            if q != b and 0 < abs(d) <= 7:
                self.ins(f"{'adds' if d > 0 else 'subs'}\t{rn(b)}, {rn(q)}, #{abs(d)}")
            else:
                if q != b:
                    self.ins(f"movs\t{rn(b)}, {rn(q)}")     # LSL #0: C kept
                self.ins(f"{'adds' if d > 0 else 'subs'}\t{rn(b)}, #{abs(d)}")
            self.wr(b, base)
            self.c_write()
        else:
            self.ldr_lit(b, base)
        return b, off

    def set_value(self, r, v):
        """r = v (a small offset), by MOVS, MOVS + NEG or the literal pool."""
        if 0 <= v <= 255:
            self.ins(f"movs\t{rn(r)}, #{v}")
        elif -255 <= v < 0 and self.R.random() < 0.7:
            self.ins(f"movs\t{rn(r)}, #{-v}")
            self.ins(f"negs\t{rn(r)}, {rn(r)}")
            self.c_write()
        else:
            self.ldr_lit(r, v)
        self.wr(r, v)

    def mem(self, store, region=None, size=None):
        R = self.R
        main_top = self.c.kind == "main"
        if region is None:
            if store:
                region = R.choices(["data", "stack"], [70, 30 if main_top else 0])[0]
            else:
                region = R.choices(["data", "rom", "code", "asset", "sig", "stack"],
                                   [36, 15, 6, 15, 8 if main_top else 0, 20 if main_top else 0])[0]
            # Locality: mostly a region some register already points into.
            ok = ["data", "stack"] if store else ["data", "rom", "asset", "sig", "stack"]
            live = [g for g in ok if (main_top or g not in ("sig", "stack")) and
                    any(self.bounds(g)[0] <= v < self.bounds(g)[1] - 4
                        for r, v in self.c.known.items() if r < 8)]
            if live and R.random() < 0.75:
                region = R.choice(live)
        if size is None:
            if store:
                size = R.choices(["w", "h", "b"], [50, 25, 25])[0]
            else:
                size = R.choices(["w", "h", "sh", "b", "sb"], [40, 16, 14, 16, 14])[0]
        align, lop, sop = self.SIZES[size]
        op = sop if store else lop
        if region == "stack" and size == "w" and R.random() < 0.6:
            k = 4 * R.randrange(min(256, (STK_HI - self.sp) // 4))
            d = self.R.randrange(8) if store else self.rd()
            self.ins(f"{op}\t{rn(d)}, [sp, #{k}]")
            if not store:
                self.wr(d)
            return
        if region == "code":       # the code itself, through ADD Rd, PC, #imm (F12)
            b = self.rd()
            self.ins(f"add\t{rn(b)}, pc, #{4 * R.randrange(64)}")
            self.wr(b)
            d = self.rd()
            if size in ("sh", "sb") or R.random() < 0.4:
                o = R.choice([r for r in self.data_lo() if r != b])
                self.set_value(o, align * R.randrange(64 // align))
                self.ins(f"{op}\t{rn(d)}, [{rn(b)}, {rn(o)}]")
            else:
                self.ins(f"{op}\t{rn(d)}, [{rn(b)}, #{align * R.randrange(32)}]")
            self.wr(d)
            return
        a = self.pick_addr(region, align)
        regoff = size in ("sh", "sb") or R.random() < 0.35
        d = R.randrange(8) if store else self.rd()
        # Most accesses go near a pointer some register already holds, as
        # compiled code does (a field of a structure, the next element).
        lo, hi = self.bounds(region)
        ptrs = [(r, v) for r, v in self.c.known.items() if r < 8 and lo <= v < hi - 4]
        if ptrs and R.random() < 0.8:
            b, p = R.choice(ptrs)
            if not regoff and p % align == 0:
                off = align * R.randrange(min(32, (hi - p) // align))
                self.ins(f"{op}\t{rn(d)}, [{rn(b)}, #{off}]")
                if not store:
                    self.wr(d)
                return
            a = max(lo, min(hi - align, p + R.randrange(-64, 128))) & ~(align - 1)
            regoff = True
            close = near = [b]
        elif regoff:
            close = [r for r, v in self.c.known.items() if r < 8 and abs(a - v) <= 255]
            near = [r for r, v in self.c.known.items() if r < 8 and abs(a - v) <= 1024]
        if regoff:
            if close and R.random() < 0.85:
                b = R.choice(close)
            elif near and R.random() < 0.5:
                b = R.choice(near)
            elif R.random() < 0.6:  # a base near the address, unaligned as it comes
                b, _ = self.set_base(a - R.randrange(-255, 256), 1, 0)
            else:
                b, _ = self.set_base(a - align * R.randrange(64), 1, 0)
            delta = a - self.kv(b)
            if delta >= 1 << 31:
                delta -= 1 << 32
            olds = [r for r, v in self.c.known.items() if r < 8 and v == delta and r != b]
            if olds and R.random() < 0.7:
                o = R.choice(olds)
            else:
                o = R.choice([r for r in self.data_lo() if r != b])
                self.set_value(o, delta)
            self.ins(f"{op}\t{rn(d)}, [{rn(b)}, {rn(o)}]")
        else:
            b, off = self.set_base(a, align, 31 * align)
            self.ins(f"{op}\t{rn(d)}, [{rn(b)}, #{off}]")
        if not store:
            self.wr(d)

    def op_load(self):
        if self.R.random() < 0.06:
            self.op_const()
        else:
            self.mem(False)

    def op_store(self):
        self.mem(True)

    # ---- signature ----------------------------------------------------------------
    def sig_slot(self, n=1, flags_free=False):
        """Reserve n words of the signature; returns the offset from rS."""
        if self.sig_used + 4 * n - self.sig_rbase > 128:
            new = self.sig_used
            if flags_free and new - self.sig_rbase <= 255 and self.R.random() < 0.3:
                self.ins(f"adds\t{rn(self.rS)}, #{new - self.sig_rbase}")
                self.c_write()
            else:
                self.ldr_lit(self.rS, SIG + new)
            self.sig_rbase = new
            self.wr(self.rS, SIG + new)
        off = self.sig_used - self.sig_rbase
        self.sig_used += 4 * n
        assert self.sig_used <= SIG_SIZE, "signature full"
        return off

    def dump(self, hi=False):
        """The low registers written since the last dump into the signature:
        mostly STMIA rS! (rS moved to the next free word first), else one STR
        each. hi: every register, r8-r12, SP and LR through a low one."""
        R = self.R
        regs = self.data_lo() if hi else sorted(r for r in self.dirty if r < 8 and r != self.rS)
        self.dirty = set()
        if not regs:
            return
        if hi and R.random() < 0.7:
            # STMIA the low registers, MOV r8-r12, SP, LR into them, STMIA
            # those, and get the low ones back with LDMIA t, {..., t, ...}
            # (the base in the list: the loaded value wins). final: no reload.
            at = self.stmia_sig(regs)
            his = HI + [13, 14]
            lows = sorted(R.sample(regs, len(his)))
            for h, r in zip(his, lows):
                self.ins(f"mov\t{rn(r)}, {rn(h)}")
            self.stmia_sig(lows)
            if hi != "final":
                t = R.choice(regs)
                kt = self.c.known.get(t)
                self.ldr_lit(t, at)
                self.ins(f"ldmia\t{rn(t)}, {rlist(regs)}")
                self.wr(t, kt)          # t has its own value back
            self.dirty = set()
            return
        if not hi and R.random() < 0.85:
            self.stmia_sig(regs)
            return
        R.shuffle(regs)
        self.sig_slot(len(regs) + (8 if hi else 0), flags_free=True)   # one window for all
        self.sig_used -= 4 * (len(regs) + (8 if hi else 0))
        where = {}
        for r in regs:
            where[r] = self.sig_slot()
            self.ins(f"str\t{rn(r)}, [{rn(self.rS)}, #{where[r]}]")
        if hi:
            t = R.choice(regs)
            for h in HI + [13, 14]:
                self.ins(f"mov\t{rn(t)}, {rn(h)}")
                self.ins(f"str\t{rn(t)}, [{rn(self.rS)}, #{self.sig_slot()}]")
            self.ins(f"ldr\t{rn(t)}, [{rn(self.rS)}, #{where[t]}]")
        self.dirty = set()

    def stmia_sig(self, regs):
        """STMIA rS!, {regs} at the next free signature word; returns its address."""
        if self.sig_used != self.sig_rbase:
            d = self.sig_used - self.sig_rbase
            if self.R.random() < 0.8:
                self.ins(f"adds\t{rn(self.rS)}, #{d}")
                self.c_write()
            else:
                self.ldr_lit(self.rS, SIG + self.sig_used)
        at = SIG + self.sig_used
        self.ins(f"stmia\t{rn(self.rS)}!, {rlist(regs)}")
        self.sig_used += 4 * len(regs)
        self.sig_rbase = self.sig_used
        assert self.sig_used <= SIG_SIZE, "signature full"
        self.wr(self.rS, SIG + self.sig_used)
        self.dirty.discard(self.rS)
        return at

    def op_capture(self, conds=None):
        """Flags into the signature: each Bcc skips a store of rS."""
        ok = [c for c in CONDS if self.c_ok() or c not in CREAD]
        conds = conds or self.R.sample(ok, self.R.randrange(1, 4))
        offs = [self.sig_slot() for _ in conds]
        for c, off in zip(conds, offs):
            L = self.label("c")
            self.ins(f"b{c}\t{L}")
            self.ins(f"str\t{rn(self.rS)}, [{rn(self.rS)}, #{off}]")
            self.lab(L)

    # ---- branches -------------------------------------------------------------------
    def inner(self):
        """One operation inside a skipped region or a function body."""
        R = self.R
        k = R.random()
        if k < 0.50:
            self.op_dp()
        elif k < 0.56:
            self.op_mul()
        elif k < 0.75:
            self.op_load()
        elif k < 0.87:
            self.op_store()
        elif k < 0.93 and self.c.depth < 2:
            self.op_bcc()
        elif k < 0.95:
            L = self.label("b")
            self.ins(f"b\t{L}")
            self.dead()
            self.lab(L)
        elif k < 0.97 and self.c.kind == "main":
            self.op_bl()
        else:
            self.op_dp()

    def op_bcc(self):
        ok = [c for c in CONDS if self.c_ok() or c not in CREAD]
        cond = self.R.choice(ok)
        L = self.label("s")
        self.ins(f"b{cond}\t{L}")
        snap = self.snapshot()
        self.c.depth += 1
        n = [0, 1, 1, 2, 2, 2, 3, 4] if self.c.depth == 1 else [0, 1, 2, 3]
        for _ in range(self.R.choice(n)):
            self.inner()
        if self.R.random() < (0.6 if self.c.depth == 1 else 0.3):     # if/else: B over the else part
            E = self.label("e")
            self.ins(f"b\t{E}")
            then = self.snapshot()
            self.c.known, self.c.cstate = dict(snap[0]), snap[1]
            self.lab(L)
            for _ in range(self.R.choice(n[1:])):
                self.inner()
            self.c.depth -= 1
            self.lab(E)
            self.merge(then)
            return
        self.c.depth -= 1
        self.lab(L)
        self.merge(snap)

    def dead(self):
        """A few instructions that never run (after B, BX, MOV pc...)."""
        for _ in range(self.R.choice([0, 1, 1, 2])):
            d, s = self.R.randrange(8), self.R.randrange(8)
            self.ins(self.R.choice([f"movs\t{rn(d)}, #{self.R.randrange(256)}",
                                    f"eors\t{rn(d)}, {rn(s)}", f"adds\t{rn(d)}, {rn(s)}, #1"]))

    def place(self, maxn=2):
        """Dead region contents: the literal pool, waiting functions."""
        self.ltorg()
        n = 0
        while self.pending and n < maxn and self.R.random() < 0.7:
            f = self.pending.pop(0)
            self.c.lines += f.lines
            self.c.pos += f.size
            f.placed = True
            n += 1
            self.ltorg_raw()

    def ltorg_raw(self):
        self.raw(".ltorg", 2)

    def op_b(self):
        L = self.label("b")
        self.ins(f"b\t{L}")
        self.dead()
        self.place()
        if self.R.random() < 0.25 and len(self.funcs) < 40:
            f = self.new_tfunc(arm_callable=self.R.random() < 0.3)
            self.pending.append(f)
            self.place(1)
        self.lab(L)

    def get_tfunc(self, arm_callable=False):
        fs = [f for f in self.funcs if f.arm_callable == arm_callable and not f.name.startswith(("a", "v"))]
        if fs and self.R.random() < 0.55:
            return self.R.choice(fs)
        f = self.new_tfunc(arm_callable)
        self.pending.append(f)
        return f

    def op_bl(self):
        f = self.get_tfunc()
        self.ins(f"bl\t{f.name}", 4)
        self.call_effect(f)

    # ---- functions --------------------------------------------------------------------
    def new_tfunc(self, arm_callable=False):
        """A Thumb leaf function. Called from ARM it must return with BX."""
        R = self.R
        name = self.label("f")
        outer = self.c
        self.c = Ctx("func", "pass")
        ret = R.choice(["bx", "popbx"] if arm_callable else ["bx", "mov", "pop", "pop", "popbx"])
        saved, t = [], None
        self.lab(name)
        if ret in ("pop", "popbx"):
            cands = self.data_lo()
            if ret == "popbx":
                t = R.choice([r for r in cands if r > min(cands)])
                cands = [r for r in cands if r < t]
            saved = sorted(R.sample(cands, R.randrange(0, min(3, len(cands)) + 1)))
            self.ins(f"push\t{rlist(saved + [14])}")
        for _ in range(R.randrange(1, 7)):
            self.inner()
        if ret == "bx":
            self.ins("bx\tlr")
        elif ret == "mov":
            self.ins("mov\tpc, lr")
        elif ret == "pop":
            self.ins(f"pop\t{rlist(saved + [15])}")
        else:
            self.ins(f"pop\t{rlist(saved + [t])}")
            self.ins(f"bx\t{rn(t)}")
            self.wr(t)
        self.ltorg_raw()
        c = self.c
        self.c = outer
        f = Func(name, c.lines, c.pos + 4 * c.nlit + 2, (c.written - set(saved)) | ({t} if t is not None else set()),
                 c.cstate, arm_callable)
        self.funcs.append(f)
        return f

    def arm_dp(self):
        """One ARM data-processing or multiply instruction (gen_random.py's
        mix), on r0-r12 without rS; C read only when this context knows it."""
        R = self.R
        regs = [r for r in range(13) if r != self.rS]
        rr = lambda: R.choice(regs)
        cok = self.c_ok()
        conds = [c for c in CONDS if cok or c not in CREAD]
        cond = R.choice(conds) if R.random() < 0.15 else ""
        k = R.random()
        if k < 0.12:
            d, m = R.sample(regs, 2)
            if R.random() < 0.5:
                self.ins(f"mul{cond}\t{rn(d)}, {rn(m)}, {rn(rr())}", 4)
            else:
                self.ins(f"mla{cond}\t{rn(d)}, {rn(m)}, {rn(rr())}, {rn(rr())}", 4)
            self.wr(d)
            return
        ops = ["and", "eor", "sub", "rsb", "add", "orr", "bic", "mov", "mvn", "cmp", "cmn", "tst", "teq"]
        if cok:
            ops += ["adc", "sbc", "rsc"]
        op = R.choice(ops)
        s = "s" if op not in ("cmp", "cmn", "tst", "teq") and R.random() < 0.35 else ""
        q = R.random()
        if q < 0.35:
            o2 = rn(rr())
        elif q < 0.6:
            sh = R.choice(["lsl", "lsr", "asr", "ror"] + (["rrx"] if cok else []))
            if sh == "rrx":
                o2 = f"{rn(rr())}, rrx"
            else:
                o2 = f"{rn(rr())}, {sh} #{R.randrange(1, 32) if sh in ('lsl', 'ror') else R.randrange(1, 33)}"
        elif q < 0.75:
            o2 = f"{rn(rr())}, {R.choice(['lsl', 'lsr', 'asr', 'ror'])} {rn(rr())}"
        else:
            v, rot = R.randrange(256), 2 * R.randrange(16)
            o2 = f"#{((v >> rot) | (v << (32 - rot))) & M:#x}"
        if op in ("cmp", "cmn", "tst", "teq"):
            self.ins(f"{op}{cond}\t{rn(rr())}, {o2}", 4)
        elif op in ("mov", "mvn"):
            d = rr()
            self.ins(f"{op}{s}{cond}\t{rn(d)}, {o2}", 4)
            self.wr(d)
        else:
            d = rr()
            self.ins(f"{op}{s}{cond}\t{rn(d)}, {rn(rr())}, {o2}", 4)
            self.wr(d)
        arith = op in ("sub", "rsb", "add", "adc", "sbc", "rsc", "cmp", "cmn")
        if arith and (s or op in ("cmp", "cmn")) and not cond:
            self.c_write()

    def arm_mem(self):
        R = self.R
        regs = [r for r in range(13) if r != self.rS]
        store = R.random() < 0.4
        region = "data" if store else R.choice(["data", "rom", "asset"])
        size = R.choice(["w", "h", "b"] if store else ["w", "h", "sh", "b", "sb"])
        align, lop, sop = self.SIZES[size]
        a = self.pick_addr(region, align)
        b = R.choice(regs)
        off = align * R.randrange(64 if size == "w" else 32) if R.random() < 0.7 else 0
        off = min(off, a - (a & ~0xFFF)) if region == "rom" else off
        self.ldr_lit(b, a - off)
        d = R.choice(regs)
        self.ins(f"{sop if store else lop}\t{rn(d)}, [{rn(b)}, #{off}]", 4)
        if not store:
            self.wr(d)

    def arm_ops(self, n):
        for _ in range(n):
            if self.R.random() < 0.75:
                self.arm_dp()
            else:
                self.arm_mem()

    def new_afunc(self):
        """An ARM function, called from Thumb through a BX veneer; it may call
        a Thumb function back (MOV LR, PC; BX). Returns with BX LR."""
        R = self.R
        name = self.label("a")
        outer = self.c
        self.c = Ctx("arm", "pass")
        self.raw(".balign 4", 2)
        self.raw(".arm")
        self.lab(name)
        saved = sorted(R.sample([r for r in range(4, 13) if r != self.rS], R.randrange(0, 3)))
        self.ins(f"push\t{rlist(saved + [14])}", 4)
        self.arm_ops(R.randrange(1, 5))
        if R.random() < 0.5:
            f = self.get_tfunc(arm_callable=True)
            y = R.choice([r for r in range(13) if r != self.rS])
            self.ldr_lit(y, f"{f.name}+1")
            self.ins("mov\tlr, pc", 4)
            self.ins(f"bx\t{rn(y)}", 4)
            self.call_effect(f)
            self.arm_ops(R.randrange(0, 3))
        self.ins(f"pop\t{rlist(saved + [14])}", 4)
        self.ins("bx\tlr", 4)
        self.raw(".ltorg")
        self.raw(".thumb")
        c = self.c
        self.c = outer
        f = Func(name, c.lines, c.pos + 4 * c.nlit + 4, c.written - set(saved), c.cstate, False)
        self.funcs.append(f)
        return f

    def veneer(self, r):
        if r not in self.veneers:
            name = f"via_{rn(r)}"
            f = Func(name, [f"{name}:", f"\tbx\t{rn(r)}"], 2, set(), "pass", False)
            self.veneers[r] = f
            self.funcs.append(f)
            self.pending.append(f)
        return self.veneers[r]

    def op_armcall(self):
        """Thumb -> ARM function (BL to a BX veneer) -> maybe Thumb -> back."""
        R = self.R
        af = R.choice([f for f in self.funcs if f.name.startswith("a")] or [None])
        if af is None or R.random() < 0.5:
            af = self.new_afunc()
            self.pending.append(af)
        if R.random() < 0.3:
            t = self.rd()
            h = R.choice(HI)
            self.ldr_lit(t, af.name)
            self.ins(f"mov\t{rn(h)}, {rn(t)}")
            self.wr(h)
            v = self.veneer(h)
        else:
            t = self.rd()
            self.ldr_lit(t, af.name)
            v = self.veneer(t)
        self.ins(f"bl\t{v.name}", 4)
        self.call_effect(af)

    def op_arm_inline(self):
        """BX PC (word aligned) or BX Rm into ARM code, and back with BX."""
        R = self.R
        if R.random() < 0.5:
            self.raw(".balign 4", 2)
            self.ins("bx\tpc")
            self.ins("nop")
            self.raw(".arm")
        else:
            La = self.label("A")
            t = self.rd()
            self.ldr_lit(t, La)
            self.ins(f"bx\t{rn(t)}")
            self.dead()
            self.raw(".balign 4", 2)
            self.raw(".arm")
            self.lab(La)
        self.c.arm = True
        self.arm_ops(R.randrange(1, 5))
        y = R.choice([r for r in range(13) if r != self.rS])
        if R.random() < 0.5:        # ADD Ry, PC, #1: Thumb at the next word
            self.ins(f"add\t{rn(y)}, pc, #1", 4)
            self.ins(f"bx\t{rn(y)}", 4)
            self.raw(".thumb")
        else:
            Lt = self.label("T")
            self.ldr_lit(y, f"{Lt}+1")
            self.ins(f"bx\t{rn(y)}", 4)
            self.raw(".thumb")
            self.lab(Lt)
        self.c.arm = False
        self.wr(y)

    def op_bx(self):
        R = self.R
        k = R.random()
        if k < 0.3:
            self.op_armcall()
        elif k < 0.55:
            self.op_arm_inline()
        else:                       # BX to a Thumb label, through a low or high register
            L = self.label("x")
            t = self.rd()
            if R.random() < 0.3:
                self.ins(f"adr\t{rn(t)}, {L}")
                self.ins(f"adds\t{rn(t)}, #1")
                self.c_write()
                x = t
            else:
                self.ldr_lit(t, f"{L}+1")
                x = t
                if R.random() < 0.4:
                    x = R.choice(self.hi_w())
                    self.ins(f"mov\t{rn(x)}, {rn(t)}")
            self.ins(f"bx\t{rn(x)}")
            self.wr(t)
            self.wr(x)
            self.dead()
            self.raw(".balign 4", 2)
            self.lab(L)

    def op_jump(self):
        """Computed forward jumps: MOV pc, ADD pc, POP {pc}."""
        R = self.R
        L = self.label("j")
        k = R.random()
        t = self.rd()
        if k < 0.35:                # MOV pc, Rm (bit 0 dropped, stays Thumb)
            self.ldr_lit(t, f"{L}+{R.randrange(2)}")
            x = t
            if R.random() < 0.4:
                x = R.choice(HI)
                self.ins(f"mov\t{rn(x)}, {rn(t)}")
                self.wr(x)
            self.ins(f"mov\tpc, {rn(x)}")
            self.dead()
        elif k < 0.65:              # ADD pc, Rm: PC reads address + 4
            A = self.label("p")
            n = R.randrange(1, 4)
            odd = R.randrange(2)
            self.ins(f"movs\t{rn(t)}, #({L} - {A} - 4 + {odd})")
            self.wr(t)
            x = t
            if R.random() < 0.4:
                x = R.choice(HI)
                self.ins(f"mov\t{rn(x)}, {rn(t)}")
                self.wr(x)
            self.lab(A)
            self.ins(f"add\tpc, {rn(x)}")
            for _ in range(n):
                self.ins(f"movs\t{rn(R.randrange(8))}, #{R.randrange(256)}")
        else:                       # POP {..., pc} of an odd value
            if self.sp - 32 < STK_LO:
                self.op_dp()
                return
            lower = [r for r in self.data_lo() if r < t]
            others = sorted(R.sample(lower, R.randrange(0, min(3, len(lower)) + 1)))
            self.ldr_lit(t, f"{L}+1")
            self.ins(f"push\t{rlist(others + [t])}")
            pops = sorted(R.sample(self.data_lo(), len(others)))
            self.ins(f"pop\t{rlist(pops + [15])}")
            for r in pops:
                self.wr(r)
            self.dead()
        self.lab(L)

    # ---- PUSH/POP, LDMIA/STMIA -----------------------------------------------------
    def op_stack(self):
        R = self.R
        k = R.random()
        if k < 0.4 and self.sp - 40 >= STK_LO:
            regs = sorted(R.sample(range(8), R.randrange(1, 5)))
            lr = R.random() < 0.3
            self.ins(f"push\t{rlist(regs + ([14] if lr else []))}")
            n = len(regs) + lr
            self.sp -= 4 * n
            for _ in range(R.randrange(0, 3)):
                if R.random() < 0.5:
                    d = self.rd()
                    self.ins(f"ldr\t{rn(d)}, [sp, #{4 * R.randrange(n)}]")
                    self.wr(d)
                else:
                    self.f4()
            pops = sorted(R.sample(self.data_lo(), n))
            self.ins(f"pop\t{rlist(pops)}")
            self.sp += 4 * n
            for r in pops:
                self.wr(r)
            return
        load = k < 0.7
        n = R.randrange(1, 6)
        region = R.choice(["data", "rom", "stack"]) if load else "data"
        a = self.pick_addr(region, 4)
        lim = {"data": DATA + DATA_SIZE, "rom": RTAB + 4 * RTAB_WORDS, "stack": STK_HI}[region]
        a = min(a, lim - 4 * n)
        b, _ = self.set_base(a, 4, 0, avoid=(self.rS,))
        if load:
            regs = set(R.sample([r for r in self.data_lo() if r != b], n))
            if R.random() < 0.2:    # base in the list: the loaded value wins
                regs.add(b)
                self.ins(f"ldmia\t{rn(b)}, {rlist(regs)}")
                for r in regs:
                    self.wr(r)
                return
            self.ins(f"ldmia\t{rn(b)}!, {rlist(regs)}")
            for r in regs:
                self.wr(r)
        else:
            regs = set(R.sample([r for r in range(8) if r != b], n))
            if R.random() < 0.4 and all(r > b for r in regs):     # base lowest: old base stored
                regs.add(b)
            self.ins(f"stmia\t{rn(b)}!, {rlist(regs)}")
        self.wr(b, a + 4 * len(regs))

    # ---- the program ----------------------------------------------------------------
    def op(self):
        R = self.R
        k = R.random() * 100
        for w, f in ((21, self.op_dp), (3.5, self.op_mul), (21, self.op_load), (8, self.op_store),
                     (17, self.op_bcc), (4, self.op_capture), (11, self.op_b), (4.5, self.op_bl),
                     (1.4, self.op_bx), (1, self.op_jump), (1.6, self.op_stack), (1, self.f13),
                     (2.5, self.op_corner)):
            if k < w:
                return f()
            k -= w
        return self.op_dp()

    def program(self):
        R = self.R
        o = []
        o.append(f"@ generated by gen_thumb.py {self.seed} {self.nops}: signature register r{self.rS}")
        o.append("\t.syntax unified\n\t.cpu arm7tdmi\n\t.section .vectors, \"ax\"\n\t.arm\n\t.global _start")
        o.append("_start:\tb\treset\n" + "\tb\t.\n" * 7 + "@ the ROM table, at 0x20")
        o.append("rtab:")
        for i in range(0, RTAB_WORDS, 8):
            o.append("\t.word\t" + ", ".join(f"{R.getrandbits(32):#010x}" for _ in range(8)))
        o.append("\t.text\n\t.arm\nreset:")
        o.append(f"\tldr\tsp, ={SP0:#x}")
        for dst in (DATA, STK_LO, STK_LO + 0x400):
            o.append(f"\tldr\tr0, =rtab\n\tldr\tr1, ={dst:#x}\n\tbl\tfill")
        o.append(f"\tmsr\tcpsr_f, #{R.randrange(16) << 28:#x}")
        o.append("\tldr\tr0, =thumb_main + 1\n\tbx\tr0")
        o.append("fill:\tmov\tr2, #32\n1:\tldmia\tr0!, {r3-r10}\n\tstmia\tr1!, {r3-r10}"
                 "\n\tsubs\tr2, r2, #1\n\tbne\t1b\n\tbx\tlr")
        o.append(f"arm_end:\n\tldr\tr0, ={MMIO:#x}\n\tstr\tr2, [r0, #0x10]\n\tmov\tr1, #0xaa"
                 "\n\tstr\tr1, [r0, #0x1c]\n\tb\t.\n\t.ltorg")
        o.append("\t.thumb\n\t.balign 4\nthumb_main:")
        # Registers from the ROM table: LDMIA r0, {r0-r7} (the base in the
        # list), r8-r12 and LR from r0-r5, again r0-r7, then rS and a corner
        # value or two through the literal pool.
        for k in range(2):
            self.ldr_lit(0, RTAB + 4 * R.randrange(RTAB_WORDS - 8))
            self.ins("ldmia\tr0, {r0, r1, r2, r3, r4, r5, r6, r7}")
            if k == 0:
                for h, r in zip(HI + [14], R.sample(range(8), 6)):
                    self.ins(f"mov\t{rn(h)}, {rn(r)}")
        self.ldr_lit(self.rS, SIG)
        for r in R.sample(self.data_lo(), 2):
            self.ldr_lit(r, R.choice(SPECIAL))
        self.c.known = {self.rS: SIG}
        self.c.written = set()
        nd = R.randrange(10, 20)
        for i in range(self.nops):
            if self.pool_due():
                self.op_b()
            self.op()
            nd -= 1
            if nd == 0:
                self.dump(hi=R.random() < 0.12)
                nd = R.randrange(10, 20)
        # The end: every register, the flags, IDENT, then FAULT = 0xAA.
        self.dump(hi="final")
        conds = [c for c in CONDS if self.c_ok() or c not in CREAD]
        self.op_capture(conds)
        t, u = R.sample(self.data_lo(), 2)
        self.ldr_lit(t, MMIO)
        self.ins(f"ldr\t{rn(u)}, [{rn(t)}, #0]")
        self.ins(f"str\t{rn(u)}, [{rn(self.rS)}, #{self.sig_slot()}]")
        if R.random() < 0.5:
            self.ldr_lit(u, self.sig_used)
            self.ins(f"str\t{rn(u)}, [{rn(t)}, #0x10]")
            self.ins(f"movs\t{rn(u)}, #0xaa")
            self.ins(f"str\t{rn(u)}, [{rn(t)}, #0x1c]")
            self.ins("b\t.")
        else:
            self.ldr_lit(2, self.sig_used)
            self.ldr_lit(t, "arm_end")
            self.ins(f"bx\t{rn(t)}")
        self.ltorg()
        while self.pending:
            self.place(len(self.pending))
        self.ltorg_raw()
        return "\n".join(o + self.main.lines) + "\n"


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--image":
        r = random.Random(7800)
        open(sys.argv[2], "wb").write(a78(bytes(r.randrange(256) for _ in range(ASSET_SIZE))))
        return
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    seed = int(sys.argv[1])
    nops = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    sys.stdout.write(Gen(seed, nops).program())


if __name__ == "__main__":
    main()
