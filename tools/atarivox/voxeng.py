#!/usr/bin/env python3
"""The AtariVox speech engine: its instruction set, an assembler and a
clock-accurate emulator (docs/ATARIVOX.md, "The engine").

The engine is a small processor built for the job, so that the FPGA spends
block RAM and a multiplier rather than logic: 64 registers of 32 bits (r0
reads 0) with 192 more words of data memory in the same block RAM, one
27 x 27 multiplier, a 4,096 x 20-bit data ROM (the sine table and the sound
tables) and a 40-bit instruction ROM. Every instruction takes 4 clk_sys
cycles. One program does both jobs: it turns SpeakJet codes into segments
of sound and computes the samples.

Instruction word (40 bits):
  [39:35] op  [34:29] d  [28:23] a  [22:17] b  [16] unused  [15:0] imm

  add  d,a,b      d = a + b              sub  d,a,b   d = a - b
  and  d,a,b      or / xor likewise      addi d,a,imm d = a + sext(imm)
  andi d,a,imm    d = a & zext(imm)      ori  d,a,imm d = a | zext(imm)
  lui  d,imm      d = imm << 16
  mul  d,a,b,sh   d = (sext27(a) * sext27(b)) >>> sh, sh in 0, 7, 12, 16
                  (imm[1:0] selects it); the low 32 bits
  hi12 d,a        d = a[31:20]
  sin  d,a        d = rom[a[30:22]]: half a sine period; the program
                  negates it when a[31] is set
  ldr  d,a,imm    d = rom[a + imm] (zero-extended)   ldrs: sign-extended
  ldm  d,a,imm    d = mem[a + imm]       stm  b,a,imm  mem[a + imm] = b
  beq / bne / blt / bge / bltu  a,b,target
  jal  d,target   d = pc + 1, pc = target
  jr   a          pc = a
  in   d,port     out port,a

mem[] is the register file's block RAM: words 0-63 are r0-r63, 64-255 data.
Ports: in 0 = status (bit 0 tick, bit 2 abort, bit 3 say "Ready"; reading
clears them), in 1 = the next FIFO byte (reading pops it), in 2 = a 16-bit
LFSR (each read steps it), in 3 = FIFO not empty; out 0 = the audio
sample.

MIT licence, as the rest of the Pocket port's own code.
"""
import re
import sys

OPS = ["add", "sub", "and", "or", "xor", "addi", "andi", "ori", "lui", "mul", "hi12", "sin",
       "ldr", "ldrs", "ldm", "stm", "beq", "bne", "blt", "bge", "bltu", "jal", "jr", "in", "out"]
OP = {n: i for i, n in enumerate(OPS)}
SHIFTS = [0, 7, 12, 16]
M32 = 0xFFFFFFFF
CLK_PER_INSTR = 4
ROM_WORDS = 4096
IROM_WORDS = 1024


