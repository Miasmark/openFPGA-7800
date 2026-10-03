#!/usr/bin/env python3
"""Random-encoding test for the BupChip CPU, as assembler on stdout.

  fuzz.py SEED [CELLS] > fuzz.S          CELLS cells (default 450)

Each cell loads r0-r7 and r10 from one of 16 value tables (edge values for
the adder, the shifter and the multiplier, plus random words), points r8 at
a base (RAM, the asset window or a ROM table, aligned or not), puts a small
offset in r9 and sets NZCV, in a random order and sometimes followed by a
load from the table, so that the encoding often reads a register or the
flags written in the clock before. Then it runs one encoding drawn from
every ARM instruction class except branches: data processing in every
operand form with any opcode and S bit, the multiply space (all of bits
23:20), single, halfword and block transfers with random P/U/B/W/L/S/H
bits, the PSR space, SWP, coprocessor and undefined space, and raw random
words. Conditions are AL mostly, any of the 16 otherwise. The encoding is a
.word labelled fz<k>, so that fuzz_run.py can find it.

fuzz_run.py (run.sh calls it) runs the program on the new core (tb_s1.sv)
and replaces every encoding the core halts on with a NOP, rerunning until
the core reaches the end marker; the result must then run in lockstep with
the reference. The core may halt on anything (docs/BUPCHIP_CORE.md: exact
or halt), but what it does not halt on must match the ARM7TDMI. The same
SEED and CELLS always give the same program. Needs the 1 KiB asset image
that run.sh makes.
"""
import random
import sys

seed = int(sys.argv[1])
ncells = int(sys.argv[2]) if len(sys.argv) > 2 else 450
R = random.Random(seed)

EDGE = [0, 1, 2, 3, 0x1f, 0x20, 0x21, 0xff, 0x100, 0x120, 0x1ff, 0xffffff20, 0xffffff00,
        0x7fffffff, 0x80000000, 0x80000001, 0x7ffffffe, 0xffffffff, 0xfffffffe, 0x40000000,
        0x0000ffff, 0xffff0000, 0x00008000, 0xffff8000, 0x55555555, 0xaaaaaaaa]


def val():
    k = R.random()
    if k < 0.5:
        return R.choice(EDGE)
    if k < 0.65:
        return R.randrange(64)
    return R.getrandbits(32)


TABLES = [[val() for _ in range(9)] for _ in range(16)]
DATA = 0x40002000
ASSET = 0x02000000
# bases for r8: RAM (aligned and not), the asset window (loads only), a ROM table
BASES = [DATA + 0x400, DATA + 0x401, DATA + 0x402, DATA + 0x403, DATA + 0x800,
         ASSET + 0x200, ASSET + 0x201, ASSET + 0x203, "tbl0", "tbl0+1"]


def cond():
    k = R.random()
    if k < 0.7:
        return 0xE
    return R.randrange(16)


def reg(pc_chance=0.04):
    if R.random() < pc_chance:
        return 15
    return R.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])


def rd(pc_chance=0.02):
    return reg(pc_chance)


def dp():
    c = cond()
    form = R.randrange(3)
    op = R.randrange(16)
    s = R.randrange(2) if op < 8 or op >= 12 else (1 if R.random() < 0.9 else 0)
    w = c << 28 | op << 21 | s << 20 | reg() << 16 | rd() << 12
    if form == 0:                                  # rotated immediate
        return w | 1 << 25 | R.randrange(16) << 8 | R.randrange(256)
    if form == 1:                                  # shift by immediate (incl. the amount-0 encodings)
        amt = R.choice([0, 0, 1, 2, 31, R.randrange(32)])
        return w | amt << 7 | R.randrange(4) << 5 | reg()
    return w | reg(0.02) << 8 | R.randrange(4) << 5 | 1 << 4 | reg()   # shift by register


