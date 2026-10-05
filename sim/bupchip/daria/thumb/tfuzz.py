#!/usr/bin/env python3
"""Random-halfword test for DARIA's Thumb decode and datapath, as assembler
on stdout, with a description of every cell (JSON) for tfuzz_run.py.

  tfuzz.py SEED [CELLS] [--meta FILE] > tfuzz.S     CELLS cells (default 200)

The Thumb counterpart of ../../verif/directed/fuzz.py. Each cell is one
random halfword, fz<k>, drawn with weights from every format (data
processing, the hi-register forms with SP, LR and PC on either side, BX,
every load and store, PUSH/POP, LDM/STM, branches, lone BL halves and BL
pairs, MUL with Rd = Rm, the undefined and SWI space, the H1 = H2 = 0 forms,
empty lists, raw halfwords). A cell:

  c<k>:   ARM: the mode (SVC mostly, FIQ or SYS sometimes), NZCV by MSR,
          stores a POP {pc} needs, r0-r12 and SP from one of 16 value
          tables, then the registers the halfword needs (bases, offsets,
          jump targets), and BX into Thumb
          (a backward sled for a branch: ADD SP, #4 ..., B tl<k>)
  t<k>:   0-4 Thumb set-up instructions, so that the halfword often reads a
          register or the flags written in the clock before: literal reloads
          of the values in place, MOVS, CMP, ADDS #0, LSLS #0, TST, MOV to
          and from hi registers, MOV LR, Rt, and a MULS (C unknown) that a
          later one may define again
  fz<k>:  the halfword (or a BL pair to tl<k>)
          (a forward sled: ADD SP, #4 ..., falling into tl<k>)
  tl<k>:  where every Thumb path lands; often ADD rH, Rx, which reads in the
          next clock what fz<k> wrote; sometimes cp<k>, a C probe (ADCS,
          SBCS, or B<cond> on C to the next halfword); then BX PC back into
          ARM, onto the next cell. BX to ARM lands on c<k+1> directly.
          The sleds' ADD SP, #4 chains make where a branch landed visible
          in SP.

Control flow is aimed: B and B<cond> offsets land on the sleds; BX, MOV pc,
ADD pc, POP {pc} and a lone BL suffix get registers, LR or a stack slot that
reach tl<k> (or, for BX, c<k+1> in ARM state), and about one in ten gets a
target outside the code space or an ARM target with bit 1 set instead.

The generator tracks the registers it sets and predicts, for every cell, the
halt docs/DARIA_CORE.md requires there, if any:
  1 UNDEF  thumb_expand.record() says the halfword halts;
  8 FLAGS  C is unknown at fz<k> (a MULS with nothing defining C since) and
           the halfword reads C (record()'s rdc), or at the probe cp<k> when
           C is still unknown after the halfword (cus, cdef, and for a shift
           by register the amount);
  4 FETCH  the aimed target is outside the code space, or ARM with bit 1 set
           (BX PC at an address 2 mod 4 included);
  5, 6, 7  DATA, RO, BLOCK: the access (every beat of a block transfer)
           misses the windows of bup_cpu.sv (ROM 0-0x3FFF, RAM
           0x40000000-0x40003FFF, no assets in BLANK.a78).
tfuzz_run.py checks each predicted halt and runs everything else in lockstep
with the reference. The program starts with a start-up that fills RAM, then
jumps to the cell whose index is in the word start_cell (0 as built; the
runner patches it to run from any cell). The same SEED and CELLS always give
the same program.
SPDX-License-Identifier: MIT
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import thumb_expand as tx  # noqa: E402

M32 = 0xFFFFFFFF
DATA = 0x40002000               # RAM the start-up fills (4 KiB)
NOP = 0x46C0                    # mov r8, r8
MODES = [(0xD3, 80), (0xD1, 10), (0xDF, 10)]     # SVC, FIQ, SYS
EDGE = [0, 1, 2, 3, 0x1f, 0x20, 0x21, 0xff, 0x100, 0x1ff, 0xffffff00, 0x7fffffff, 0x80000000,
        0x80000001, 0xffffffff, 0xfffffffe, 0x40000000, 0x0000ffff, 0xffff0000, 0x00008000,
        0xffff8000, 0x55555555, 0xaaaaaaaa]
BAD_THUMB = [0x00004001, 0x00004000, 0x40000001, 0x02000001, 0xfffffffe, 0x80000001, 0x0001_0000]


def popcount(v):
    return bin(v).count("1")


def in_rom(a):
    return a < 0x4000


def in_ram(a):
    return 0x40000000 <= a < 0x40004000


def in_io(a):
    return 0xE0009000 <= a < 0xE0009100


def mem_code(a, load):
    """bup_cpu.sv's check of a single transfer: None, or the halt code."""
    if load:
        return None if in_rom(a) or in_ram(a) or in_io(a) else 5
    if in_ram(a) or in_io(a):
        return None
    return 6 if a >> 28 == 0 else 5


