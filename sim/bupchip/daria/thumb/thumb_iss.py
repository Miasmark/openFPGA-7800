#!/usr/bin/env python3
"""Golden model for the Thumb random streams: run a test binary on Unicorn,
dump RAM, count instructions as the reference retires them, check that the
run stayed inside the subset where ARMv4T and ARMv5TE agree, and count the
formats it executed.

  thumb_iss.py TEST.bin SIG.out [--image IMG.a78] [--nsig N] [--trace F] [--cov F]
  thumb_iss.py --cover COV...       sum coverage files into a table

The machine is verif/isa/iss_run.py's: Unicorn (QEMU's ARM) as an ARM926
(ARMv5TE), ROM at 0, RAM at 0x40000000, the peripheral page with IDENT
(0x42555001), and the asset bytes of --image (after the A78 header and the
cartridge) at 0x02000000. The run starts in ARM state at 0 and stops at the
write to the FAULT register (0xE000901C); N words (default 4096: all RAM)
from 0x40000000 go to SIG.out in tb_ref_trace.sv's +sig format.

The last line is "ISS: <n> instructions, end code <cc>, <b> BL pairs,
<n + b> reference retires": Unicorn runs a Thumb BL pair as one 32-bit
instruction, the reference retires it as two, so the reference's count is
the instructions plus the BL pairs (exact for streams without lone halves,
which gen_thumb.py never makes). --trace writes "<n> <pc> <insn>" per
instruction (BL pairs as one line).

"LINT:" lines report what would make the comparison meaningless, or DARIA
halt, though Unicorn ran it:
  - a word access not word aligned, a halfword access at an odd address
    (ARMv4 rotates or aligns, ARMv5 differs), and any access outside ROM,
    RAM, the assets, IDENT and the PCM and FAULT registers;
  - a change of state other than by BX (POP {pc} or LDR pc to an even
    address switches to ARM only on ARMv5), a Thumb BX PC at an address
    2 mod 4, and the encodings DARIA halts on (SWI, undefined, the v5/v6
    spaces, BX with H1 or bits 2:0 set, H1 = H2 = 0 hi-register forms,
    empty lists, lone BL halves);
  - a read of C after a Thumb MUL before an instruction that surely writes
    it (DARIA halts with code 8; Unicorn keeps C, the reference computes it).
    Readers: Bcc CS/CC/HI/LS, ADC, SBC; in ARM state those conditions,
    ADC/SBC/RSC, RRX and MRS. Writers: F1 shifts by a nonzero amount, F2,
    F3 other than MOV, CMP/CMN/NEG, register shifts by a nonzero amount,
    F5 CMP; unconditional ARM arithmetic with S, CMP, CMN, MSR of the flags.
--cov writes "<bin> <count>" lines: one bin per format and operation (F4
ops, F5 operand kinds, conditions taken and not taken, load and store size
by region, and so on), for run_random.sh's coverage table.

SPDX-License-Identifier: MIT
"""
import collections
import struct
import sys

M = 0xFFFFFFFF
CN = ["EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC", "HI", "LS", "GE", "LT", "GT", "LE", "AL", "NV"]
F4N = ["AND", "EOR", "LSL", "LSR", "ASR", "ADC", "SBC", "ROR", "TST", "NEG", "CMP", "CMN", "ORR", "MUL", "BIC", "MVN"]
CREAD = {2, 3, 8, 9}


def cover_table(files):
    """Sum --cov files and print them by format."""
    tot = collections.Counter()
    for f in files:
        for line in open(f):
            k, _, v = line.rstrip("\n").rpartition(" ")
            if k:
                tot[k] += int(v)
    fmt = collections.Counter()
    for k, v in tot.items():
        if k.startswith(("F", "ARM")) and k != "ARM startup":
            fmt[k.split()[0]] += v
    n = sum(fmt.values())
    print(f"executed after the ARM start-up: {n} instructions (BL pairs once)")
    groups = [("data processing", ["F1", "F2", "F3", "F4", "F5", "F12", "F13"]),
              ("loads", ["F6", "F7L", "F8L", "F9L", "F10L", "F11L"]),
              ("stores", ["F7S", "F8S", "F9S", "F10S", "F11S"]),
              ("Bcc", ["F16"]), ("B", ["F18"]), ("BL", ["F19"]), ("BX", ["F5BX"]),
              ("PUSH/POP, LDM/STM", ["F14", "F15"]), ("ARM state", ["ARM"])]
    for g, fs in groups:
        c = sum(fmt[f] for f in fs)
        print(f"  {g:18s} {100.0 * c / max(n, 1):5.1f}%  " + "  ".join(f"{f} {fmt[f]}" for f in fs))
    print("bins:")
    for k in sorted(tot):
        print(f"  {tot[k]:8d}  {k}")
    return 0