def mul():
    c = cond()
    if R.random() < 0.5:                           # MUL/MLA space (bits 23:22 = 00)
        top = R.choice([0b000000, 0b000000, 0b000001, 0b000010, 0b000011])   # A, S
        return c << 28 | top << 20 | rd() << 16 | reg() << 12 | reg() << 8 | 0x90 | reg()
    bits = R.choice([0b1000, 0b1000, 0b1000, 0b1001, 0b1010, 0b1100, 0b1110, R.randrange(8, 16)])
    hi, lo = rd(), rd()
    if R.random() < 0.85:
        while lo == hi:
            lo = rd()
    return c << 28 | bits << 20 | hi << 16 | lo << 12 | reg() << 8 | 0x90 | reg()


def base():
    return 8 if R.random() < 0.93 else R.choice([9, 15, 0])


def sdt():
    c = cond()
    p, u, b, w, l = (R.randrange(2) for _ in range(5))
    d = rd(0.0) if l else rd(0.03)
    word = c << 28 | 1 << 26 | p << 24 | u << 23 | b << 22 | w << 21 | l << 20 | base() << 16 | d << 12
    if R.random() < 0.5:
        return word | R.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 0x40, 0x3ff, R.randrange(4096)])
    amt = R.choice([0, 0, 1, 2, 31])
    return word | 1 << 25 | amt << 7 | R.randrange(4) << 5 | (9 if R.random() < 0.9 else reg())


def xh():
    c = cond()
    p, u, i, w, l = (R.randrange(2) for _ in range(5))
    sh = R.randrange(1, 4)                         # 01 H, 10 SB, 11 SH (LDRD/STRD when L = 0)
    d = rd(0.0) if l else rd(0.03)
    word = c << 28 | p << 24 | u << 23 | i << 22 | w << 21 | l << 20 | base() << 16 | d << 12 | 1 << 7 | sh << 5 | 1 << 4
    if i:
        off = R.choice([0, 1, 2, 3, 6, 7, 0x41, R.randrange(256)])
        return word | (off >> 4) << 8 | (off & 15)
    sbz = 0 if R.random() < 0.8 else R.randrange(16)
    return word | sbz << 8 | (9 if R.random() < 0.9 else reg())


def blk():
    c = cond()
    p, u, s, w, l = R.randrange(2), R.randrange(2), int(R.random() < 0.08), R.randrange(2), R.randrange(2)
    lst = R.getrandbits(15) if R.random() < 0.7 else R.choice([1 << R.randrange(15), 0x0100, 0x0300, 0x7fff])
    if R.random() < 0.04:
        lst |= 0x8000
    if R.random() < 0.02:
        lst = 0
    rn = 8 if R.random() < 0.95 else R.choice([13, 15, 9])
    return c << 28 | 0b100 << 25 | p << 24 | u << 23 | s << 22 | w << 21 | l << 20 | rn << 16 | lst


def psr():
    c = cond()
    r = int(R.random() < 0.1)
    k = R.random()
    if k < 0.3:                                    # MRS
        w = c << 28 | 0x010F0000 | r << 22 | rd() << 12
        if R.random() < 0.1:
            w |= R.getrandbits(12)
        return w
    mask = R.choice([0b1000, 0b0001, 0b1001, R.randrange(16)])
    if k < 0.65:                                   # MSR register
        w = c << 28 | 0x0120F000 | r << 22 | mask << 16 | reg()
        if R.random() < 0.1:
            w |= R.getrandbits(8) << 4
        return w
    rot, imm = R.choice([(0, 0xD3), (2, 0xF0), (4, 0x0F), (2, 0x50), (R.randrange(16), R.randrange(256))])
    return c << 28 | 0x0320F000 | r << 22 | mask << 16 | rot << 8 | imm