def blk_code(addrs, load):
    """The same for the beats of a block transfer, in order."""
    for a in addrs:
        if not (in_ram(a) or (in_rom(a) and load)):
            return 6 if (in_rom(a) or a >> 28 == 0) and not load else 7
    return None


class Gen:
    def __init__(self, seed, ncells):
        self.R = random.Random(seed)
        self.seed, self.ncells = seed, ncells
        R = self.R
        self.tables = [[self.val() for _ in range(14)] for _ in range(16)]
        self.kinds = [(self.k_f1, 6), (self.k_f2, 5), (self.k_f3, 5), (self.k_f4, 10), (self.k_mul, 4),
                      (self.k_rdc, 4), (self.k_f5, 9), (self.k_bx, 6), (self.k_f6, 3), (self.k_f78, 7),
                      (self.k_f9, 6), (self.k_f10, 4), (self.k_f11, 4), (self.k_f12, 3), (self.k_f13, 2),
                      (self.k_f14, 7), (self.k_f15, 5), (self.k_f16, 6), (self.k_f18, 3), (self.k_bl1, 2),
                      (self.k_bl2, 3), (self.k_blpair, 2), (self.k_und, 5), (self.k_raw, 6)]
        self.wsum = sum(w for _, w in self.kinds)
        del R

    # ---- values ---------------------------------------------------------------
    def val(self):
        R = self.R
        k = R.random()
        if k < 0.45:
            return R.choice(EDGE)
        if k < 0.6:
            return R.randrange(64)
        if k < 0.7:
            return DATA + R.randrange(0x1000)
        return R.getrandbits(32)

    def base(self, block=False):
        """A base address: mostly the filled RAM, also ROM, the window ends,
        the empty asset window and edge values."""
        R = self.R
        k = R.random()
        if k < (0.7 if block else 0.6):
            a = DATA + R.randrange(0x80, 0xF80)
            return a & ~3 if R.random() < 0.6 else a
        if k < 0.75:
            return R.randrange(0x40, 0x3F00)
        if k < 0.81:
            return 0x40004000 - R.randrange(1, 0x48)
        if k < 0.85:
            return (0x40000000 + R.randrange(0x40) - 0x20) & M32
        if k < 0.89:
            return 0x3FF0 + R.randrange(0x20)
        if k < 0.93:
            return 0x02000000 + R.randrange(0x100)
        return R.choice(EDGE)

    def offset(self):
        R = self.R
        k = R.random()
        if k < 0.6:
            return R.choice([0, 1, 2, 3, 4, R.randrange(0x100)])
        if k < 0.8:
            return -R.randrange(1, 0x100) & M32
        return R.choice(EDGE)

    # ---- halfwords, by kind -----------------------------------------------------
    def lo(self):
        return self.R.randrange(8)

    def f5reg(self):
        k = self.R.random()
        if k < 0.35:
            return self.R.randrange(8)
        if k < 0.6:
            return self.R.randrange(8, 13)
        return self.R.choice([13, 14, 15])

    def k_f1(self):
        R = self.R
        return R.randrange(3) << 11 | R.choice([0, 0, 1, 2, 31, R.randrange(32)]) << 6 | self.lo() << 3 | self.lo()

    def k_f2(self):
        return 0x1800 | self.R.randrange(4) << 9 | self.R.choice([0, 7, self.lo()]) << 6 | self.lo() << 3 | self.lo()

    def k_f3(self):
        R = self.R
        return 0x2000 | R.randrange(4) << 11 | self.lo() << 8 | R.choice([0, 1, 0x7f, 0x80, 0xff, R.randrange(256)])

    def k_f4(self):
        return 0x4000 | self.R.randrange(16) << 6 | self.lo() << 3 | self.lo()

    def k_mul(self):
        rd = self.lo()
        rs = rd if self.R.random() < 0.3 else self.lo()
        return 0x4340 | rs << 3 | rd

    def k_rdc(self):                                # the C readers: ADC, SBC, B<cond> on C
        R = self.R
        if R.random() < 0.5:
            return 0x4000 | R.choice([5, 6]) << 6 | self.lo() << 3 | self.lo()
        return 0xD000 | R.choice([2, 3, 8, 9]) << 8 | R.randrange(256)

    def k_f5(self):
        R = self.R
        op = R.randrange(3)
        while True:
            d, s = self.f5reg(), self.f5reg()
            if d >= 8 or s >= 8 or R.random() < 0.08:  # H1 = H2 = 0 sometimes: halts
                break
        return 0x4400 | op << 8 | (d >> 3) << 7 | (s >> 3) << 6 | (s & 7) << 3 | (d & 7)

    def k_bx(self):
        R = self.R
        s = self.f5reg()
        w = 0x4700 | (s >> 3) << 6 | (s & 7) << 3
        if R.random() < 0.06:
            w |= 0x80                               # H1: halts
        if R.random() < 0.06:
            w |= R.randrange(1, 8)                  # bits 2:0: halts
        return w

    def k_f6(self):
        return 0x4800 | self.lo() << 8 | self.R.randrange(256)

    def k_f78(self):
        return 0x5000 | self.R.randrange(8) << 9 | self.lo() << 6 | self.lo() << 3 | self.lo()

    def k_f9(self):
        R = self.R
        return 0x6000 | R.randrange(4) << 11 | R.choice([0, 1, 2, 3, R.randrange(32)]) << 6 | self.lo() << 3 | self.lo()

    def k_f10(self):
        R = self.R
        return 0x8000 | R.randrange(2) << 11 | R.choice([0, 1, R.randrange(32)]) << 6 | self.lo() << 3 | self.lo()

    def k_f11(self):
        R = self.R
        return 0x9000 | R.randrange(2) << 11 | self.lo() << 8 | R.choice([0, 1, 2, R.randrange(256)])

    def k_f12(self):
        return 0xA000 | self.R.randrange(2) << 11 | self.lo() << 8 | self.R.randrange(256)

    def k_f13(self):
        return 0xB000 | self.R.randrange(2) << 7 | self.R.randrange(128)

    def rlist(self):
        R = self.R
        k = R.random()
        if k < 0.75:
            return R.getrandbits(8)
        if k < 0.95:
            return R.choice([1 << R.randrange(8), 0xFF])
        return 0                                    # empty: halts

    def k_f14(self):
        return 0xB400 | self.R.randrange(2) << 11 | self.R.randrange(2) << 8 | self.rlist()

    def k_f15(self):
        return 0xC000 | self.R.randrange(2) << 11 | self.lo() << 8 | self.rlist()

    def k_f16(self):
        R = self.R
        cond = R.randrange(14) if R.random() < 0.88 else R.choice([14, 15])
        return 0xD000 | cond << 8 | R.randrange(256)

    def k_f18(self):
        return 0xE000 | self.R.randrange(2048)

    def k_bl1(self):
        return 0xF000 | self.R.randrange(2048)

    def k_bl2(self):
        return 0xF800 | self.R.randrange(2048)

    def k_blpair(self):
        return "bl"

    def k_und(self):
        R = self.R
        return R.choice([0xDE00 | R.randrange(256), 0xDF00 | R.randrange(256),
                         R.choice([0xB1, 0xB2, 0xB3, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBE, 0xBF]) << 8 | R.randrange(256),
                         0xE800 | R.randrange(2048)])

    def k_raw(self):
        return self.R.getrandbits(16)

    def pick(self):
        t = self.R.randrange(self.wsum)
        for f, w in self.kinds:
            if t < w:
                return f.__name__[2:], f()
            t -= w

    # ---- one cell -------------------------------------------------------------------
    def cell(self, k):
        R = self.R
        kind, hw = self.pick()
        if hw != "bl" and tx.record(hw)["cls"] == "ADDPC" and (hw >> 3) & 15 == 15:
            b = R.randrange(15)                     # ADD pc, pc would go anywhere: another Rm
            hw = (hw & ~0x78) | (b >> 3) << 6 | (b & 7) << 3
        rec = tx.record(hw) if hw != "bl" else dict(cls="BL", fmt="F19pair", rdc="0", cus="0", s="-", cdef="-")
        cls = rec["cls"]
        hx = (lambda f: int(rec[f], 16))
        mode = R.choices([m for m, _ in MODES], [w for _, w in MODES])[0]
        tbl = R.randrange(16)
        state = list(self.tables[tbl]) + ["t%d+1" % k]     # r0-r12, sp, lr at fz<k>
        over = {}                                   # ARM loads after the table
        crit = set()                                # must keep their value until fz<k>
        prep = []                                   # (address, value) stores, before the table
        lr_val = None                               # LR wanted at fz<k> (MOV LR, Rt)
        target = None                               # an aimed jump: "tl", "arm" or "bad"
        layout = None                               # "bxpc" or "movpcpc"
        align = R.randrange(2)                      # fz<k> at 4n (0) or 4n + 2 (1)
        mb = mf = 0                                 # sled lengths
        if cls != "HALT" and R.random() < 0.85:
            over[13] = state[13] = self.base(block=True)    # SP in RAM, mostly

        def want_reg(r, v):
            nonlocal lr_val
            if r == 14:
                lr_val = v
            else:
                over[r] = v
            state[r] = v
            crit.add(r)

        def aim(r, good, bad, can_arm=False):
            """Give register r a jump target: "tl", "arm" or "bad"."""
            x = R.random()
            if x < 0.1:
                want_reg(r, R.choice(bad))
                return "bad"
            if can_arm and x < 0.4:
                if R.random() < 0.25:
                    want_reg(r, "c%d+2" % (k + 1))  # ARM with bit 1 set
                    return "bad"
                want_reg(r, "c%d" % (k + 1))
                return "arm"
            want_reg(r, R.choice(good))
            return "tl"

        if cls == "MEM":
            a = hx("A")
            if a != 15:
                want_reg(a, self.base())
            if rec["roff"] == "1":
                b = hx("B")
                if b == a:                          # [Rb, Rb]: the address is 2 x Rb
                    want_reg(a, R.choice([(DATA + R.randrange(0x100, 0xF00)) // 2, self.base()]))
                else:
                    want_reg(b, self.offset())
        elif cls == "BLK":
            a, lst = hx("A"), int(rec["list"], 16)
            if lst & 0x8000:                        # POP {pc}: a stack the program can prepare
                want_reg(a, DATA + R.randrange(0x80, 0xF00) + (0 if R.random() < 0.7 else R.randrange(4)))
            else:
                want_reg(a, self.base(block=True))
        elif cls in ("BX", "MOVPC"):
            b = hx("B")
            if b == 15:
                if cls == "BX":                     # BX PC: ARM at fz + 4, or FETCH at 4n + 2
                    layout, target = "bxpc", ("arm" if align == 0 else "bad")
                else:                               # MOV pc, pc: Thumb at fz + 4
                    layout, target, mf = "movpcpc", "tl", 2
            elif cls == "BX":
                target = aim(b, ["tl%d+1" % k], BAD_THUMB, can_arm=True)
            else:
                target = aim(b, ["tl%d" % k, "tl%d+1" % k], BAD_THUMB)
        elif cls == "ADDPC":
            target = aim(hx("B"), ["tl%d-fz%d-4" % (k, k), "tl%d-fz%d-3" % (k, k)], [0x40000000, 0x7ffff000, 0x10000])
        elif cls == "BL2":
            imm = int(rec["imm"], 16)
            target = aim(14, ["tl%d-%d" % (k, imm), "tl%d-%d" % (k, imm - 1)], [0x40000000, 0x3ff00, 0xfffff000])
        elif cls in ("BR", "BL"):
            target = "tl"
        elif cls == "DP" and rec["sh"].endswith(":R"):     # the amount: 0, 32, past 32, Rs[7:0] only
            want_reg(hx("B"), R.choice([0, 0, 1, 31, 32, 33, 64, 0xff, 0x100, 0x120, 0xffffff20, 0x80000000,
                                        self.val()]))
        if cls == "BR":
            mb, mf = R.choice([0, 1, 2, 3, 5, 8]), R.choice([0, 1, 2, 3, 5, 8])

        # Thumb set-up before fz<k>, tracking the registers and whether C is
        # unknown when fz<k> starts.
        deps = []
        cunk = False
        free = [r for r in range(8) if r not in crit]
        if lr_val is not None:                      # MOV LR, Rt with Rt = the value
            rt = R.choice(free)
            free.remove(rt)
            over[rt] = state[rt] = lr_val
            deps.append("mov\tlr, r%d" % rt)
        plan = [R.choice(["lit", "lit", "movs", "cmp", "adds0", "lsl0", "tst", "movhi"])
                for _ in range(R.choice([0, 0, 1, 1, 2, 3]))]
        # A MULS (C unknown) before the C readers, and before what passes C
        # through or defines it only for a non-zero register amount.
        if R.random() < (0.5 if rec["rdc"] == "1" else 0.35 if rec.get("cdef") in ("N", "R") else 0.15):
            plan.insert(R.randrange(len(plan) + 1), "mul")
            if R.random() < 0.25:
                plan.append(R.choice(["cmp", "adds0", "movs", "lsl0", "tst"]))
        for p in plan:
            if p == "lit":                          # reload a value in place (often a base)
                cand = [r for r in range(8) if isinstance(state[r], (int, str))]
                hot = [r for r in cand if r in crit]
                r = R.choice(hot if hot and R.random() < 0.6 else cand)
                deps.append(("lit", "r%d" % r, state[r]))
            elif p == "movs" and free:
                r, v = R.choice(free), R.randrange(256)
                deps.append("movs\tr%d, #%d" % (r, v))
                state[r] = v
            elif p == "cmp":
                if R.random() < 0.5:
                    deps.append("cmp\tr%d, r%d" % (self.lo(), self.lo()))
                else:
                    deps.append("cmp\tr%d, #%d" % (self.lo(), R.randrange(256)))
                cunk = False
            elif p == "adds0":
                r = self.lo()
                deps.append("adds\tr%d, r%d, #0" % (r, r))
                cunk = False
            elif p == "lsl0":
                r = self.lo()
                deps.append("lsls\tr%d, r%d, #0" % (r, r))
            elif p == "tst":
                deps.append("tst\tr%d, r%d" % (self.lo(), self.lo()))
            elif p == "movhi" and free:
                h = R.randrange(8, 13)
                if h in crit or R.random() < 0.5:
                    r = R.choice(free)
                    deps.append("mov\tr%d, r%d" % (r, h))
                    state[r] = state[h]
                else:
                    r = self.lo()
                    deps.append("mov\tr%d, r%d" % (h, r))
                    state[h] = state[r]
            elif p == "mul" and free:
                r, s = R.choice(free), self.lo()
                deps.append("muls\tr%d, r%d" % (r, s))
                x, y = state[r], state[s]
                state[r] = (x * y) & M32 if isinstance(x, int) and isinstance(y, int) else None
                cunk = True

        # fz<k>'s alignment: a leading NOP fixes the parity of sled + set-up.
        if (mb + len(deps)) % 2 != align:
            deps.insert(0, "nop")

        # Branch offsets that land on the sleds or on tl<k>, never on the
        # set-up (which would loop).
        if cls == "BR":
            nd = len(deps)
            off = R.choice([-nd - j - 2 for j in range(1, mb + 1)] + [j - 2 for j in range(1, mf + 2)])
            hw = (hw & 0xFF00) | (off & 0xFF) if rec["fmt"] == "F16" else (hw & 0xF800) | (off & 0x7FF)
            rec = tx.record(hw)

        # The halt the cell must take, if any.
        exp, note = None, ""
        if cls == "HALT":
            exp = (1, "fz", "table: " + rec["fmt"])
        elif cunk and rec["rdc"] == "1":
            exp = (8, "fz", "C unknown, reads C")
        elif cls == "MEM" and hx("A") != 15:
            off = int(rec["off"], 16) if rec["roff"] == "0" else state[hx("B")]
            addr = (state[hx("A")] + off) & M32
            if in_io(addr):
                raise RuntimeError("tfuzz %d cell %d: address %08x in the peripheral" % (self.seed, k, addr))
            note = "address %08x" % addr
            code = mem_code(addr, rec["L"] == "1")
            if code:
                exp = (code, "fz", note)
        elif cls == "BLK":
            lst = int(rec["list"], 16)
            n = popcount(lst)
            start = state[hx("A")] if rec["pu"][1] == "1" else (state[hx("A")] - 4 * n) & M32
            beats = [(start + 4 * i) & M32 for i in range(n)]
            note = "beats from %08x" % start
            code = blk_code(beats, rec["L"] == "1")
            if code:
                exp = (code, "fz", note)
            elif lst & 0x8000:                      # POP {pc}: the last beat is the target
                bad = R.random() < 0.1
                prep.append((beats[-1] & ~3, R.choice(BAD_THUMB) if bad else R.choice(["tl%d" % k, "tl%d+1" % k])))
                target = "bad" if bad else "tl"
        if exp is None and target == "bad":
            exp = (4, "fz", "aimed outside the code space")

        # Whether C is unknown after fz<k>, and the probe at tl<k>.
        if rec["cus"] == "1":
            cunk_after = True
        elif rec.get("s") == "1" and rec["cdef"] == "Y":
            cunk_after = False
        elif rec.get("s") == "1" and rec["cdef"] == "R":
            amt = state[hx("B")]
            cunk_after = cunk and amt & 0xFF == 0 if isinstance(amt, int) else None
        else:
            cunk_after = cunk
        probe = None
        if exp is None and target != "arm" and cunk_after is not None and \
                R.random() < (0.6 if cunk_after else 0.12):
            if R.random() < 0.5:
                probe = "%s\tr%d, r%d" % (R.choice(["adcs", "sbcs"]), self.lo(), self.lo())
            else:
                probe = "b%s\t.+2" % R.choice(["cs", "cc", "hi", "ls"])
            if cunk_after:
                exp = (8, "cp", "C still unknown at the probe")

        # Often, an instruction at tl<k> that reads what fz<k> wrote, in the next
        # clock (ADD to a hi register: no flags, so C stays as predicted).
        consumer = None
        if (exp is None or exp[1] == "cp") and target != "arm" and R.random() < 0.5:
            x = int(rec["rd"], 16) if rec.get("rd", "-") not in ("-", "f") else self.lo()
            consumer = "add\tr%d, r%d" % (R.randrange(8, 13), x)

        meta = dict(k=k, kind=kind, hw=hw, fmt=rec["fmt"], cls=rec["cls"], exp=exp, note=note, align=align,
                    mode=mode, cunk=cunk, probe=probe is not None, target=target, layout=layout)
        return meta, dict(mode=mode, nzcv=R.randrange(16), prep=prep, tbl=tbl, over=over, deps=deps,
                          mb=mb, mf=mf, layout=layout, hw=hw, probe=probe, align=align, consumer=consumer)

    # ---- the program --------------------------------------------------------------
    def lit(self, reg, v):
        """A literal load. GAS cannot put a forward label difference (an ADD
        pc offset) in a literal pool, so those go into words of their own,
        emitted at the next pool."""
        if isinstance(v, str) and "-fz" in v:
            self.words.append(("aw%d" % len(self.words), v))
            return "ldr\t%s, %s" % (reg, self.words[-1][0])
        return "ldr\t%s, =%s" % (reg, v if isinstance(v, str) else "0x%08x" % v)

    def flush(self):
        out = ["\t.balign 4"] + ["%s:\t.word\t%s" % w for w in self.words[self.flushed:]]
        self.flushed = len(self.words)
        return out

    def program(self):
        R = self.R
        cells = [self.cell(k) for k in range(self.ncells)]
        self.words, self.flushed = [], 0
        out = ["@ generated by tfuzz.py %d %d" % (self.seed, self.ncells),
               "\t.syntax unified", "\t.cpu arm7tdmi", '\t.section .vectors, "ax"', "\t.arm",
               "\t.global _start", "_start:\tb\treset"] + ["\tb\t."] * 7
        out += ["\t.text", "reset:",
                "\tldr\tr12, =0x%08x" % DATA, "\tldr\tr0, =0x83828180", "\tldr\tr8, =0x04040404"]
        out += ["\tadd\tr%d, r%d, r8" % (i, i - 1) for i in range(1, 8)]
        out += ["\tldr\tr8, =0x20202020", "\tmov\tr9, #128",
                "1:\tstmia\tr12!, {r0-r7}"] + ["\tadd\tr%d, r%d, r8" % (i, i) for i in range(8)] + \
               ["\tsubs\tr9, r9, #1", "\tbne\t1b",
                "\tldr\tr0, start_cell", "\tadr\tr1, cells", "\tldr\tpc, [r1, r0, lsl #2]",
                "start_cell:\t.word\t0",
                "cells:\t.word\t" + ", ".join("c%d" % k for k in range(self.ncells + 1)),
                "\t.ltorg"]
        for k, (c, x) in enumerate(cells):
            if k % 3 == 0 and k:
                out += ["\tb\tlp%d" % k, "\t.ltorg"] + self.flush() + ["lp%d:" % k]
            out += ["c%d:" % k, "\tmsr\tcpsr_c, #0x%02x" % x["mode"], "\tmsr\tcpsr_f, #0x%08x" % (x["nzcv"] << 28)]
            for a, v in x["prep"]:
                out += ["\tldr\tr0, =%s" % (v if isinstance(v, str) else "0x%08x" % v),
                        "\tldr\tr1, =0x%08x" % a, "\tstr\tr0, [r1]"]
            out += ["\tldr\tr12, =tbl%d" % x["tbl"], "\tldmia\tr12, {r0-r12, sp}"]
            for r, v in sorted(x["over"].items()):
                out.append("\t" + self.lit("sp" if r == 13 else "r%d" % r, v))
            out += ["\tadr\tlr, t%d+1" % k, "\tbx\tlr", "\t.thumb"]
            # Sleds: a chain of ADD SP, #4 (no flags), so that SP shows where a
            # branch landed; the backward one ends in B tl<k>.
            out += ["\tadd\tsp, #4"] * (x["mb"] - 1) + ["\tb\ttl%d" % k] * min(x["mb"], 1)
            out.append("t%d:" % k)
            out += ["\t" + (self.lit(d[1], d[2]) if isinstance(d, tuple) else d) for d in x["deps"]]
            pos = x["mb"] + len(x["deps"])          # halfwords from the aligned start
            assert pos % 2 == x["align"]
            if x["hw"] == "bl":
                out.append("fz%d:\tbl\ttl%d" % (k, k))
                pos += 2
            else:
                out.append("fz%d:\t.hword\t0x%04x" % (k, x["hw"]))
                pos += 1
            if x["layout"] == "bxpc":               # BX PC: Thumb at fz + 2, ARM at fz + 4
                out.append("\tb\ttl%d" % k)
                pos += 1
                if x["align"] == 0:
                    out += ["\t.arm", "\tb\tc%d" % (k + 1), "\t.thumb"]
                    pos += 2
            out += ["\tadd\tsp, #4"] * x["mf"]
            pos += x["mf"]
            out.append("tl%d:" % k)
            if x["consumer"]:
                out.append("\t" + x["consumer"])
                pos += 1
            if x["probe"]:
                out.append("cp%d:\t%s" % (k, x["probe"]))
                pos += 1
            if pos % 2:
                out.append("\tnop")
            out += ["\tbx\tpc", "\tnop", "\t.arm"]
        out += ["c%d:" % self.ncells, "\tldr\tr1, =0xE000901C", "\tmov\tr0, #0xaa", "\tstr\tr0, [r1]",
                "\tb\t.", "\t.ltorg"] + self.flush()
        for t, vals in enumerate(self.tables):
            out.append("tbl%d:\t.word\t" % t + ", ".join("0x%08x" % v for v in vals))
        del R
        return "\n".join(out) + "\n", [c for c, _ in cells]


def generate(seed, ncells=200):
    return Gen(seed, ncells).program()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--meta")]
    meta = None
    if "--meta" in sys.argv:
        meta = sys.argv[sys.argv.index("--meta") + 1]
        args.remove(meta)
    seed = int(args[0])
    ncells = int(args[1]) if len(args) > 1 else 200
    asm, cells = generate(seed, ncells)
    sys.stdout.write(asm)
    if meta:
        json.dump(cells, open(meta, "w"), indent=0)


if __name__ == "__main__":
    main()
