#!/usr/bin/env python3
"""Reference model of a Thumb (ARMv4T) to ARM expander for DARIA, and a check
of it against an independent CPU model (Unicorn's ARM926) on every distinct
Thumb encoding the given cartridge images execute.

  thumb_expand.py ROM.bin [ROM.bin ...] [--trials N] [--table OUT.hex]

expand(hw, hw2) maps one Thumb halfword (and, for a BL pair, the next one)
onto one ARM encoding, written from the ARM Architecture Reference Manual's
Thumb chapter (each Thumb instruction's "ARM equivalent"). Branches keep an
ARM-like layout, cond:101:L:imm24, but imm24 counts halfwords, so the PC
adder shifts it by 1 in Thumb state and by 2 in ARM state. Two flags carry
the Thumb PC rules the ARM encoding cannot: pcrel (fmt 6 and ADD Rd,PC: the
base is (addr + 4) & ~3) and pc4 (r15 reads addr + 4 elsewhere). halt marks
encodings ARMv4T leaves undefined or UNPREDICTABLE, plus SWI, and a BL half
that is not part of a pair: DARIA would halt on them (exact-or-halt).

The check takes every Thumb halfword that daria_scan.py reaches in the
images, runs it in Thumb state and its expansion in ARM state on Unicorn
from the same random registers and memory, and compares r0-r14, NZCV and
memory. PC-relative forms are placed so that the ARM PC + 8 equals the
Thumb (PC + 4) & ~3. Control flow (B, Bcc, BL, BX, POP {pc}, MOV/ADD pc)
is checked against the scan's targets instead, since ARM926 (ARMv5)
interworks on POP {pc} where ARMv4T does not. Needs the unicorn module
(sim/work/bupchip/venv). --table writes the expansion of all 65,536
halfwords (with hw2 = a BL suffix) for an RTL equivalence check.

SPDX-License-Identifier: MIT
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import daria_scan  # noqa: E402

AL = 0xE << 28


def sx(v, bits):
    m = 1 << (bits - 1)
    return (v & (m - 1)) - (v & m)


def expand(hw, hw2=0):
    """Return dict(arm=int, pcrel=bool, pc4=bool, halt=bool, pair=bool,
    branch=bool)."""
    r = dict(arm=0, pcrel=False, pc4=False, halt=False, pair=False, branch=False)
    rd, rs, rn = hw & 7, (hw >> 3) & 7, (hw >> 6) & 7
    if hw >> 11 == 0b00011:                         # fmt 2
        i, sub = (hw >> 10) & 1, (hw >> 9) & 1
        opc = 0b0010 if sub else 0b0100
        r["arm"] = AL | (i << 25) | (opc << 21) | (1 << 20) | (rs << 16) | (rd << 12) | rn
    elif hw >> 13 == 0:                             # fmt 1: MOVS Rd, Rs, sh #n
        sh, n = (hw >> 11) & 3, (hw >> 6) & 31
        r["arm"] = AL | (0b1101 << 21) | (1 << 20) | (rd << 12) | (n << 7) | (sh << 5) | rs
    elif hw >> 13 == 1:                             # fmt 3
        op, d8, imm = (hw >> 11) & 3, (hw >> 8) & 7, hw & 0xFF
        opc = [0b1101, 0b1010, 0b0100, 0b0010][op]
        rnf = 0 if op == 0 else d8
        rdf = 0 if op == 1 else d8
        r["arm"] = AL | (1 << 25) | (opc << 21) | (1 << 20) | (rnf << 16) | (rdf << 12) | imm
    elif hw >> 10 == 0b010000:                      # fmt 4
        op = (hw >> 6) & 15
        dp = {0: 0b0000, 1: 0b0001, 5: 0b0101, 6: 0b0110, 8: 0b1000,
              10: 0b1010, 11: 0b1011, 12: 0b1100, 14: 0b1110, 15: 0b1111}
        if op in dp:                                # Rd = Rd op Rs
            opc = dp[op]
            rnf = 0 if opc == 0b1111 else rd
            rdf = 0 if opc in (0b1000, 0b1010, 0b1011) else rd
            r["arm"] = AL | (opc << 21) | (1 << 20) | (rnf << 16) | (rdf << 12) | rs
        elif op in (2, 3, 4, 7):                    # MOVS Rd, Rd, sh Rs
            sh = {2: 0, 3: 1, 4: 2, 7: 3}[op]
            r["arm"] = AL | (0b1101 << 21) | (1 << 20) | (rd << 12) | (rs << 8) | (sh << 5) | (1 << 4) | rd
        elif op == 9:                               # NEG: RSBS Rd, Rs, #0
            r["arm"] = AL | (1 << 25) | (0b0011 << 21) | (1 << 20) | (rs << 16) | (rd << 12)
        else:                                       # MUL: MULS Rd, Rs, Rd
            r["arm"] = AL | (1 << 20) | (rd << 16) | (rd << 8) | (9 << 4) | rs
            r["halt"] = rd == rs                    # UNPREDICTABLE on v4T
    elif hw >> 10 == 0b010001:                      # fmt 5
        op, h1, h2 = (hw >> 8) & 3, (hw >> 7) & 1, (hw >> 6) & 1
        hd, hs = (h1 << 3) | rd, (h2 << 3) | rs
        r["pc4"] = hs == 15 or (hd == 15 and op == 1)
        if op == 3:                                 # BX
            r["arm"] = AL | 0x012FFF10 | hs
            r["branch"] = True
            r["halt"] = bool(h1) or rd != 0
        else:
            opc = [0b0100, 0b1010, 0b1101][op]
            s = 1 if op == 1 else 0
            rnf = 0 if op == 2 else hd
            rdf = 0 if op == 1 else hd
            r["arm"] = AL | (opc << 21) | (s << 20) | (rnf << 16) | (rdf << 12) | hs
            r["halt"] = not h1 and not h2
            r["branch"] = hd == 15 and op != 1
            if op == 0 and hd == 15:
                r["pc4"] = True
    elif hw >> 11 == 0b01001:                       # fmt 6
        d8 = (hw >> 8) & 7
        r["arm"] = AL | 0x059F0000 | (d8 << 12) | ((hw & 0xFF) << 2)
        r["pcrel"] = True
    elif hw >> 12 == 0b0101:
        ro = rn
        if not (hw >> 9) & 1:                       # fmt 7
            l, b = (hw >> 11) & 1, (hw >> 10) & 1
            r["arm"] = AL | 0x07800000 | (b << 22) | (l << 20) | (rs << 16) | (rd << 12) | ro
        else:                                       # fmt 8
            h, sgn = (hw >> 11) & 1, (hw >> 10) & 1
            l = 1 if (h or sgn) else 0
            shf = [[0b01, 0b01], [0b10, 0b11]][sgn][h]
            r["arm"] = AL | 0x01800090 | (l << 20) | (rs << 16) | (rd << 12) | (shf << 5) | ro
    elif hw >> 13 == 0b011:                         # fmt 9
        b, l, n = (hw >> 12) & 1, (hw >> 11) & 1, (hw >> 6) & 31
        off = n if b else n << 2
        r["arm"] = AL | 0x05800000 | (b << 22) | (l << 20) | (rs << 16) | (rd << 12) | off
    elif hw >> 12 == 0b1000:                        # fmt 10
        l, off = (hw >> 11) & 1, ((hw >> 6) & 31) << 1
        r["arm"] = AL | 0x01C000B0 | (l << 20) | (rs << 16) | (rd << 12) | ((off >> 4) << 8) | (off & 15)
    elif hw >> 12 == 0b1001:                        # fmt 11
        l, d8 = (hw >> 11) & 1, (hw >> 8) & 7
        r["arm"] = AL | 0x058D0000 | (l << 20) | (d8 << 12) | ((hw & 0xFF) << 2)
    elif hw >> 12 == 0b1010:                        # fmt 12: ADD Rd, PC|SP, #imm8<<2
        sp, d8 = (hw >> 11) & 1, (hw >> 8) & 7
        r["arm"] = AL | 0x02800F00 | ((13 if sp else 15) << 16) | (d8 << 12) | (hw & 0xFF)
        r["pcrel"] = not sp
    elif hw >> 8 == 0b10110000:                     # fmt 13
        opc = 0b0010 if (hw >> 7) & 1 else 0b0100
        r["arm"] = AL | (1 << 25) | (opc << 21) | (13 << 16) | (13 << 12) | (0xF << 8) | (hw & 0x7F)
    elif hw >> 12 == 0b1011 and ((hw >> 9) & 3) == 0b10:   # fmt 14
        l, rr, rl = (hw >> 11) & 1, (hw >> 8) & 1, hw & 0xFF
        if l:   # LDMIA sp!, {rl, pc}
            r["arm"] = AL | 0x08BD0000 | (rr << 15) | rl
            r["branch"] = bool(rr)
        else:   # STMDB sp!, {rl, lr}
            r["arm"] = AL | 0x092D0000 | (rr << 14) | rl
        r["halt"] = rl == 0 and not rr
    elif hw >> 12 == 0b1011:
        r["halt"] = True                            # BKPT, CBZ, ... (v5+)
    elif hw >> 12 == 0b1100:                        # fmt 15
        l, rb, rl = (hw >> 11) & 1, (hw >> 8) & 7, hw & 0xFF
        r["arm"] = AL | 0x08A00000 | (l << 20) | (rb << 16) | rl
        r["halt"] = rl == 0
    elif hw >> 12 == 0b1101:
        cond = (hw >> 8) & 15
        if cond >= 14:                              # undefined / SWI
            r["halt"] = True
        else:                                       # fmt 16
            r["arm"] = (cond << 28) | (0b101 << 25) | (sx(hw & 0xFF, 8) & 0xFFFFFF)
            r["branch"] = True
    elif hw >> 11 == 0b11100:                       # fmt 18
        r["arm"] = AL | (0b101 << 25) | (sx(hw & 0x7FF, 11) & 0xFFFFFF)
        r["branch"] = True
    elif hw >> 11 == 0b11110 and hw2 >> 11 == 0b11111:   # fmt 19 pair
        off = (sx(hw & 0x7FF, 11) << 11) | (hw2 & 0x7FF)
        r["arm"] = AL | (0b1011 << 24) | (off & 0xFFFFFF)
        r["pair"] = r["branch"] = True
    else:                                           # lone BL half, BLX suffix
        r["halt"] = True
    return r


# ---------------------------------------------------------------------------
# Unicorn check
# ---------------------------------------------------------------------------

def collect(paths):
    seen = {}
    for p in paths:
        rom = open(p, "rb").read()
        info = daria_scan.detect(rom)
        if info["scheme"] == "unknown":
            continue
        s = daria_scan.Scan(rom, info)
        s.run()
        for a, d in s.t.items():
            hw = daria_scan.u16(rom, a)
            hw2 = daria_scan.u16(rom, a + 2) or 0
            key = (hw, hw2 if d["fmt"] == 19 else 0)
            seen.setdefault(key, (os.path.basename(p), a, d))
    return seen


def run_check(seen, trials, seed=1):
    from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_MEM_WRITE
    from unicorn import arm_const as A
    rnd = random.Random(seed)
    REGS = [getattr(A, "UC_ARM_REG_R%d" % i) for i in range(13)] + \
        [A.UC_ARM_REG_SP, A.UC_ARM_REG_LR]
    RAM, RAMSZ = 0x40000000, 0x10000
    CODE = 0x10000
    base_ram = bytes(rnd.getrandbits(8) for _ in range(RAMSZ))

    def mk():
        uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
        try:
            uc.ctl_set_cpu_model(A.UC_CPU_ARM_926)
        except Exception:
            pass
        uc.mem_map(CODE, 0x10000)
        uc.mem_map(RAM, RAMSZ)
        uc.mem_write(RAM, base_ram)
        uc.writes = []
        uc.hook_add(UC_HOOK_MEM_WRITE,
                    lambda u, acc, addr, size, val, ud:
                    u.writes.append((addr, size, val & ((1 << (8 * size)) - 1))))
        return uc

    uc_t, uc_a = mk(), mk()
    stats = {"checked": 0, "skipped": 0, "fail": []}
    for (hw, hw2), (src, addr, d) in sorted(seen.items()):
        e = expand(hw, hw2)
        if e["halt"]:
            stats["fail"].append((hex(hw), "expander halts on a reached encoding"))
            continue
        if e["branch"] or e["pc4"]:
            stats["skipped"] += 1
            continue
        mem = d["fmt"] in (7, 8, 9, 10, 11, 14, 15)
        for t in range(trials):
            regs = []
            for i in range(15):
                if mem:
                    v = RAM + 0x4000 + rnd.randrange(0, 0x4000)
                    if d["fmt"] in (7, 8) and i == (hw >> 6) & 7:
                        v = rnd.randrange(0, 0x100)          # Ro: a small offset
                    regs.append(v)
                else:
                    regs.append(rnd.choice([rnd.getrandbits(32), rnd.randrange(0, 64),
                                            0, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF]))
            if mem and d["fmt"] in (7, 8) and (hw >> 6) & 7 == (hw >> 3) & 7:
                regs[(hw >> 6) & 7] = RAM + 0x4000        # Ro == Rb
            nzcv = rnd.getrandbits(4) << 28
            tpc = CODE + 0x1000 + rnd.choice([0, 2])
            apc = ((tpc + 4) & ~3) - 8 if e["pcrel"] else CODE + 0x4000
            lit = rnd.getrandbits(32)
            out = []
            for uc, thumb in ((uc_t, True), (uc_a, False)):
                for i, v in enumerate(regs):
                    uc.reg_write(REGS[i], v)
                uc.reg_write(A.UC_ARM_REG_CPSR, nzcv | 0x13 | (0x20 if thumb else 0))
                if e["pcrel"]:
                    b0 = (tpc + 4) & ~3
                    uc.mem_write(b0, b"".join(((lit + k) & 0xFFFFFFFF).to_bytes(4, "little")
                                              for k in range(0, 1024, 4)))
                uc.writes = []
                if thumb:
                    uc.mem_write(tpc, hw.to_bytes(2, "little"))
                    uc.emu_start(tpc | 1, tpc + 2, count=1)
                else:
                    uc.mem_write(apc, e["arm"].to_bytes(4, "little"))
                    uc.emu_start(apc, apc + 4, count=1)
                rs = [uc.reg_read(r) for r in REGS]
                fl = uc.reg_read(A.UC_ARM_REG_CPSR) >> 28
                w = list(uc.writes)
                for wa, ws, _ in w:                       # restore memory
                    if RAM <= wa < RAM + RAMSZ:
                        uc.mem_write(wa, base_ram[wa - RAM:wa - RAM + ws])
                out.append((rs, fl, w))
            (rt, ft, wt), (ra, fa, wa_) = out
            if rt != ra or ft != fa or wt != wa_:
                diff = [i for i in range(15) if rt[i] != ra[i]]
                stats["fail"].append((hex(hw), d["op"], "regs %s flags %x/%x writes %s/%s" % (
                    diff, ft, fa, wt[:2], wa_[:2]), "%s 0x%x" % (src, addr)))
                break
        stats["checked"] += 1
    return stats


def write_table(path):
    with open(path, "w") as f:
        for hw in range(65536):
            e = expand(hw, 0xF800)
            flags = (e["pcrel"] << 4) | (e["pc4"] << 3) | (e["halt"] << 2) | \
                (e["pair"] << 1) | e["branch"]
            f.write("%04x %08x %02x\n" % (hw, e["arm"], flags))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("roms", nargs="*")
    ap.add_argument("--trials", type=int, default=24)
    ap.add_argument("--table")
    a = ap.parse_args()
    if a.table:
        write_table(a.table)
    if a.roms:
        seen = collect(a.roms)
        st = run_check(seen, a.trials)
        print("distinct Thumb encodings reached: %d" % len(seen))
        print("checked against Unicorn (ARM926), %d random states each: %d" % (
            a.trials, st["checked"]))
        print("control flow / PC-reading, checked by the scan instead: %d" % st["skipped"])
        print("mismatches: %d" % len(st["fail"]))
        for f in st["fail"][:30]:
            print("  ", f)
        return 1 if st["fail"] else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
