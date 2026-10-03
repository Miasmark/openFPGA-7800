#!/usr/bin/env python3
"""Dense random programs for the BupChip CPU, as assembler on stdout.

  vrand.py SEED [OPS] [--iss] > vrandSEED.S     OPS operations (default 1800)

The other random tests keep instructions apart: gen_random.py stores every
result to the signature before the next operation, and fuzz.py sets up a
known state before each encoding. Here the operations follow each other
directly and read what the last few wrote, so the core's multi-clock
instructions run back to back in every order: a load straight into the
next operand, base or store data, a multiply after an LDM, an STM of a
register written the clock before, LDR pc after a flag-setting compare.
run_vrand.sh runs each program in lockstep with the reference
(tb_lockstep.sv), which compares every retire, store and peripheral
access, plainly and with asset waits and throttle clocks.

Every operation is one the ARM7TDMI defines and the core implements:
data processing in every operand form (shift amounts 0-31 by immediate,
so LSR #32, ASR #32 and RRX too, and 0-255 by register; r15 as Rn or Rm),
any opcode, S or not; MUL, MLA and UMULL; LDR/STR/LDRB/STRB and the
halfword and signed forms at any byte offset (unaligned word and odd
halfword accesses take the ARM7TDMI's rotations), immediate and register
offsets, pre and post index, write-back, Rd == Rn; LDM/STM in the four
modes with and without write-back, the base in the list too (STM, or LDM
without write-back); push/pop,
conditional pops; loads from the ROM, the asset window and the
peripheral; MRS, MSR of the flags and of the fixed control byte; forward
B, BL and BX, LDR pc (from a literal and popped from the stack), all of
them conditional at times. About a quarter of the operations are
conditional, and a third of the data-processing ones set the flags.

--iss keeps to what ARMv4 and ARMv5 do alike, so that Unicorn can run the
program too (../isa/run_isa.sh): accesses aligned to their size, base
registers kept word-aligned, no Rd == Rn with write-back, no base in a
block-transfer list, no peripheral or asset-window access. Every 40
operations, and at the end, r0-r9, lr and the CPSR are stored below the
random data (0x40000040 onwards, in the signature run_isa.sh compares), and
the random stores themselves land partly inside it.

Register roles: r0-r9 and r14 data; r10 a pointer into the ROM, the asset
window or the peripheral, loaded just before it is used; r11 and r12 RAM
bases, around 0x40001400 and 0x40002400, reset whenever their write-backs
may have taken them more than 512 bytes away or a load may have overwritten
them; sp the stack. RAM from 0x40000a00 to 0x40002e00, everything the bases
can reach, starts with random words. The lockstep runs need the 1 KiB asset
image that run.sh makes. The same arguments always give the same program.

SPDX-License-Identifier: MIT
"""
import random
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
ISS = "--iss" in sys.argv
seed = int(args[0])
nops = int(args[1]) if len(args) > 1 else 1800
R = random.Random(seed * 2 + int(ISS))

