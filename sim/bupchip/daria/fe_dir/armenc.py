#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Hand encoders for the few Thumb and ARM (ARMv4T) instructions the
daria_fe directed tests' ARM calls need, a two-pass layout with labels and a
literal pool, and the one call routine every synthetic image carries.

The call routine (call_routine) is a tiny script interpreter, entered in
Thumb state at the scheme's call entry with upstream's call state (r0-r12 = 0,
SP = the scheme's stack, LR = 0xF0000000, SYS mode; the audio counters in FIQ
r8-r10 and the frequencies in FIQ r11-r13). Each call bumps a call counter in
cart RAM and runs script[min(count, n-1)] from a table in ROM. A script is a
list of 4-word entries (op, a, b, c):
    0  END                            return (BX LR to the sentinel)
    1  W8   a = address, b = byte     STRB
    2  W16  a, b                      STRH
    3  W32  a, b                      STR
    4  FSET a = FIQ register 8..13,   set that FIQ register (ARM state, FIQ
            b = value                 mode, then back to SYS and Thumb)
    5  ADD32 a, b                     *a += b (word)
    6  COPY a = dst, b = src,         c words, LDR/STR (word aligned)
            c = words
    7  FILL a = dst, b = word,        c words
            c = words
    8  FADD a = FIQ register, b       add b to that FIQ register