def s32(x):
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def sx(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if x >> (bits - 1) else x


# ---------------------------------------------------------------- assembler
class AsmError(Exception):
    pass


def assemble(text, consts=None):
    """Two passes. Returns (words, labels, regs, lines)."""
    regs = {"r0": 0, "zero": 0}
    equ = dict(consts or {})
    labels = {}
    prog = []                                     # (line_no, mnemonic, args)

    def value(tok, line):
        tok = tok.strip()
        if tok in labels:
            return labels[tok]
        if tok in equ:
            return equ[tok]
        try:
            return eval(tok, {"__builtins__": {}}, {**equ, **labels})
        except Exception as e:
            raise AsmError(f"line {line}: bad value {tok!r}: {e}")

    lines = text.splitlines()
    for no, raw in enumerate(lines, 1):
        s = raw.split(";")[0].strip()
        if not s:
            continue
        m = re.match(r"^\.reg\s+(\w+)\s+(\d+)$", s)
        if m:
            regs[m.group(1)] = int(m.group(2))
            continue
        m = re.match(r"^\.equ\s+(\w+)\s+(.+)$", s)
        if m:
            equ[m.group(1)] = value(m.group(2), no)
            continue
        while True:
            m = re.match(r"^(\w+):\s*(.*)$", s)
            if not m:
                break
            if m.group(1) in labels:
                raise AsmError(f"line {no}: label {m.group(1)} twice")
            labels[m.group(1)] = len(prog)
            s = m.group(2).strip()
        if not s:
            continue
        parts = s.split(None, 1)
        mn = parts[0].lower()
        args = [a.strip() for a in parts[1].split(",")] if len(parts) > 1 else []
        n = 2 if mn == "li" else 1
        for k in range(n):
            prog.append((no, mn, args, k))

    def reg(tok, line):
        tok = tok.strip()
        if tok not in regs:
            m = re.match(r"^r(\d+)$", tok)
            if m and int(m.group(1)) < 64:
                return int(m.group(1))
            raise AsmError(f"line {line}: unknown register {tok!r}")
        return regs[tok]

    words = []
    for pc, (no, mn, a, k) in enumerate(prog):
        d = ra = rb = imm = 0
        op = mn
        try:
            if mn == "li":                        # two words: lui + ori
                v = value(a[1], no) & M32
                if k == 0:
                    op, d, imm = "lui", reg(a[0], no), v >> 16
                else:
                    op, d, ra, imm = "ori", reg(a[0], no), reg(a[0], no), v & 0xFFFF
            elif mn == "mov":
                op, d, ra = "add", reg(a[0], no), reg(a[1], no)
            elif mn == "nop":
                op = "add"
            elif mn == "j":
                op, imm = "jal", value(a[0], no)
            elif mn in ("add", "sub", "and", "or", "xor"):
                d, ra, rb = reg(a[0], no), reg(a[1], no), reg(a[2], no)
            elif mn in ("addi", "andi", "ori", "ldr", "ldrs", "ldm"):
                d, ra, imm = reg(a[0], no), reg(a[1], no), value(a[2], no)
            elif mn == "stm":
                rb, ra, imm = reg(a[0], no), reg(a[1], no), value(a[2], no)
            elif mn == "lui":
                d, imm = reg(a[0], no), value(a[1], no)
            elif mn == "mul":
                d, ra, rb = reg(a[0], no), reg(a[1], no), reg(a[2], no)
                sh = value(a[3], no) if len(a) > 3 else 0
                if sh not in SHIFTS:
                    raise AsmError(f"line {no}: mul shift {sh} not in {SHIFTS}")
                imm = SHIFTS.index(sh)
            elif mn in ("hi12", "sin"):
                d, ra = reg(a[0], no), reg(a[1], no)
            elif mn in ("beq", "bne", "blt", "bge", "bltu"):
                ra, rb, imm = reg(a[0], no), reg(a[1], no), value(a[2], no)
            elif mn == "jal":
                d, imm = reg(a[0], no), value(a[1], no)
            elif mn == "jr":
                ra = reg(a[0], no)
            elif mn == "in":
                d, imm = reg(a[0], no), value(a[1], no)
            elif mn == "out":
                imm, ra = value(a[0], no), reg(a[1], no)
            else:
                raise AsmError(f"line {no}: unknown instruction {mn!r}")
        except IndexError:
            raise AsmError(f"line {no}: too few operands for {mn}")
        if op in ("addi", "ldr", "ldrs", "ldm", "stm"):
            if not -32768 <= imm <= 65535:
                raise AsmError(f"line {no}: immediate {imm} out of range")
        elif not 0 <= imm <= 65535:
            raise AsmError(f"line {no}: immediate {imm} out of range")
        if d == 0 and op not in ("add", "jal", "out", "stm", "beq", "bne", "blt", "bge", "bltu", "jr") \
                and mn not in ("nop",):
            raise AsmError(f"line {no}: writes r0")
        words.append((OP[op] << 35) | (d << 29) | (ra << 23) | (rb << 17) | (imm & 0xFFFF))
    if len(words) > IROM_WORDS:
        raise AsmError(f"program has {len(words)} words, more than {IROM_WORDS}")
    return words, labels, regs, prog


# ---------------------------------------------------------------- emulator
class Engine:
    """Clock-accurate: instruction i starts at clock 4i. A tick is raised at
    every clock where the divider wraps; `in 0` sees and clears the flags at
    the instruction's last clock (a tick raised on that same clock stays).
    Bytes reach the FIFO at given clocks (push(clk, byte)); `in` sees a byte
    whose clock is at or before the instruction's last clock."""

    def __init__(self, words, rom, div=874):
        self.iw = words
        self.rom = rom
        self.div = div
        self.mem = [0] * 256
        self.pc = 0
        self.clk = 0
        self.tick = 0
        self.abort = 0
        self.ready = 0
        self.fifo = []
        self.events = []          # (clk, kind, value), sorted: kind "byte", "abort", "ready"
        self.lfsr = 0xACE1
        self.out = []             # (clk, sample)
        self.icount = 0
        self.missed = 0           # ticks raised while one was still pending

    def push_now(self, byte):
        """A byte into the FIFO now, seen from the next instruction."""
        self.schedule(self.clk - 1, "byte", byte)
        self._advance(self.clk - 1)

    def schedule(self, clk, kind, value=0):
        self.events.append((clk, kind, value))
        self.events.sort(key=lambda e: e[0])

    def _wraps(self, c0, c1):
        """Does the tick divider wrap on any clock in c0..c1? It counts
        0..div-1 from clock 0 and wraps on clocks div-1, 2*div-1, ..."""
        return c1 >= c0 and (c1 + 1) // self.div > c0 // self.div

    def _advance(self, upto):
        """Apply ticks and external events for clocks <= upto."""
        while self.events and self.events[0][0] <= upto:
            c, kind, v = self.events.pop(0)
            if kind == "byte":
                if len(self.fifo) < 64:
                    self.fifo.append(v)
            elif kind == "abort":
                self.fifo = []
                self.abort = 1
            elif kind == "ready":
                self.ready = 1

    def step(self):
        w = self.iw[self.pc]
        op = OPS[w >> 35]
        d = (w >> 29) & 63
        a = self.mem[(w >> 23) & 63]
        b = self.mem[(w >> 17) & 63]
        imm = w & 0xFFFF
        last = self.clk + CLK_PER_INSTR - 1
        # Registers change at the end of a clock: a tick or byte "at clock c"
        # is seen by reads in later clocks. This instruction reads at its last
        # clock, so it sees what happened up to last - 1.
        if self._wraps(self.clk, last - 1):
            self.missed += self.tick
            self.tick = 1
        self._advance(last - 1)
        npc = self.pc + 1
        res = None
        if op == "add": res = a + b
        elif op == "sub": res = a - b
        elif op == "and": res = a & b
        elif op == "or": res = a | b
        elif op == "xor": res = a ^ b
        elif op == "addi": res = a + sx(imm, 16)
        elif op == "andi": res = a & imm
        elif op == "ori": res = a | imm
        elif op == "lui": res = imm << 16
        elif op == "mul":
            p = sx(a, 27) * sx(b, 27)
            res = p >> SHIFTS[imm & 3]
        elif op == "hi12": res = (a >> 20) & 0xFFF
        elif op == "sin": res = self.rom[(a >> 22) & 0x1FF]
        elif op == "ldr": res = self.rom[(a + sx(imm, 16)) & (ROM_WORDS - 1)]
        elif op == "ldrs": res = sx(self.rom[(a + sx(imm, 16)) & (ROM_WORDS - 1)], 20)
        elif op == "ldm": res = self.mem[(a + sx(imm, 16)) & 255]
        elif op == "stm":
            addr = (a + sx(imm, 16)) & 255
            if addr:
                self.mem[addr] = b
        elif op in ("beq", "bne", "blt", "bge", "bltu"):
            sa, sb = s32(a), s32(b)
            take = {"beq": a == b, "bne": a != b, "blt": sa < sb, "bge": sa >= sb,
                    "bltu": a < b}[op]
            if take:
                npc = imm
        elif op == "jal":
            res = self.pc + 1
            npc = imm
        elif op == "jr":
            npc = a & (IROM_WORDS - 1)
        elif op == "in":
            if imm == 0:
                res = self.tick | (self.abort << 2) | (self.ready << 3)
                self.tick = self.abort = self.ready = 0
            elif imm == 1:
                res = self.fifo.pop(0) if self.fifo else 0
            elif imm == 2:
                res = self.lfsr
                bit = ((self.lfsr >> 0) ^ (self.lfsr >> 2) ^ (self.lfsr >> 3) ^ (self.lfsr >> 5)) & 1
                self.lfsr = (self.lfsr >> 1) | (bit << 15)
            elif imm == 3:
                res = 1 if self.fifo else 0
            else:
                res = 0
        elif op == "out":
            self.out.append((last, s32(a)))
        if res is not None and d:
            self.mem[d] = res & M32
        # events on the last clock land after this instruction's reads and
        # clears (a set on the same edge as a clear wins)
        if self._wraps(last, last):
            self.missed += self.tick
            self.tick = 1
        self._advance(last)
        self.pc = npc & (IROM_WORDS - 1)
        self.clk += CLK_PER_INSTR
        self.icount += 1

    def run_until(self, clk):
        while self.clk < clk:
            self.step()