def misc():
    """The rest of the 000 space with bit 24:23 = 10 and S = 0, SWP, and the 11x groups."""
    c = cond()
    k = R.random()
    if k < 0.4:
        return c << 28 | 0b00010 << 23 | R.getrandbits(23) & ~(1 << 20)
    if k < 0.6:                                    # SWP / SWPB and the rest of 0001 0xx0 .... 1001
        return c << 28 | 0x01000090 | R.randrange(2) << 22 | base() << 16 | rd() << 12 | reg()
    if k < 0.8:                                    # media/undefined (011 with bit 4 set)
        return c << 28 | 0x06000010 | R.getrandbits(25) & 0x01FFFFEF
    return c << 28 | (0b11 << 26) | R.getrandbits(26)   # coprocessor, SWI


def raw():
    while True:
        w = R.getrandbits(32)
        if R.random() < 0.8:
            w = (w & 0x0FFFFFFF) | 0xE0000000
        grp = (w >> 25) & 7
        if grp == 0b101:
            continue                               # branches: they would leave the cell
        if grp in (0b010, 0b011) and (w >> 20) & 1 and (w >> 12) & 15 == 15:
            continue                               # LDR pc
        if grp == 0b100 and (w >> 20) & 1 and (w >> 15) & 1:
            continue                               # LDM with pc
        if w & 0x0FFFFFF0 == 0x012FFF10:
            continue                               # BX
        return w


KINDS = [(dp, 30), (mul, 10), (sdt, 15), (xh, 15), (blk, 10), (psr, 6), (misc, 6), (raw, 8)]


def pick():
    t = R.randrange(sum(k for _, k in KINDS))
    for f, k in KINDS:
        if t < k:
            return f()
        t -= k


print(f"@ generated by fuzz.py {seed} {ncells}")
print('\t.syntax unified\n\t.arm\n\t.cpu arm7tdmi\n\t.section .vectors, "ax"\n\t.global _start')
print("_start:\tb\treset\n" + "\tb\t.\n" * 7 + "\t.text\nreset:")
for s in ["mrs\tr0, cpsr", "bic\tr0, r0, #31", "orr\tr0, r0, #0xd3", "msr\tcpsr_c, r0",
          "ldr\tsp, =__stack_top", "ldr\tr12, =0x40002000", "ldr\tr0, =0x83828180", "ldr\tr1, =0x04040404",
          "mov\tr2, #0", "1:\tstr\tr0, [r12, r2]", "add\tr0, r0, r1", "add\tr2, r2, #4",
          "cmp\tr2, #4096", "bne\t1b"]:
    print(("\t" if not s.startswith("1:") else "") + s)
for k in range(ncells):
    if k % 40 == 0:
        print("\tb\t2f\n\t.ltorg\n2:")
    t = R.randrange(16)
    b = R.choice(BASES)
    off = R.choice([0, 1, 2, 3, 4, 7, 8, 12, 16, 0x40])
    setup = [f"ldr\tr8, ={b if isinstance(b, str) else hex(b)}",
             f"{'mvn' if R.random() < 0.3 else 'mov'}\tr9, #{off}",
             f"msr\tcpsr_f, #0x{R.randrange(16) << 28:08x}"]
    R.shuffle(setup)                               # r8, r9 or NZCV written just before
    k2 = R.random()                                # or a register loaded just before
    if k2 < 0.25:
        rl = R.choice([0, 1, 2, 3, 4, 5, 6, 7])
        setup.append(f"ldr\tr{rl}, [r12, #{4 * rl}]")
    elif k2 < 0.35:
        lo = R.randrange(8)
        setup.append(f"ldmia\tr12, {{r{lo}-r7}}" if lo < 7 else "ldmia\tr12, {r7}")
    print(f"\tldr\tr12, =tbl{t}")
    print("\tldmia\tr12, {r0-r7, r10}")
    for s in setup:
        print("\t" + s)
    print(f"fz{k}:\t.word\t0x{pick():08x}")
print("\tb\t3f\n\t.ltorg")
for t, vals in enumerate(TABLES):
    print(f"tbl{t}:\t.word\t" + ", ".join(f"0x{v:08x}" for v in vals))
print("""3:	ldr	r1, =0xE0009000
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.
	.ltorg""")