So "return", "change frequencies" (FSET 11..13), "rewrite a waveform pointer"
(W32 to the scheme's waveform base) and "write cart RAM" (W8..FILL) are all
scripts of this one routine. No game data: every byte is generated here.
"""

COND = {'eq': 0, 'ne': 1, 'cs': 2, 'cc': 3, 'mi': 4, 'pl': 5, 'hi': 8, 'ls': 9,
        'ge': 10, 'lt': 11, 'gt': 12, 'le': 13, 'al': 14}


class Code:
    """Items are (size, emit(pc, labels) -> bytes). Labels are byte addresses."""

    def __init__(self, base):
        self.base = base
        self.items = []
        self.pool = []          # pending literal values (int or label name)
        self.labels = {}

    # ---- layout primitives
    def label(self, name):
        self.items.append(('label', name))

    def h(self, fn):
        self.items.append((2, lambda pc, L: fn(pc, L).to_bytes(2, 'little')))

    def w(self, fn):
        self.items.append((4, lambda pc, L: (fn(pc, L) & 0xFFFFFFFF).to_bytes(4, 'little')))

    def word(self, v):
        self.w(lambda pc, L, v=v: L[v] if isinstance(v, str) else v)

    def align4(self, thumb_pad=True):
        self.items.append(('align', thumb_pad))

    # ---- Thumb
    def movs(self, rd, imm):
        self.h(lambda pc, L: 0x2000 | rd << 8 | imm)

    def cmpi(self, rd, imm):
        self.h(lambda pc, L: 0x2800 | rd << 8 | imm)

    def addsi(self, rd, imm):
        self.h(lambda pc, L: 0x3000 | rd << 8 | imm)

    def subsi(self, rd, imm):
        self.h(lambda pc, L: 0x3800 | rd << 8 | imm)

    def adds3(self, rd, rn, imm3):
        self.h(lambda pc, L: 0x1C00 | imm3 << 6 | rn << 3 | rd)

    def subs3(self, rd, rn, imm3):
        self.h(lambda pc, L: 0x1E00 | imm3 << 6 | rn << 3 | rd)

    def addsr(self, rd, rn, rm):
        self.h(lambda pc, L: 0x1800 | rm << 6 | rn << 3 | rd)

    def cmpr(self, rn, rm):
        self.h(lambda pc, L: 0x4280 | rm << 3 | rn)

    def lsls(self, rd, rm, imm5):
        self.h(lambda pc, L: 0x0000 | imm5 << 6 | rm << 3 | rd)

    def ldr(self, rd, rn, off):      # word offset in bytes
        self.h(lambda pc, L: 0x6800 | (off >> 2) << 6 | rn << 3 | rd)

    def str_(self, rd, rn, off):
        self.h(lambda pc, L: 0x6000 | (off >> 2) << 6 | rn << 3 | rd)

    def ldrb(self, rd, rn, off):
        self.h(lambda pc, L: 0x7800 | off << 6 | rn << 3 | rd)

    def strb(self, rd, rn, off):
        self.h(lambda pc, L: 0x7000 | off << 6 | rn << 3 | rd)

    def strh(self, rd, rn, off):
        self.h(lambda pc, L: 0x8000 | (off >> 1) << 6 | rn << 3 | rd)

    def ldrr(self, rd, rn, rm):
        self.h(lambda pc, L: 0x5800 | rm << 6 | rn << 3 | rd)

    def bx(self, rm):
        self.h(lambda pc, L: 0x4700 | rm << 3)

    def nop(self):
        self.h(lambda pc, L: 0x46C0)

    def b(self, lab):
        def f(pc, L):
            d = L[lab] - (pc + 4)
            assert -2048 <= d < 2048 and d % 2 == 0, d
            return 0xE000 | (d >> 1) & 0x7FF
        self.h(f)

    def bc(self, cond, lab):
        def f(pc, L):
            d = L[lab] - (pc + 4)
            assert -256 <= d < 256 and d % 2 == 0, d
            return 0xD000 | COND[cond] << 8 | (d >> 1) & 0xFF
        self.h(f)

    def ldr_eq(self, rd, val):
        """LDR rd, =val (Thumb PC-relative literal from the next pool)."""
        idx = len(self.pool)
        self.pool.append(val)
        name = '__lit%d_%d' % (id(self), idx)
        self._pool_names = getattr(self, '_pool_names', [])
        self._pool_names.append(name)

        def f(pc, L):
            d = L[name] - ((pc + 4) & ~3)
            assert 0 <= d < 1024 and d % 4 == 0, d
            return 0x4800 | rd << 8 | d >> 2
        self.h(f)

    def literal_pool(self):
        self.align4()
        for name, val in zip(self._pool_names, self.pool):
            self.label(name)
            self.word(val)
        self.pool = []
        self._pool_names = []

    # ---- ARM
    def arm(self, word):
        self.w(lambda pc, L: word)

    def arm_b(self, lab, cond='al'):
        def f(pc, L):
            d = L[lab] - (pc + 8)
            return COND[cond] << 28 | 0x0A000000 | (d >> 2) & 0xFFFFFF
        self.w(f)

    def arm_ldr_lit(self, rd, lab):
        def f(pc, L):
            d = L[lab] - (pc + 8)
            assert 0 <= d < 4096
            return 0xE59F0000 | rd << 12 | d
        self.w(f)

    # ---- layout
    def build(self):
        for pas in (1, 2):
            pc = self.base
            out = bytearray()
            for it in self.items:
                if it[0] == 'label':
                    self.labels[it[1]] = pc
                    continue
                if it[0] == 'align':
                    while pc % 4:
                        out += (0x46C0).to_bytes(2, 'little') if it[1] else b'\0\0'
                        pc += 2
                    continue
                size, emit = it
                if pas == 2:
                    bs = emit(pc, self.labels)
                    assert len(bs) == size
                    out += bs
                else:
                    out += bytes(size)
                pc += size
        return bytes(out), dict(self.labels)


def arm_cmp_imm(rn, imm):
    return 0xE3500000 | rn << 16 | imm


def arm_mov_reg(rd, rm, cond='al'):
    return COND[cond] << 28 | 0x01A00000 | rd << 12 | rm


def arm_add_reg(rd, rn, rm, cond='al'):
    return COND[cond] << 28 | 0x00800000 | rn << 16 | rd << 12 | rm


def arm_msr_c(imm):
    return 0xE321F000 | imm


OP_END, OP_W8, OP_W16, OP_W32, OP_FSET, OP_ADD32, OP_COPY, OP_FILL, OP_FADD = range(9)


def call_routine(base, cnt_addr, scripts):
    """The interpreter at `base` (the entry, Thumb), its ARM helper, the script
    table and the scripts. scripts: list of lists of (op, a, b, c).
    Returns (bytes, labels)."""
    c = Code(base)
    c.label('entry')
    c.ldr_eq(0, cnt_addr)
    c.ldr(1, 0, 0)
    c.adds3(2, 1, 1)
    c.str_(2, 0, 0)
    c.ldr_eq(3, len(scripts))
    c.cmpr(1, 3)
    c.bc('cc', 'sel')
    c.subs3(1, 3, 1)
    c.label('sel')
    c.lsls(1, 1, 2)
    c.ldr_eq(3, 'table')
    c.ldrr(5, 3, 1)
    c.label('loop')
    c.ldr(6, 5, 0)
    c.ldr(1, 5, 4)
    c.ldr(2, 5, 8)
    c.ldr(4, 5, 12)
    c.addsi(5, 16)
    c.cmpi(6, OP_END)
    c.bc('eq', 'done')
    c.cmpi(6, OP_W8)
    c.bc('eq', 'w8')
    c.cmpi(6, OP_W16)
    c.bc('eq', 'w16')
    c.cmpi(6, OP_W32)
    c.bc('eq', 'w32')
    c.cmpi(6, OP_ADD32)
    c.bc('eq', 'add32')
    c.cmpi(6, OP_COPY)
    c.bc('eq', 'copy')
    c.cmpi(6, OP_FILL)
    c.bc('eq', 'fill')
    # OP_FSET / OP_FADD: the ARM helper
    c.ldr_eq(7, 'armhelp')
    c.bx(7)
    c.label('w8')
    c.strb(2, 1, 0)
    c.b('loop')
    c.label('w16')
    c.strh(2, 1, 0)
    c.b('loop')
    c.label('w32')
    c.str_(2, 1, 0)
    c.b('loop')
    c.label('add32')
    c.ldr(7, 1, 0)
    c.addsr(7, 7, 2)
    c.str_(7, 1, 0)
    c.b('loop')
    c.label('copy')
    c.ldr(7, 2, 0)
    c.str_(7, 1, 0)
    c.addsi(1, 4)
    c.addsi(2, 4)
    c.subsi(4, 1)
    c.bc('ne', 'copy')
    c.b('loop')
    c.label('fill')
    c.str_(2, 1, 0)
    c.addsi(1, 4)
    c.subsi(4, 1)
    c.bc('ne', 'fill')
    c.b('loop')
    c.label('done')
    c.bx(14)
    c.literal_pool()
    # ARM helper: FIQ mode, set or add FIQ r8..r13, back to SYS, return to the
    # Thumb loop. r1 = register number, r2 = value, r6 = op.
    c.align4()
    c.label('armhelp')
    c.arm(arm_msr_c(0xD1))
    c.arm(arm_cmp_imm(6, OP_FSET))
    c.arm_b('fset', 'eq')
    for r in range(8, 14):
        c.arm(arm_cmp_imm(1, r))
        c.arm(arm_add_reg(r, r, 2, 'eq'))
    c.arm_b('back')
    c.label('fset')
    for r in range(8, 14):
        c.arm(arm_cmp_imm(1, r))
        c.arm(arm_mov_reg(r, 2, 'eq'))
    c.label('back')
    c.arm(arm_msr_c(0x1F))
    c.arm_ldr_lit(7, 'loopaddr')
    c.arm(0xE12FFF17)               # BX r7
    c.label('loopaddr')
    c.w(lambda pc, L: L['loop'] | 1)
    # script table and scripts
    c.label('table')
    for i in range(len(scripts)):
        c.word('s%d' % i)
    for i, s in enumerate(scripts):
        c.label('s%d' % i)
        for e in list(s) + [(OP_END, 0, 0, 0)]:
            e = tuple(e) + (0,) * (4 - len(e))
            for v in e:
                c.word(v)
    return c.build()


if __name__ == '__main__':
    bs, labs = call_routine(0xC08, 0x40000800,
                            [[], [(OP_W32, 0x40000C00, 0x11223344), (OP_FSET, 11, 0x1000)]])
    print(len(bs), {k: hex(v) for k, v in labs.items() if not k.startswith('__')})
    for i in range(0, 64, 2):
        print('%04X' % int.from_bytes(bs[i:i + 2], 'little'), end=' ')
    print()