DATA = [f"r{i}" for i in range(10)] + ["lr"]
CONDS = ["eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]
INVERSE = dict(zip(CONDS, ["ne", "eq", "cc", "cs", "pl", "mi", "vc", "vs", "ls", "hi", "lt", "ge", "le", "gt"]))
DP3 = ["and", "eor", "sub", "rsb", "add", "adc", "sbc", "rsc", "orr", "bic"]
DP2 = ["mov", "mvn"]
CMP = ["cmp", "cmn", "tst", "teq"]
SH = ["lsl", "lsr", "asr", "ror"]
ANCHOR = {"r11": 0x40001400, "r12": 0x40002400}
DUMP = 0x40000040               # register dumps, 12 words each, below the random data
ASSET_BYTES = 1024
MMIO_READ = [0x00, 0x04, 0x08, 0x14, 0x00, 0x08, 0x20, 0x40]

out = []
recent = []                     # the last registers written, most recent last
drift = {"r11": 0, "r12": 0}    # how far write-backs may have moved each base
label = [0]
in_sub = [False]                # inside a BL subroutine: lr is not data there
dumps = [0]


def emit(s):
    out.append("\t" + s)


def newlabel():
    label[0] += 1
    return f"L{label[0]}"


def wrote(reg):
    recent.append(reg)
    del recent[:-4]


def data_regs():
    return [r for r in DATA if not (in_sub[0] and r == "lr")]


def src():
    """A source register, often one written in the last few operations."""
    if recent and R.random() < 0.55:
        r = R.choice(recent)
        if r in data_regs():
            return r
    return R.choice(data_regs())


def dst():
    return R.choice(data_regs())


def cond(p=0.25):
    return R.choice(CONDS) if R.random() < p else ""


def imm8r():
    v, rot = R.randrange(256), 2 * R.randrange(16)
    return ((v >> rot) | (v << (32 - rot))) & 0xffffffff


def op2(allow_pc=True):
    """Operand 2 and whether it is a shift by register."""
    k = R.random()
    if k < 0.25:
        return src(), False
    if k < 0.40:
        return f"#{imm8r():#x}", False
    if k < 0.80:
        s = R.choice(SH)
        rm = "pc" if allow_pc and R.random() < 0.03 else src()
        amt = R.choice([0, 1, 2, 31, R.randrange(32)])
        if amt == 0:
            # the amount-0 encodings: LSL #0, LSR #32, ASR #32, RRX
            return {"lsl": f"{rm}", "lsr": f"{rm}, lsr #32", "asr": f"{rm}, asr #32",
                    "ror": f"{rm}, rrx"}[s], False
        return f"{rm}, {s} #{amt}", False
    return f"{src()}, {R.choice(SH)} {src()}", True     # shift by register: no pc


def anchor(base):
    emit(f"ldr\t{base}, ={ANCHOR[base]:#x}")
    drift[base] = 0


def check_drift():
    for b in ("r11", "r12"):
        if drift[b] > 512:
            anchor(b)


def dump():
    """r0-r9, lr and the CPSR to the next dump slot (r0 kept on the stack)."""
    emit(f"ldr\tr10, ={DUMP + 48 * dumps[0]:#x}")
    emit("stmia\tr10!, {r0-r9, lr}")
    emit("str\tr0, [sp, #-4]!")
    emit("mrs\tr0, cpsr")
    emit("str\tr0, [r10]")
    emit("ldr\tr0, [sp], #4")
    dumps[0] += 1


def op_dp():
    c = cond()
    k = R.random()
    o2, rsh = op2()
    s = "s" if R.random() < 0.33 else ""
    if k < 0.65:
        rn = "pc" if not rsh and R.random() < 0.03 else src()
        if rn == "pc" and o2.startswith("#"):
            o2 = src()          # gas reads "op rd, pc, #imm" as an address expression
        d = dst()
        emit(f"{R.choice(DP3)}{s}{c}\t{d}, {rn}, {o2}")
        wrote(d)
    elif k < 0.85:
        d = dst()
        emit(f"{R.choice(DP2)}{s}{c}\t{d}, {o2}")
        wrote(d)
    else:
        rn = "pc" if not rsh and R.random() < 0.03 else src()
        if rn == "pc" and o2.startswith("#"):
            o2 = src()
        emit(f"{R.choice(CMP)}{c}\t{rn}, {o2}")


def op_mul():
    c = cond()
    k = R.random()
    if k < 0.15:
        lo, hi = R.sample(data_regs(), 2)
        m = src()
        while m in (lo, hi):    # UMULL with RdLo or RdHi == Rm is UNPREDICTABLE (v_unpred has it)
            m = R.choice(data_regs())
        emit(f"umull{c}\t{lo}, {hi}, {m}, {src()}")
        wrote(lo)
        wrote(hi)
        return
    d = dst()
    m = src()
    while m == d:               # MUL/MLA Rd == Rm is UNPREDICTABLE (v_unpred has it)
        m = R.choice(data_regs())
    if k < 0.55:
        emit(f"mul{c}\t{d}, {m}, {src()}")
    else:
        emit(f"mla{c}\t{d}, {m}, {src()}, {src()}")
    wrote(d)


def offset_reg(mask):
    """A data register turned into a small offset just before it is used."""
    r = dst()
    emit(f"and\t{r}, {src()}, #{mask:#x}")
    wrote(r)
    return r


def op_ram(half):
    c = cond()
    b = R.choice(["r11", "r12"])
    load = R.random() < 0.6
    if half:
        mn = R.choice(["ldrh", "ldrsh", "ldrsb"]) if load else "strh"
        size = 1 if mn == "ldrsb" else 2
    else:
        mn = R.choice(["ldr", "ldrb", "ldr"]) if load else R.choice(["str", "strb", "str"])
        size = 1 if mn.endswith("b") else 4
    form = R.random()
    wb = form >= 0.6
    rd = b if R.random() < 0.06 and not (ISS and wb) else (dst() if load else src())
    if R.random() < 0.35:                          # register offset
        if half:
            rm = offset_reg(R.choice([0x7c, 0xfc, 0x1fc] if ISS else [0x7c, 0xff, 0x1fc, 0x3f]))
            off, reach = f"{R.choice(['', '-'])}{rm}", 0x1fc
        else:
            rm = offset_reg(R.choice([0x7c, 0xfc, 0x1fc] if ISS else [0x7c, 0xfc, 0x1fc, 0xff, 0x3f, 0x1f]))
            shifts = ["", ", lsl #1", ", lsl #2"] + ([] if ISS else [", lsr #1", ", asr #2"])
            off, reach = f"{R.choice(['', '-'])}{rm}{R.choice(shifts)}", 0x7fc
    else:
        v = R.choice([0, 1, 2, 3, R.randrange(256)])
        if ISS:                 # aligned to the access, and the base stays word-aligned
            v &= ~3 if wb else ~(size - 1)
        off, reach = f"#{R.choice(['', '-'])}{v}", 255
    if form < 0.6:
        emit(f"{mn}{c}\t{rd}, [{b}, {off}]")
    elif form < 0.8:
        emit(f"{mn}{c}\t{rd}, [{b}, {off}]!")
        drift[b] += reach
    else:
        emit(f"{mn}{c}\t{rd}, [{b}], {off}")
        drift[b] += reach
    if load:
        wrote(rd)
        if rd == b:
            anchor(b)
    check_drift()


def op_rom():
    c = cond(0.15)
    mn = R.choice(["ldr", "ldrb", "ldrh", "ldrsh", "ldrsb", "ldr"])
    d = dst()
    if R.random() < 0.5:                           # a literal word, often used at once
        emit(f"ldr{c}\t{d}, ={R.getrandbits(32):#x}")
    else:                                          # code behind us, at any byte offset
        l = newlabel()
        out.append(f"{l}:")
        emit(f"adr\tr10, {l}")
        off = R.randrange(4, 200)
        if ISS:
            off &= ~3 if mn == "ldr" else ~1
        emit(f"{mn}{c}\t{d}, [r10, #-{off}]")
    wrote(d)


def op_asset():
    c = cond(0.15)
    mn = R.choice(["ldrsb", "ldrb", "ldrh", "ldrsh", "ldr"])
    emit(f"ldr\tr10, ={0x02000000 + R.randrange(ASSET_BYTES - 64):#x}")
    d = dst()
    if R.random() < 0.7:
        emit(f"{mn}{c}\t{d}, [r10, #{R.randrange(64)}]")
    else:                                          # post-indexed through the window
        emit(f"{mn}{c}\t{d}, [r10], #{R.randrange(32)}")
        d2 = dst()
        emit(f"{R.choice(['ldrsb', 'ldrb', 'ldrh'])}\t{d2}, [r10]")
        wrote(d2)
    wrote(d)


def op_mmio():
    c = cond(0.4)
    emit("ldr\tr10, =0xE0009000")
    if R.random() < 0.7:
        d = dst()
        emit(f"{R.choice(['ldr', 'ldr', 'ldrb', 'ldrh'])}{c}\t{d}, [r10, #{R.choice(MMIO_READ)}]")
        wrote(d)
    else:                                          # PCM push: the only write without side effects here
        emit(f"{R.choice(['str', 'str', 'strh', 'strb'])}{c}\t{src()}, [r10, #0x10]")


def op_blk():
    c = cond(0.2)
    b = R.choice(["r11", "r12"])
    mode = R.choice(["ia", "ib", "da", "db"])
    load = R.random() < 0.5
    names = [f"r{x}" for x in sorted(R.sample(range(10), R.randrange(1, 7)))]
    if R.random() < 0.2:
        names.append("lr")
    wb = "!" if R.random() < 0.5 else ""
    # the base in the list: an STM stores it (old or new, as the ARM7TDMI
    # does); an LDM without write-back loads it (with write-back ARMv4
    # leaves the base UNPREDICTABLE; v_blkx and blk15 have that)
    inlist = not ISS and R.random() < 0.15 and not (load and wb)
    if inlist:
        names.append(b)
    names.sort(key=lambda x: 14 if x == "lr" else int(x[1:]))
    emit(f"{'ldm' if load else 'stm'}{mode}{c}\t{b}{wb}, {{{', '.join(names)}}}")
    if wb:
        drift[b] += 4 * len(names) + 4
    if load:
        for x in names:
            wrote(x)
        if inlist:
            anchor(b)
    check_drift()


def op_stack():
    regs = sorted(R.sample(range(10), R.randrange(1, 5)))
    emit(f"push\t{{{', '.join('r%d' % x for x in regs)}}}")
    for _ in range(R.randrange(0, 3)):
        op_dp()
    regs2 = sorted(R.sample(range(10), len(regs)))
    c = cond(0.3)
    emit(f"pop{c}\t{{{', '.join('r%d' % x for x in regs2)}}}")
    if c:                       # the same flags: drop the words when the pop did not run
        emit(f"add{INVERSE[c]}\tsp, sp, #{4 * len(regs2)}")
    for x in regs2:
        wrote(f"r{x}")


def op_psr():
    k = R.random()
    c = cond(0.2)
    if k < 0.35:
        d = dst()
        emit(f"mrs{c}\t{d}, cpsr")
        wrote(d)
    elif k < 0.6:
        emit(f"msr{c}\tcpsr_f, #{R.randrange(16) << 28:#x}")
    elif k < 0.85:
        t = dst()
        emit(f"and\t{t}, {src()}, #0xf0000000")
        if R.random() < 0.5:
            emit(f"orr\t{t}, {t}, #0xd3")
            emit(f"msr{c}\tcpsr_fc, {t}")
        else:
            emit(f"msr{c}\tcpsr_f, {t}")
        wrote(t)
    else:
        emit(f"msr{c}\tcpsr_c, #0xd3")


def op_branch():
    k = R.random()
    if k < 0.45:                                   # forward conditional branch
        l = newlabel()
        emit(f"b{R.choice(CONDS)}\t{l}")
        for _ in range(R.randrange(1, 4)):
            op_dp()
        out.append(f"{l}:")
    elif k < 0.7 and not in_sub[0]:                # BL to a short subroutine, BX lr back
        l1, l2 = newlabel(), newlabel()
        emit(f"bl{cond(0.2)}\t{l1}")
        emit(f"b\t{l2}")
        out.append(f"{l1}:")
        in_sub[0] = True
        for _ in range(R.randrange(1, 4)):
            R.choice([op_dp, op_dp, op_mul, lambda: op_ram(False)])()
        if R.random() < 0.3:
            emit(f"bx{R.choice(CONDS)}\tlr")
            op_dp()
        emit("bx\tlr")
        in_sub[0] = False
        out.append(f"{l2}:")
        wrote("lr")
    elif k < 0.85:                                 # LDR pc from a literal
        l = newlabel()
        emit(f"ldr{cond(0.4)}\tpc, ={l}")
        for _ in range(R.randrange(1, 3)):
            op_dp()
        out.append(f"{l}:")
    else:                                          # an address pushed, then popped into pc
        l = newlabel()
        emit(f"adr\tr10, {l}")
        emit("str\tr10, [sp, #-4]!")
        op_dp()
        emit("ldr\tpc, [sp], #4")
        for _ in range(R.randrange(1, 3)):
            op_dp()
        out.append(f"{l}:")


KINDS = [(op_dp, 34), (op_mul, 9), (lambda: op_ram(False), 16), (lambda: op_ram(True), 11),
         (op_rom, 4), (op_blk, 8), (op_stack, 2), (op_psr, 4), (op_branch, 6)]
if not ISS:
    KINDS += [(op_asset, 4), (op_mmio, 2)]


def pick():
    t = R.randrange(sum(k for _, k in KINDS))
    for f, k in KINDS:
        if t < k:
            return f()
        t -= k


print(f"@ generated by vrand.py {seed} {nops}{' --iss' if ISS else ''}")
print('\t.syntax unified\n\t.arm\n\t.cpu arm7tdmi\n\t.section .vectors, "ax"\n\t.global _start')
print("_start:\tb\treset\n" + "\tb\t.\n" * 7 + "\t.text\nreset:")
for s in ["mrs\tr0, cpsr", "bic\tr0, r0, #31", "orr\tr0, r0, #0xd3", "msr\tcpsr_c, r0",
          "ldr\tsp, =__stack_top"]:
    emit(s)
# Random words in RAM from 0x40000a00 to 0x40002e00, everywhere the bases can
# reach (anchor +- 512 + 0x7fc), six words a beat; then random registers.
for r in range(4, 10):
    emit(f"ldr\tr{r}, ={R.getrandbits(32):#x}")
emit("ldr\tr2, =0x40000a00")
emit("ldr\tr3, =0x40002e00")
out.append("1:")
emit("stmia\tr2!, {r4-r9}")
emit("eor\tr4, r4, r9, ror #7")
emit("add\tr5, r5, r4, lsl #3")
emit("eor\tr6, r6, r5, ror #13")
emit("sub\tr7, r7, r6, lsr #1")
emit("eor\tr8, r8, r7, ror #19")
emit("add\tr9, r9, r8, asr #2")
emit("cmp\tr2, r3")
emit("bne\t1b")
for r in DATA:
    emit(f"ldr\t{r}, ={R.getrandbits(32):#x}")
anchor("r11")
anchor("r12")
emit(f"msr\tcpsr_f, #{R.randrange(16) << 28:#x}")
emit("b\t2f")
emit(".ltorg")
out.append("2:")
for i in range(nops):
    if i % 40 == 39:
        dump()
        l = newlabel()
        emit(f"b\t{l}")
        emit(".ltorg")
        out.append(f"{l}:")
    pick()
dump()
# The end marker: a FAULT write of 0xAA.
emit("ldr\tr1, =0xE0009000")
emit("mov\tr0, #0xaa")
emit("str\tr0, [r1, #0x1c]")
emit("b\t.")
emit(".ltorg")
print("\n".join(out))