if len(sys.argv) > 1 and sys.argv[1] == "--cover":
    sys.exit(cover_table(sys.argv[2:]))

from unicorn import Uc, UcError, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE, UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE  # noqa: E402
from unicorn import UC_MEM_WRITE, arm_const  # noqa: E402
from unicorn.arm_const import UC_CPU_ARM_926, UC_ARM_REG_CPSR  # noqa: E402


def opt(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


binf, sigf = sys.argv[1], sys.argv[2]
nsig = int(opt("--nsig", "4096"))
tracef, covf, image = opt("--trace"), opt("--cov"), opt("--image")

assets = b""
if image:
    img = open(image, "rb").read()
    assets = img[128 + int.from_bytes(img[49:53], "big"):]

uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
uc.ctl_set_cpu_model(UC_CPU_ARM_926)
uc.mem_map(0x00000000, 0x4000)
uc.mem_map(0x40000000, 0x4000)
uc.mem_map(0xE0009000, 0x1000)
uc.mem_write(0, open(binf, "rb").read())
uc.mem_write(0xE0009000, struct.pack("<I", 0x42555001))
if assets:
    uc.mem_map(0x02000000, (len(assets) + 0xFFF) & ~0xFFF)
    uc.mem_write(0x02000000, assets)
uc.reg_write(UC_ARM_REG_CPSR, 0xd3)

st = {"body": False, "blpre": None, "code": None, "n": 0, "bl": 0, "cunk": False, "prev": None, "lint": 0}
cov = collections.Counter()
tfd = open(tracef, "w") if tracef else None


def lint(msg):
    st["lint"] += 1
    if st["lint"] <= 20:
        print(f"LINT: {msg}")


REGS = [getattr(arm_const, f"UC_ARM_REG_R{i}") for i in range(8)]


def lo_reg(i):
    return uc.reg_read(REGS[i])


def region(addr):
    if addr < 0x4000:
        return "ROM"
    if 0x40000000 <= addr < 0x40004000:
        return "RAM"
    if 0x02000000 <= addr < 0x02000000 + len(assets):
        return "asset"
    return "MMIO"


def on_mem(uc_, access, addr, size, value, _):
    write = access == UC_MEM_WRITE
    if (size == 4 and addr & 3) or (size == 2 and addr & 1):
        lint(f"unaligned {'store' if write else 'load'} of {size} bytes at {addr:08x} (pc {st['pc']:08x})")
    r = region(addr)
    if r == "MMIO" and not ((not write and addr == 0xE0009000) or (write and addr in (0xE0009010, 0xE000901C))):
        lint(f"access to {addr:08x} (pc {st['pc']:08x})")
    if write and r in ("ROM", "asset"):
        lint(f"store to {r} at {addr:08x}")
    cov[f"mem {'store' if write else 'load'} {r} {size}{'' if addr % size == 0 and size > 1 else (' odd' if addr & 1 else '')}"] += 1
    if write and addr == 0xE000901C:
        st["code"] = value & 0xFF
        uc_.emu_stop()


def thumb(addr, hw):
    """Classify a Thumb halfword for coverage, and lint it. Returns the
    coverage bin, whether it reads C, writes C, or sets C unknown."""
    rd_c = wr_c = mul = False
    top = hw >> 11
    if hw >> 13 == 0 and top != 3:                     # F1
        op, n = top, (hw >> 6) & 31
        name = ["LSL", "LSR", "ASR"][op]
        b = f"F1 {name} #{'0' if n == 0 and op == 0 else ('32' if n == 0 else 'n')}"
        wr_c = op != 0 or n != 0
    elif top == 3:                                     # F2
        b = f"F2 {'SUB' if hw >> 9 & 1 else 'ADD'} {'#imm3' if hw >> 10 & 1 else 'reg'}"
        if hw >> 10 & 1 and (hw >> 6) & 7 == 0:
            b += " #0"
        wr_c = True
    elif hw >> 13 == 1:                                # F3
        b = f"F3 {['MOV', 'CMP', 'ADD', 'SUB'][top & 3]}"
        wr_c = top & 3 != 0
    elif hw >> 10 == 0x10:                             # F4
        op = (hw >> 6) & 15
        b = f"F4 {F4N[op]}"
        if op in (2, 3, 4, 7):
            amt = lo_reg((hw >> 3) & 7) & 0xFF
            wr_c = amt != 0
            b += " by 0" if amt == 0 else (" by 1-31" if amt < 32 else (" by 32" if amt == 32 else " by >32"))
        elif op in (5, 6):
            rd_c = wr_c = True
        elif op in (9, 10, 11):
            wr_c = True
        elif op == 13:
            mul = True
            if (hw >> 3) & 7 == hw & 7:
                b += " Rd=Rm"
    elif hw >> 10 == 0x11:                             # F5
        op, h1, h2 = (hw >> 8) & 3, hw >> 7 & 1, hw >> 6 & 1
        rm, rdn = (h2 << 3) | (hw >> 3 & 7), (h1 << 3) | (hw & 7)
        if op == 3:
            b = "F5BX " + ("PC" if rm == 15 else ("LR" if rm == 14 else ("hi" if h2 else "lo")))
            if h1 or hw & 7:
                lint(f"BX with H1 or SBZ bits at {addr:08x}")
            if rm == 15 and addr & 2:
                lint(f"BX PC at {addr:08x}, 2 mod 4")
        else:
            if not h1 and not h2:
                lint(f"hi-register op with H1 = H2 = 0 at {addr:08x}")
            kind = lambda r: "PC" if r == 15 else ("SP" if r == 13 else ("LR" if r == 14 else ("hi" if r > 7 else "lo")))
            b = f"F5 {['ADD', 'CMP', 'MOV'][op]} {kind(rdn)},{kind(rm)}"
            wr_c = op == 1
    elif top == 9:
        b = "F6 LDR PC" + (" @2mod4" if addr & 2 else "")
    elif hw >> 12 == 5:
        if hw >> 9 & 1 == 0:
            b = f"F7{'L' if hw >> 11 & 1 else 'S'} {['STR', 'STRB', 'LDR', 'LDRB'][hw >> 10 & 3]}"
        else:
            o = ["STRH", "LDRSB", "LDRH", "LDRSH"][((hw >> 11) & 1) << 1 | ((hw >> 10) & 1)]
            b = f"F8{'S' if o == 'STRH' else 'L'} {o}"
    elif hw >> 13 == 3:
        b = f"F9{'L' if hw >> 11 & 1 else 'S'} {'LDR' if hw >> 11 & 1 else 'STR'}{'B' if hw >> 12 & 1 else ''}"
    elif hw >> 12 == 8:
        b = f"F10{'L' if hw >> 11 & 1 else 'S'} {'LDRH' if hw >> 11 & 1 else 'STRH'}"
    elif hw >> 12 == 9:
        b = f"F11{'L' if hw >> 11 & 1 else 'S'} {'LDR' if hw >> 11 & 1 else 'STR'} SP"
    elif hw >> 12 == 0xA:
        b = f"F12 ADD {'SP' if hw >> 11 & 1 else 'PC'}"
    elif hw >> 8 == 0xB0:
        b = f"F13 {'SUB' if hw >> 7 & 1 else 'ADD'} SP"
    elif hw & 0xF600 == 0xB400:
        pop, r = hw >> 11 & 1, hw >> 8 & 1
        b = f"F14 {'POP' if pop else 'PUSH'}{(' +PC' if pop else ' +LR') if r else ''}"
        if hw & 0x1FF == 0:
            lint(f"empty PUSH/POP at {addr:08x}")
    elif hw >> 12 == 0xC:
        ld, rb = hw >> 11 & 1, hw >> 8 & 7
        b = f"F15 {'LDMIA' if ld else 'STMIA'}" + (" base in list" if hw >> rb & 1 else "")
        if hw & 0xFF == 0:
            lint(f"empty LDMIA/STMIA at {addr:08x}")
    elif hw >> 12 == 0xD:
        c = hw >> 8 & 15
        if c >= 14:
            lint(f"SWI or undefined Bcc at {addr:08x}")
        b = f"F16 B{CN[c]}"
        rd_c = c in CREAD
    elif top == 0x1C:
        b = "F18 B"
    elif top == 0x1E:
        b = "F19 BL prefix"
    elif top == 0x1F:
        b = "F19 BL suffix"
    else:
        b = "undefined"
        lint(f"undefined or v5 encoding {hw:04x} at {addr:08x}")
    if hw >> 8 in (0xB1, 0xB2, 0xB3, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBE, 0xBF) or top == 0x1D:
        lint(f"undefined or v5 encoding {hw:04x} at {addr:08x}")
    return b, rd_c, wr_c, mul


def arm(addr, w):
    cond = w >> 28
    rd_c = cond in CREAD
    wr_c = False
    b = "ARM"
    if cond == 15:
        lint(f"ARM NV space {w:08x} at {addr:08x}")
    if (w & 0x0FFFFFF0) == 0x012FFF10:
        b = "ARM BX"
    elif (w & 0x0FBF0FFF) == 0x010F0000:               # MRS
        rd_c = True
    elif (w & 0x0DB0F000) == 0x0120F000:               # MSR
        wr_c = cond == 14 and bool(w >> 19 & 1)
    elif (w >> 26) & 3 == 0 and not ((w >> 25) & 1 == 0 and (w >> 4) & 9 == 9):   # data processing
        op, s = (w >> 21) & 15, (w >> 20) & 1
        if op in (5, 6, 7):
            rd_c = True
        if not (w >> 25) & 1 and not (w >> 4) & 1 and (w >> 5) & 3 == 3 and (w >> 7) & 31 == 0:
            rd_c = True                                # RRX
        wr_c = cond == 14 and s == 1 and op in (2, 3, 4, 5, 6, 7, 10, 11)
    return b, rd_c, wr_c


def on_code(uc_, addr, size, _):
    st["pc"] = addr
    t = uc_.reg_read(UC_ARM_REG_CPSR) >> 5 & 1
    prev = st["prev"]
    if prev is not None:
        paddr, pt, pins, pbin = prev
        if t != pt:
            bx = (pins & 0xFF87) == 0x4700 if pt else (pins & 0x0FFFFFF0) == 0x012FFF10
            if not bx:
                lint(f"state change to {'Thumb' if t else 'ARM'} after {pins:0{4 if pt else 8}x} at {paddr:08x} (not BX)")
        if pbin.startswith("F16"):
            cov[pbin + (" taken" if addr != paddr + 2 else " not taken")] += 1
    if t:
        st["body"] = True
        hw = struct.unpack("<H", uc_.mem_read(addr, 2))[0]
        ins = hw
        if size == 4:
            st["bl"] += 1
            nxt = struct.unpack("<H", uc_.mem_read(addr + 2, 2))[0]
            b = "F19 BL " + ("back" if hw & 0x400 else "fwd")
            if hw >> 11 != 0x1E or nxt >> 11 != 0x1F:
                lint(f"32-bit Thumb instruction {hw:04x} {nxt:04x} at {addr:08x}")
            ins = hw << 16 | nxt
            rd_c = wr_c = mul = False
        else:
            # QEMU runs a BL pair that straddles its 1 KiB page as two
            # instructions, as the reference does: then no adjustment.
            b, rd_c, wr_c, mul = thumb(addr, hw)
            if b == "F19 BL suffix":
                if st["blpre"] != addr - 2:
                    lint(f"lone BL suffix {hw:04x} at {addr:08x}")
                b = "F19 BL split"
            elif st["blpre"] is not None:
                lint(f"lone BL prefix at {st['blpre']:08x}")
            st["blpre"] = addr if b == "F19 BL prefix" else None
    else:
        ins = struct.unpack("<I", uc_.mem_read(addr, 4))[0]
        b, rd_c, wr_c = arm(addr, ins)
        mul = False
        if not st["body"]:
            b = "ARM startup"
    if rd_c and st["cunk"]:
        lint(f"C read after a Thumb MUL at {addr:08x} ({b})")
    if wr_c:
        st["cunk"] = False
    if mul:
        st["cunk"] = True
    if not b.startswith(("F16", "F19 BL prefix")):
        cov[b] += 1
    st["prev"] = (addr, t, ins, b)
    st["n"] += 1
    if tfd:
        tfd.write(f"{st['n']} {addr:08x} {ins:08x}\n")
    if st["n"] > 2_000_000:
        lint("more than 2,000,000 instructions")
        uc_.emu_stop()


uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, on_mem)
uc.hook_add(UC_HOOK_CODE, on_code)
st["pc"] = 0
try:
    uc.emu_start(0, 0x4000)
except UcError as e:
    lint(f"Unicorn stopped: {e} at pc {st['pc']:08x}")
sig = uc.mem_read(0x40000000, 4 * nsig)
open(sigf, "w").write("".join(f"{struct.unpack_from('<I', sig, 4 * i)[0]:08x}\n" for i in range(nsig)))
if covf:
    open(covf, "w").write("".join(f"{k} {v}\n" for k, v in sorted(cov.items())))
end = "none" if st["code"] is None else f"{st['code']:02x}"
print(f"ISS: {st['n']} instructions, end code {end}, {st['bl']} BL pairs, {st['n'] + st['bl']} reference retires")
sys.exit(1 if st["lint"] else 0)
