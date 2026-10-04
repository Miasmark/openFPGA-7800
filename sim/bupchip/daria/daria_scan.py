#!/usr/bin/env python3
"""Static scan of a 2600 Harmony/Melody ARM cartridge image (DPC+, CDF, CDFJ,
CDFJ+) for the DARIA feasibility study (docs/BUPCHIP_CORE.md, "Later: 2600
ARM cartridges").

  daria_scan.py ROM.bin [ROM.bin ...] [--json OUT.json] [--listdir DIR]
                [--check]

For each image it:
  - detects the scheme the way upstream's detect2600.sv does (DPC+ marker,
    "CDF" words, the PLUSCDFJ header) and takes the ARM entry and stack the
    way upstream's mappers do (mapper_dpcplus.sv, mapper_cdf.sv): DPC+
    0x0C08, CDF/CDFJ 0x0808, CDFJ+ the words at 0x17F8/0x17F4;
  - follows the code the ARM can run from those entries by recursive
    descent: B, Bcc, BL pairs, BX/MOV pc through registers whose value is a
    literal-pool constant, GCC's __gnu_thumb1_case_* switch tables, the
    CDF-family driver helpers at 0x750 (Thumb stubs that BX into ARM state),
    and, in a second pass, odd literal or table words that point at code.
    The walk repeats until it is stable: bytes found to be literal pools or
    switch tables stop the fall-through after a BL that GCC used as a far
    jump (or a call that does not return);
  - classifies every reached Thumb halfword into the 19 ARM7TDMI Thumb
    formats (plus the encodings ARMv4T leaves undefined), and every reached
    ARM word into its ARMv4 class; reports the bytes of the code span that
    are neither reached code nor known data (gaps), the return idioms, and
    MULs whose (UNPREDICTABLE on ARMv4) C flag is read afterwards;
  - records the literal constants the code loads (ROM data, RAM, MMIO), the
    crt0 stub's .data/.bss ranges, the driver's peripheral set-up (PLL, MAM,
    VPB), the 6507's CALLFN sites and its RIOT timer loads (the VBLANK and
    overscan windows an ARM call has to fit in).

--check compares every reached Thumb instruction's class with objdump's
mnemonic. --listdir writes one objdump listing per image of just the
reached ranges (objdump -b binary -marmv4t, -Mforce-thumb for Thumb
ranges). Listings and JSON hold game code: write them under sim/work/ only,
never commit them. The script itself contains no game data.

SPDX-License-Identifier: MIT
"""
import argparse
import json
import os
import struct
import subprocess
import sys
from collections import Counter, defaultdict

# ---------------------------------------------------------------------------
# Scheme detection (src/fpga/mister/rtl/detect2600.sv, top.sv, mapper_*.sv)
# ---------------------------------------------------------------------------


def u32(rom, a):
    return struct.unpack_from("<I", rom, a)[0] if 0 <= a <= len(rom) - 4 else None


def u16(rom, a):
    return struct.unpack_from("<H", rom, a)[0] if 0 <= a <= len(rom) - 2 else None


def detect(rom):
    size = len(rom)
    words = [u32(rom, a) for a in range(0, min(size, 2048), 4)]
    cdf0 = sum(1 for w in words if w == 0x00464443)
    cdfj = sum(1 for w in words if w == 0x4A464443)
    plus = any(words[i] == 0x53554C50 and words[i + 1] == 0x4A464443 and
               words[i + 2] == 0x00000001 for i in range(len(words) - 2))
    has_cdf = rom.count(b"CDF") >= 3 or b"PLUSCDFJ" in rom
    dpcp = rom.count(b"DPC+") >= 2
    info = {"size": size}
    if has_cdf and size in (32768, 65536, 131072, 262144, 524288):
        if plus:
            rev, name = 3, "CDFJ+"
        elif cdfj >= 3:
            rev, name = 2, "CDFJ"
        elif cdf0 >= 3:
            rev, name = 0, "CDF0"
        else:                       # "CDF" + a version byte
            rev, name = 1, "CDF1"
        info.update(scheme=name, revision=rev, family="CDF")
        if rev == 3:
            info["stack"] = u32(rom, 0x17F4)
            info["entry"] = u32(rom, 0x17F8) & ~1
            info["bank0"] = 0x0800          # rom_a = 2048 + bank*4K, start bank 0
            info["start_bank"] = 0
            info["ram_size"] = 32768        # top.sv: CDFJ+ 32K, others 8K
        else:
            info["stack"] = 0x40001FFC
            info["entry"] = 0x0808
            info["bank0"] = 0x1000          # rom_a = 4096 + bank*4K, start bank 6
            info["start_bank"] = 6
            info["ram_size"] = 8192
        info["driver_size"] = 0x800
        info["display_ram"] = 0x40000800    # 15'd2048 + pointer
        # Thumb stubs into the driver's ARM-state audio helpers
        # (Stella Thumbulator: CDF 0x6E0, CDF1/CDFJ/CDFJ+ 0x750).
        info["helpers"] = 0x06E0 if rev == 0 else 0x0750
    elif dpcp and size == 32768:
        info.update(scheme="DPC+", revision=0, family="DPC+",
                    stack=0x40001FFC, entry=0x0C08, bank0=0x0C00,
                    start_bank=5, ram_size=8192, driver_size=0x0C00,
                    display_ram=0x40000C00, helpers=None)
    else:
        info.update(scheme="unknown")
    return info


# ---------------------------------------------------------------------------
# Thumb (ARMv4T) decoder: ARM7TDMI data sheet formats 1-19
# ---------------------------------------------------------------------------

FMT_NAMES = {
    1: "move shifted register", 2: "add/subtract", 3: "mov/cmp/add/sub imm",
    4: "ALU operations", 5: "hi-reg ops / BX", 6: "PC-relative load",
    7: "load/store reg offset", 8: "load/store sign-ext byte/halfword",
    9: "load/store imm offset", 10: "load/store halfword",
    11: "SP-relative load/store", 12: "load address", 13: "add offset to SP",
    14: "push/pop", 15: "LDMIA/STMIA", 16: "conditional branch", 17: "SWI",
    18: "unconditional branch", 19: "BL pair",
    0: "undefined on ARMv4T",
}
ALU = ["AND", "EOR", "LSL", "LSR", "ASR", "ADC", "SBC", "ROR",
       "TST", "NEG", "CMP", "CMN", "ORR", "MUL", "BIC", "MVN"]
COND = ["EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC",
        "HI", "LS", "GE", "LT", "GT", "LE", "AL", "NV"]


def sext(v, bits):
    m = 1 << (bits - 1)
    return (v & (m - 1)) - (v & m)


def tdecode(hw, a, nxt):
    """Return dict: fmt, op (detail key), and control/data info."""
    d = {"fmt": 0, "op": "UNDEF", "len": 2}
    if hw >> 11 == 0b00011:
        i, sub = (hw >> 10) & 1, (hw >> 9) & 1
        d.update(fmt=2, op=("SUB" if sub else "ADD") + (" imm3" if i else " reg"),
                 rd=hw & 7, rs=(hw >> 3) & 7, imm=(hw >> 6) & 7 if i else None,
                 rn=None if i else (hw >> 6) & 7)
    elif hw >> 13 == 0:
        op = (hw >> 11) & 3
        off = (hw >> 6) & 31
        name = ["LSL", "LSR", "ASR"][op]
        d.update(fmt=1, op=name + (" #0" if off == 0 else ""), rd=hw & 7,
                 rs=(hw >> 3) & 7, imm=off)
    elif hw >> 13 == 1:
        op = (hw >> 11) & 3
        d.update(fmt=3, op=["MOV", "CMP", "ADD", "SUB"][op] + " imm8",
                 rd=(hw >> 8) & 7, imm=hw & 0xFF)
    elif hw >> 10 == 0b010000:
        op = (hw >> 6) & 15
        d.update(fmt=4, op=ALU[op], rd=hw & 7, rs=(hw >> 3) & 7)
        if op == 13 and d["rd"] == d["rs"]:
            d["op"] = "MUL Rd==Rm (UNPRED v4T)"
    elif hw >> 10 == 0b010001:
        op = (hw >> 8) & 3
        h1, h2 = (hw >> 7) & 1, (hw >> 6) & 1
        rs = (h2 << 3) | ((hw >> 3) & 7)
        rd = (h1 << 3) | (hw & 7)
        d.update(fmt=5, rd=rd, rs=rs)
        if op == 3:
            if h1:
                d.update(fmt=0, op="BLX reg (ARMv5)")
            elif hw & 7:
                d.update(fmt=0, op="BX SBZ!=0")
            else:
                d.update(op="BX " + ("lr" if rs == 14 else "pc" if rs == 15 else "rN"))
        else:
            name = ["ADD", "CMP", "MOV"][op]
            if not h1 and not h2:
                d.update(op=name + " lo,lo (UNPRED v4T)")
            else:
                tag = ""
                if rd == 15 and op != 1:
                    tag = " ->pc"
                elif rs == 15:
                    tag = " pc-src"
                d.update(op=name + " hi" + tag)
    elif hw >> 11 == 0b01001:
        imm = (hw & 0xFF) * 4
        d.update(fmt=6, op="LDR [pc]", rd=(hw >> 8) & 7,
                 lit=((a + 4) & ~3) + imm)
    elif hw >> 12 == 0b0101:
        ro, rb, rd = (hw >> 6) & 7, (hw >> 3) & 7, hw & 7
        if not (hw >> 9) & 1:
            l, b = (hw >> 11) & 1, (hw >> 10) & 1
            d.update(fmt=7, op=("LDR" if l else "STR") + ("B" if b else ""),
                     rd=rd, rb=rb, ro=ro)
        else:
            h, s = (hw >> 11) & 1, (hw >> 10) & 1
            d.update(fmt=8, op=[["STRH", "LDRH"], ["LDSB", "LDSH"]][s][h],
                     rd=rd, rb=rb, ro=ro)
    elif hw >> 13 == 0b011:
        b, l = (hw >> 12) & 1, (hw >> 11) & 1
        d.update(fmt=9, op=("LDR" if l else "STR") + ("B" if b else ""),
                 rd=hw & 7, rb=(hw >> 3) & 7,
                 imm=((hw >> 6) & 31) * (1 if b else 4))
    elif hw >> 12 == 0b1000:
        l = (hw >> 11) & 1
        d.update(fmt=10, op="LDRH imm" if l else "STRH imm", rd=hw & 7,
                 rb=(hw >> 3) & 7, imm=((hw >> 6) & 31) * 2)
    elif hw >> 12 == 0b1001:
        l = (hw >> 11) & 1
        d.update(fmt=11, op="LDR [sp]" if l else "STR [sp]",
                 rd=(hw >> 8) & 7, imm=(hw & 0xFF) * 4)
    elif hw >> 12 == 0b1010:
        sp = (hw >> 11) & 1
        d.update(fmt=12, op="ADD rd,sp,#" if sp else "ADD rd,pc,# (ADR)",
                 rd=(hw >> 8) & 7, imm=(hw & 0xFF) * 4)
        if not sp:
            d["adr"] = ((a + 4) & ~3) + (hw & 0xFF) * 4
    elif hw >> 8 == 0b10110000:
        d.update(fmt=13, op="SUB sp" if (hw >> 7) & 1 else "ADD sp",
                 imm=(hw & 0x7F) * 4)
    elif hw >> 12 == 0b1011 and ((hw >> 9) & 3) == 0b10:
        l, r = (hw >> 11) & 1, (hw >> 8) & 1
        rl = hw & 0xFF
        if rl == 0 and not r:
            d.update(fmt=0, op="PUSH/POP empty list")
        else:
            d.update(fmt=14, op=("POP" if l else "PUSH") +
                     ((" pc" if l else " lr") if r else ""),
                     rlist=rl, r=r, nregs=bin(rl).count("1") + r)
    elif hw >> 12 == 0b1011:
        d.update(fmt=0, op="1011 misc (ARMv5+: BKPT/CBZ/SXT...)")
    elif hw >> 12 == 0b1100:
        l = (hw >> 11) & 1
        rl = hw & 0xFF
        d.update(fmt=15, op=("LDMIA" if l else "STMIA") + (" empty" if rl == 0 else ""),
                 rb=(hw >> 8) & 7, rlist=rl, nregs=bin(rl).count("1"))
        if rl == 0:
            d["fmt"] = 0
        elif (hw >> 8) & 7 and (rl >> ((hw >> 8) & 7)) & 1:
            d["op"] += " (Rb in list)"
    elif hw >> 12 == 0b1101:
        cond = (hw >> 8) & 15
        if cond == 15:
            d.update(fmt=17, op="SWI", imm=hw & 0xFF)
        elif cond == 14:
            d.update(fmt=0, op="B<AL> cond=1110 (undef)")
        else:
            d.update(fmt=16, op="B" + COND[cond],
                     target=a + 4 + sext(hw & 0xFF, 8) * 2)
    elif hw >> 11 == 0b11100:
        d.update(fmt=18, op="B", target=a + 4 + sext(hw & 0x7FF, 11) * 2)
    elif hw >> 11 == 0b11101:
        d.update(fmt=0, op="BLX suffix (ARMv5)")
    elif hw >> 11 == 0b11110:
        if nxt is not None and nxt >> 11 == 0b11111:
            off = (sext(hw & 0x7FF, 11) << 12) + ((nxt & 0x7FF) << 1)
            d.update(fmt=19, op="BL", len=4, target=a + 4 + off)
        else:
            d.update(fmt=19, op="BL prefix alone", len=2)
    elif hw >> 11 == 0b11111:
        d.update(fmt=19, op="BL suffix alone", len=2)
    return d


# ---------------------------------------------------------------------------
# ARM (ARMv4) classifier, for the few ARM-state words the ARM can reach
# ---------------------------------------------------------------------------
DP = ["AND", "EOR", "SUB", "RSB", "ADD", "ADC", "SBC", "RSC",
      "TST", "TEQ", "CMP", "CMN", "ORR", "MOV", "BIC", "MVN"]


def adecode(w, a):
    cond = w >> 28
    d = {"cond": COND[cond], "len": 4, "op": "UNDEF"}
    if cond == 15:
        d["op"] = "cond=1111 (undef v4)"
        return d
    if (w & 0x0FFFFFF0) == 0x012FFF10:
        d.update(op="BX", rm=w & 15)
    elif (w & 0x0FBF0FFF) == 0x010F0000:
        d.update(op="MRS " + ("SPSR" if w & (1 << 22) else "CPSR"), rd=(w >> 12) & 15)
    elif (w & 0x0DB0F000) == 0x0120F000:
        fields = "".join(c for c, b in zip("cxsf", range(16, 20)) if w >> b & 1)
        src = "imm" if w & (1 << 25) else "reg"
        imm = None
        if w & (1 << 25):
            rot = ((w >> 8) & 15) * 2
            v = w & 0xFF
            imm = ((v >> rot) | (v << (32 - rot))) & 0xFFFFFFFF if rot else v
        d.update(op="MSR %s_%s %s" % ("SPSR" if w & (1 << 22) else "CPSR",
                                       fields, src), imm=imm, rm=w & 15)
    elif (w & 0x0FC000F0) == 0x00000090:
        d.update(op="MLA" if w & (1 << 21) else "MUL", s=bool(w & (1 << 20)))
    elif (w & 0x0F8000F0) == 0x00800090:
        d.update(op=["UMULL", "UMLAL", "SMULL", "SMLAL"][(w >> 21) & 3])
    elif (w & 0x0FB00FF0) == 0x01000090:
        d.update(op="SWP" + ("B" if w & (1 << 22) else ""))
    elif (w & 0x0E000090) == 0x00000090 and (w & 0x60):
        sh = (w >> 5) & 3
        l = (w >> 20) & 1
        d.update(op=("LDR" if l else "STR") + ["", "H", "SB", "SH"][sh] +
                 (" imm" if w & (1 << 22) else " reg"))
    elif (w >> 26) & 3 == 0:
        opc = (w >> 21) & 15
        i = (w >> 25) & 1
        rd = (w >> 12) & 15
        rn = (w >> 16) & 15
        kind = "imm" if i else ("regshift" if w & 0x10 else "reg")
        d.update(op="%s %s" % (DP[opc], kind) + ("S" if (w >> 20) & 1 else ""),
                 rd=rd, rn=rn, i=i, opc=opc)
        if i:
            rot = ((w >> 8) & 15) * 2
            v = w & 0xFF
            d["imm"] = ((v >> rot) | (v << (32 - rot))) & 0xFFFFFFFF if rot else v
        else:
            d["rm"] = w & 15
        if rd == 15 and opc not in (8, 9, 10, 11):
            d["op"] += " ->pc"
    elif (w >> 26) & 3 == 1:
        if (w >> 25) & 1 and (w >> 4) & 1:
            d["op"] = "UNDEF (media)"
            return d
        l, b = (w >> 20) & 1, (w >> 22) & 1
        d.update(op=("LDR" if l else "STR") + ("B" if b else "") +
                 (" reg" if (w >> 25) & 1 else " imm"),
                 rd=(w >> 12) & 15, rn=(w >> 16) & 15,
                 u=(w >> 23) & 1, imm=w & 0xFFF, p=(w >> 24) & 1)
        if d["rd"] == 15 and l:
            d["op"] += " ->pc"
    elif (w >> 25) & 7 == 0b100:
        d.update(op=("LDM" if (w >> 20) & 1 else "STM"),
                 pc_in=bool(w & 0x8000))
    elif (w >> 25) & 7 == 0b101:
        d.update(op="BL" if (w >> 24) & 1 else "B",
                 target=a + 8 + (sext(w & 0xFFFFFF, 24) << 2))
    elif (w >> 24) & 15 == 0xF:
        d.update(op="SWI")
    elif (w >> 26) & 3 == 0b11:
        d.update(op="coprocessor")
    return d


# ---------------------------------------------------------------------------
# Recursive descent
# ---------------------------------------------------------------------------

CASE_HELPERS = {  # libgcc lib1funcs.S __gnu_thumb1_case_*: load used
    "LDSB": ("sqi", 1), "LDRB": ("uqi", 1), "LDSH": ("shi", 2),
    "LDRH": ("uhi", 2), "LDR": ("si", 4)}


class Scan:
    def __init__(self, rom, info):
        self.rom = rom
        self.info = info
        self.size = len(rom)
        self.t = {}                 # Thumb insn addr -> decode
        self.a = {}                 # ARM insn addr -> decode
        self.lits = {}              # literal addr -> (value, size)
        self.funcs = set()          # Thumb function entries (BL targets etc.)
        self.entries = {}           # addr -> how found
        self.arm_targets = Counter()
        self.unresolved = Counter()
        self.case_tables = []       # (bl addr, kind, n, table bytes)
        self.notes = []
        self.case_helper = {}       # helper addr -> kind
        self.cover = {}             # byte addr -> 'T','A','L','J' (jump table)
        self.adr_refs = set()
        self.forbid = set()
        self.fell_into_data = set()
        self.data_bytes = set()

    # -- helpers ----------------------------------------------------------
    def in_rom(self, x):
        return 0 <= x < self.size

    def mark(self, a, n, kind):
        for i in range(n):
            self.cover.setdefault(a + i, kind)
            if kind in ("L", "J"):
                self.data_bytes.add(a + i)

    def classify_case_helper(self, a):
        """Recognise libgcc's __gnu_thumb1_case_* at Thumb address a."""
        if a in self.case_helper:
            return self.case_helper[a]
        ops = []
        p = a
        for _ in range(12):
            hw = u16(self.rom, p)
            if hw is None:
                break
            d = tdecode(hw, p, u16(self.rom, p + 2))
            ops.append(d)
            p += d["len"]
            if d["op"].startswith("BX") or d["op"].startswith("MOV hi ->pc"):
                break
        kind = None
        if len(ops) >= 8 and ops[0]["fmt"] == 14 and ops[0]["op"] == "PUSH" and \
                ops[1]["op"] == "MOV hi" and ops[1].get("rs") == 14:
            loads = [o["op"] for o in ops if o["fmt"] in (7, 8)]
            if loads and loads[0] in CASE_HELPERS and \
                    any(o["op"].startswith("ADD hi") or o["op"] == "MOV hi" for o in ops[2:]):
                kind = CASE_HELPERS[loads[0]]
        self.case_helper[a] = kind
        return kind

    def case_count(self, bl_addr):
        """Entries of a switch table: the nearest CMP rX,#imm before the BL,
        or, failing that, an AND with a MOV #imm mask (index = x & mask)."""
        p = bl_addr - 2
        window = []
        for _ in range(12):
            d = self.t.get(p) or tdecode(u16(self.rom, p) or 0, p, None)
            window.append(d)
            if d["fmt"] == 3 and d["op"].startswith("CMP"):
                return d["imm"] + 1
            p -= 2
        for k, d in enumerate(window):
            if d["fmt"] == 4 and d["op"] == "AND":
                for e in window[k + 1:]:
                    if e["fmt"] == 3 and e["op"].startswith("MOV") and \
                            e["rd"] == d["rs"]:
                        return e["imm"] + 1
        return None

    @staticmethod
    def no_dest(d):
        """Thumb instructions whose rd field is not written."""
        op = d["op"]
        return (op.startswith(("STR", "CMP", "CMN", "TST", "BX")) or
                d["fmt"] in (16, 17, 18, 19))

    # -- Thumb walk -------------------------------------------------------
    def walk_thumb(self, start, why, work):
        a = start
        regs = {}
        while True:
            if a in self.t or not self.in_rom(a) or a & 1:
                if not self.in_rom(a):
                    self.notes.append("Thumb flow leaves ROM at 0x%x (%s)" % (a, why))
                return
            if a in self.forbid or a + 1 in self.forbid:
                # Reached only by falling through a BL that GCC used as a far
                # jump, or a call that does not return: the bytes are a
                # literal pool or a switch table, not code.
                self.fell_into_data.add(a)
                return
            hw = u16(self.rom, a)
            d = tdecode(hw, a, u16(self.rom, a + 2))
            self.t[a] = d
            self.mark(a, d["len"], "T")
            f, op = d["fmt"], d["op"]
            nxt = a + d["len"]
            if f == 0:
                return
            if f == 6:
                lit = d["lit"]
                v = u32(self.rom, lit)
                if v is not None:
                    self.lits[lit] = v
                    self.mark(lit, 4, "L")
                    regs[d["rd"]] = v
            elif f == 12 and "adr" in d:
                regs[d["rd"]] = d["adr"]
                self.adr_refs.add(d["adr"])
            elif f == 3 and op.startswith("MOV"):
                regs[d["rd"]] = d["imm"]
            elif f == 5 and op.startswith("MOV hi") and "->pc" not in op:
                v = regs.get(d["rs"]) if d["rs"] != 15 else a + 4
                if v is None:
                    regs.pop(d["rd"], None)
                else:
                    regs[d["rd"]] = v
                if d["rd"] == 14 and regs.get(14) is not None:
                    v = regs[14]
                    if v & 1 and self.in_rom(v & ~1):
                        work.append(("T", v & ~1, "lr constant at 0x%x" % a))
            elif f == 2 and d["imm"] is not None and regs.get(d["rs"]) is not None:
                regs[d["rd"]] = regs[d["rs"]] + (d["imm"] if op.startswith("ADD") else -d["imm"])
            elif f == 1 and d["imm"] == 0 and op.startswith("LSL") and \
                    regs.get(d["rs"]) is not None:
                regs[d["rd"]] = regs[d["rs"]]
            elif f == 3 and op.startswith(("ADD", "SUB")) and regs.get(d["rd"]) is not None:
                regs[d["rd"]] += d["imm"] if op.startswith("ADD") else -d["imm"]
            elif f == 15 and op.startswith("LDMIA"):
                regs = {k: v for k, v in regs.items()
                        if not (d["rlist"] >> k) & 1 and k != d["rb"]}
            elif f == 15:
                regs.pop(d["rb"], None)
            elif f == 14 and op.startswith("POP"):
                regs = {k: v for k, v in regs.items() if not (d["rlist"] >> k) & 1}
            elif "rd" in d and not self.no_dest(d):
                regs.pop(d["rd"], None)
            if f == 16:
                work.append(("T", d["target"], "bcc"))
                a = nxt
                continue
            if f == 18:
                work.append(("T", d["target"], "b"))
                return
            if f == 19:
                if op != "BL":
                    return
                tgt = d["target"]
                self.funcs.add(tgt)
                work.append(("T", tgt, "bl"))
                kind = self.classify_case_helper(tgt)
                if kind:
                    self.do_case(a, nxt, kind, work)
                    return
                regs = {}
                a = nxt
                continue
            if f == 5 and op.startswith("BX"):
                rs = d["rs"]
                if rs == 14:
                    self.returns["bx lr"] += 1
                    return
                v = regs.get(rs)
                pd = self.t.get(a - 2)
                if v is None and pd and pd["fmt"] == 14 and pd["op"] == "POP" and \
                        (pd["rlist"] >> rs) & 1:
                    self.returns["pop {rX}; bx rX"] += 1
                    return
                if v is None:
                    self.unresolved["bx r%d" % rs] += 1
                    self.unresolved_at.append(a)
                elif v & 1:
                    work.append(("T", v & ~1, "bx const at 0x%x" % a))
                else:
                    self.arm_targets[v] += 1
                    if self.in_rom(v):
                        work.append(("A", v, "bx const at 0x%x" % a))
                return
            if f == 5 and "->pc" in op:
                v = regs.get(d["rs"])
                if v is None:
                    self.unresolved[op + " r%d" % d["rs"]] += 1
                    self.unresolved_at.append(a)
                else:
                    work.append(("T", v & ~1, "mov pc const"))
                return
            if f == 14 and d.get("r") and op.startswith("POP"):
                self.returns["pop {.., pc}"] += 1
                return
            if f == 17:
                self.notes.append("SWI at 0x%x" % a)
            a = nxt

    def do_case(self, bl, after, kind, work):
        name, esz = kind
        n = self.case_count(bl)
        if n is None:
            self.notes.append("switch table after BL at 0x%x: no bound found" % bl)
            return
        base = after
        if name == "si":
            base = (after + 3) & ~3
        tsize = n * esz
        self.mark(after, (base - after) + tsize, "J")
        for i in range(n):
            if esz == 1:
                e = self.rom[base + i]
                e = sext(e, 8) if name == "sqi" else e
                tgt = after + e * 2
            elif esz == 2:
                e = u16(self.rom, base + 2 * i)
                e = sext(e, 16) if name == "shi" else e
                tgt = after + e * 2
            else:
                e = sext(u32(self.rom, base + 4 * i), 32)
                tgt = base + e
            work.append(("T", tgt, "case"))
        self.case_tables.append((bl, name, n, tsize))

    # -- ARM walk ---------------------------------------------------------
    def walk_arm(self, start, why, work):
        a = start
        regs = {}
        while True:
            if a in self.a or not self.in_rom(a) or a & 3:
                return
            w = u32(self.rom, a)
            d = adecode(w, a)
            self.a[a] = d
            self.mark(a, 4, "A")
            op = d["op"]
            cond = d["cond"]
            if op.startswith("ADD imm") and d.get("rn") == 15:
                regs[d["rd"]] = a + 8 + d["imm"]
            elif op.startswith("LDR imm") and d.get("rn") == 15:
                lit = a + 8 + (d["imm"] if d["u"] else -d["imm"])
                v = u32(self.rom, lit)
                if v is not None:
                    self.lits[lit] = v
                    self.mark(lit, 4, "L")
                    regs[d["rd"]] = v
                if "->pc" in op:
                    return
            elif op.startswith("ORR imm") and d.get("rn") == 14:
                regs[d["rd"]] = "lr|1"
            if op == "BX":
                v = regs.get(d["rm"])
                if v == "lr|1":
                    pass                     # return to the Thumb caller
                elif isinstance(v, int):
                    work.append(("T" if v & 1 else "A", v & ~1, "arm bx"))
                if cond == "AL":
                    return
            if op in ("B", "BL"):
                work.append(("A", d["target"], op.lower()))
                if op == "B" and cond == "AL":
                    return
            if "->pc" in op or op.startswith("UNDEF") or op.startswith("cond="):
                return
            a += 4

    def run(self):
        """Walk to a fixed point: bytes found to be literals or switch tables
        in one round stop the fall-through into them in the next."""
        self.forbid = set()
        for _ in range(8):
            self.reset()
            self.run_once()
            data = self.data_bytes
            if data <= self.forbid:
                break
            self.forbid |= data

    def reset(self):
        self.t, self.a, self.lits = {}, {}, {}
        self.funcs, self.entries = set(), {}
        self.arm_targets, self.unresolved = Counter(), Counter()
        self.case_tables, self.notes, self.cover = [], [], {}
        self.adr_refs, self.fell_into_data = set(), set()
        self.unresolved_at = []
        self.returns = Counter()
        self.data_bytes = set()

    def run_once(self):
        work = []
        e = self.info["entry"]
        work.append(("T", e, "entry"))
        self.entries[e] = "upstream entry (Thumb)"
        if self.info["family"] in ("CDF", "DPC+") and self.info["scheme"] != "CDFJ+":
            stub = e - 8
            work.append(("A", stub, "driver->custom ARM stub"))
        if self.info.get("helpers") is not None:
            for k in range(4):
                work.append(("T", self.info["helpers"] + 4 * k, "audio helper stub"))
        self.drain(work)
        # pass 2: odd literal / table words pointing at code
        lo, hi = self.code_extent()
        changed = True
        while changed:
            changed = False
            cands = set()
            for lit, v in self.lits.items():
                if v & 1 and lo <= (v & ~1) < hi + 0x400 and \
                        (v & ~1) not in self.t and self.looks_like_func(v & ~1):
                    cands.add((v & ~1, "literal 0x%x" % lit))
            for p in range(lo & ~3, min(hi + 0x400, self.size - 3), 4):
                if self.cover.get(p) in ("T", "A"):
                    continue
                v = u32(self.rom, p)
                if v & 1 and lo <= (v & ~1) < hi and (v & ~1) not in self.t and \
                        self.looks_like_func(v & ~1):
                    cands.add((v & ~1, "table word 0x%x" % p))
            for tgt, why in sorted(cands):
                if tgt in self.t or tgt in self.forbid:
                    continue
                self.entries[tgt] = "pointer: " + why
                self.drain([("T", tgt, why)])
                changed = True
            lo, hi = self.code_extent()

    def looks_like_func(self, a):
        hw = u16(self.rom, a)
        if hw is None:
            return False
        d = tdecode(hw, a, u16(self.rom, a + 2))
        return d["fmt"] == 14 and d["op"].startswith("PUSH lr")

    def drain(self, work):
        while work:
            st, a, why = work.pop()
            if st == "T":
                self.walk_thumb(a, why, work)
            else:
                self.walk_arm(a, why, work)

    def code_extent(self):
        ts = [a for a in self.t if a >= self.info["entry"] - 0x10]
        if not ts:
            return (0, 0)
        return (min(ts), max(ts) + 2)


# ---------------------------------------------------------------------------
# Other static facts
# ---------------------------------------------------------------------------

def driver_periph(rom, end):
    """Constant stores to 0xE0000000+ in the driver's straight-line init."""
    regs = {}
    out = []
    for a in range(0, end, 4):
        w = u32(rom, a)
        d = adecode(w, a)
        op = d["op"]
        if op.startswith("LDR imm") and d.get("rn") == 15 and d["cond"] == "AL":
            lit = a + 8 + (d["imm"] if d["u"] else -d["imm"])
            regs[d["rd"]] = u32(rom, lit)
        elif op.startswith("MOV imm") and d["cond"] == "AL":
            regs[d["rd"]] = d["imm"]
        elif op.startswith("STR") and "imm" in op and d["cond"] == "AL":
            base = regs.get(d["rn"])
            val = regs.get(d["rd"])
            if base is not None and base >= 0xE0000000:
                addr = base + (d["imm"] if d["u"] else -d["imm"])
                out.append((a, addr, val))
        elif op in ("B", "BX") and d["cond"] == "AL":
            regs = {}
    return out


PERIPH = {0xE01FC000: "MAMCR", 0xE01FC004: "MAMTIM", 0xE01FC080: "PLLCON",
          0xE01FC084: "PLLCFG", 0xE01FC08C: "PLLFEED", 0xE01FC100: "VPBDIV",
          0xE01FC040: "MEMMAP", 0xE0008004: "T1TCR", 0xE0008008: "T1TC",
          0xE0004004: "T0TCR"}


def callfn_sites(rom, info):
    """6507 stores to the CALLFN register: CDF $1FF3 (mirrors), DPC+ $105A."""
    reg = 0x05A if info["family"] == "DPC+" else 0xFF3
    sites = []
    for p in range(info["bank0"], len(rom) - 2):
        if rom[p] in (0x8D, 0x8E, 0x8C):
            addr = rom[p + 1] | rom[p + 2] << 8
            if addr & 0x1000 and (addr & 0xFFF) == reg:
                sites.append(p)
    return sites


RIOT_TIMERS = {0x94: ("TIM1T", 1), 0x95: ("TIM8T", 8), 0x96: ("TIM64T", 64),
               0x97: ("T1024T", 1024)}


def riot_timer_loads(rom, info):
    """6507 stores of an immediate to a RIOT timer (any mirror with A12 = 0,
    A9 = 1, A7 = 1), with the immediate found by walking back to the last
    LDA/LDX/LDY # of the same register. The windows these set (VBLANK,
    overscan) bound how long an ARM call made inside them may take."""
    st = {0x8D: 0xA9, 0x8E: 0xA2, 0x8C: 0xA0}      # STA/STX/STY abs -> LDx #
    out = []
    for p in range(info["bank0"] + 2, len(rom) - 2):
        op = rom[p]
        if op in st and rom[p + 1] in RIOT_TIMERS and (rom[p + 2] & 0x12) == 0x02:
            for q in range(p - 2, max(p - 16, 0), -1):
                if rom[q] == st[op]:
                    name, scale = RIOT_TIMERS[rom[p + 1]]
                    out.append((p, name, rom[q + 1], rom[q + 1] * scale))
                    break
    return out


def crt0(scan):
    """The entry stub's literal pool: a call counter in RAM, then .bss
    (end, start; not in DPC+), .data (ROM source, RAM end, RAM start), the
    stub's own return address and main()."""
    lits = [v for a, v in sorted(scan.lits.items())
            if scan.info["entry"] <= a < scan.info["entry"] + 0x60]
    out = {"literals": [hex(v) for v in lits]}
    if len(lits) == 8:
        out.update(counter=hex(lits[0]), bss=(hex(lits[2]), hex(lits[1])),
                   bss_bytes=lits[1] - lits[2], data_rom=hex(lits[3]),
                   data=(hex(lits[5]), hex(lits[4])), data_bytes=lits[4] - lits[5],
                   main=hex(lits[7] & ~1))
    elif len(lits) == 6:
        out.update(counter=hex(lits[0]), bss=None, bss_bytes=0,
                   data_rom=hex(lits[1]), data=(hex(lits[3]), hex(lits[2])),
                   data_bytes=lits[2] - lits[3], main=hex(lits[5] & ~1))
    return out


def objdump_ranges(path, ranges, thumb, out):
    for lo, hi in ranges:
        args = ["arm-none-eabi-objdump", "-D", "-b", "binary", "-marmv4t",
                "--start-address=0x%x" % lo, "--stop-address=0x%x" % hi, path]
        if thumb:
            args.insert(5, "-Mforce-thumb")
        r = subprocess.run(args, capture_output=True, text=True)
        lines = r.stdout.splitlines()
        body = [l for l in lines if l.startswith(" ") or l.startswith("\t")]
        out.write("; %s 0x%x-0x%x\n" % ("Thumb" if thumb else "ARM", lo, hi))
        out.write("\n".join(body) + "\n")


def ranges_of(addrs, gap=4):
    out = []
    for a in sorted(addrs):
        if out and a <= out[-1][1] + gap:
            out[-1][1] = max(out[-1][1], a)
        else:
            out.append([a, a])
    return out


OBJ = {  # this decoder's op -> objdump (binutils, -marmv4t) mnemonics
    "LSL": {"lsls", "movs"}, "LSR": {"lsrs"}, "ASR": {"asrs"},
    "ADD imm3": {"adds"}, "SUB imm3": {"subs"}, "ADD reg": {"adds"},
    "SUB reg": {"subs"}, "MOV imm8": {"movs"}, "CMP imm8": {"cmp"},
    "ADD imm8": {"adds"}, "SUB imm8": {"subs"}, "AND": {"ands"},
    "EOR": {"eors"}, "ADC": {"adcs"}, "SBC": {"sbcs"}, "ROR": {"rors"},
    "TST": {"tst"}, "NEG": {"negs", "rsbs"}, "CMP": {"cmp"}, "CMN": {"cmn"},
    "ORR": {"orrs"}, "MUL": {"muls"}, "BIC": {"bics"}, "MVN": {"mvns"},
    "ADD hi": {"add"}, "CMP hi": {"cmp"}, "MOV hi": {"mov", "nop"},
    "BX": {"bx"}, "LDR [pc]": {"ldr"}, "LDR": {"ldr"}, "STR": {"str"},
    "LDRB": {"ldrb"}, "STRB": {"strb"}, "STRH": {"strh"}, "LDRH": {"ldrh"},
    "LDSB": {"ldrsb"}, "LDSH": {"ldrsh"}, "LDR [sp]": {"ldr"},
    "STR [sp]": {"str"}, "ADD rd": {"add"}, "ADD sp": {"add"},
    "SUB sp": {"sub"}, "PUSH": {"push"}, "POP": {"pop"}, "LDMIA": {"ldmia"},
    "STMIA": {"stmia"}, "SWI": {"svc", "swi"}, "B": {"b"}, "BL": {"bl"},
}


def check_objdump(path, scan):
    """Compare every reached Thumb instruction with objdump's mnemonic."""
    lo, hi = scan.code_extent()
    los = [a for a in scan.t if a < lo]
    r = subprocess.run(["arm-none-eabi-objdump", "-D", "-b", "binary",
                        "-marmv4t", "-Mforce-thumb",
                        "--start-address=0x%x" % min([lo] + los),
                        "--stop-address=0x%x" % hi, path],
                       capture_output=True, text=True)
    mn = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0].strip().endswith(":"):
            try:
                mn[int(parts[0].strip()[:-1], 16)] = parts[2].split()[0] if parts[2].split() else ""
            except ValueError:
                pass
    good, bad = 0, []
    for a, d in scan.t.items():
        if d["fmt"] == 0:
            continue
        m = mn.get(a)
        if m is None:   # objdump's linear sweep was out of step here
            r = subprocess.run(["arm-none-eabi-objdump", "-D", "-b", "binary",
                                "-marmv4t", "-Mforce-thumb",
                                "--start-address=0x%x" % a,
                                "--stop-address=0x%x" % (a + d["len"]), path],
                               capture_output=True, text=True)
            m = "?"
            for line in r.stdout.splitlines():
                parts = line.split("\t")
                if len(parts) >= 3 and parts[0].strip() == "%x:" % a:
                    m = parts[2].split()[0]
        m = m.split(".")[0]
        key = d["op"]
        if d["fmt"] == 16:
            ok = m.startswith("b") and m[1:].upper() == key[1:]
        else:
            cands = [k for k in OBJ if key == k or key.startswith(k + " ") or
                     key.startswith(k + ",")]
            exp = OBJ[max(cands, key=len)] if cands else set()
            ok = m in exp
        if ok:
            good += 1
        else:
            bad.append((hex(a), key, m))
    return good, bad


# Thumb flag effects: (sets N/Z, sets C, sets V, reads C, reads V/N/Z)
def flag_use(d):
    f, op = d["fmt"], d["op"]
    if f == 1:
        return (True, not op.endswith("#0"), False, False, False)
    if f == 2:
        return (True, True, True, False, False)
    if f == 3:
        mov = op.startswith("MOV")
        return (True, not mov, not mov, False, False)
    if f == 4:
        base = op.split()[0]
        if base in ("ADC", "SBC"):
            return (True, True, True, True, False)
        if base in ("NEG", "CMP", "CMN"):
            return (True, True, True, False, False)
        if base in ("LSL", "LSR", "ASR", "ROR"):
            # C passes through when Rs[7:0] == 0: neither a reader nor a
            # certain writer, so the search goes on past it.
            return (True, False, False, False, False)
        if base == "MUL":
            return (True, False, False, False, False)
        return (True, False, False, False, False)      # logical: C, V kept
    if f == 5 and op.startswith("CMP"):
        return (True, True, True, False, False)
    if f == 16:
        c = op[1:]
        return (False, False, False, c in ("CS", "CC", "HI", "LS"),
                c in ("VS", "VC", "GE", "LT", "GT", "LE"))
    return (False, False, False, False, False)


def mul_flag_readers(scan):
    """MULS leaves C UNPREDICTABLE on ARMv4 (the ARM7TDMI writes a meaningless
    value) and V unchanged. Count MULs whose C is read on the fall-through
    path before anything writes C again."""
    readers = []
    for a, d in scan.t.items():
        if d["fmt"] != 4 or not d["op"].startswith("MUL"):
            continue
        p = a + 2
        for _ in range(16):
            e = scan.t.get(p)
            if e is None:
                break
            nz, c, v, rc, rv = flag_use(e)
            if rc:
                readers.append(hex(p))
                break
            if c or e["fmt"] in (14, 18, 19) or e["op"].startswith("BX") or \
                    e["fmt"] == 16:
                break
            p += e["len"]
    return readers


def gaps(scan, lo, hi):
    """Bytes of [lo, hi) neither reached code nor known data, grouped into
    runs; for each run, how many Thumb PUSH {.., lr} prologues it holds
    (a hint of code that indirect flow reaches and this scan does not)."""
    out = []
    a = lo
    while a < hi:
        if a in scan.cover:
            a += 1
            continue
        b = a
        while b < hi and b not in scan.cover:
            b += 1
        g0 = (a + 1) & ~1
        pro = sum(1 for p in range(g0, b - 1, 2) if scan.looks_like_func(p))
        zero = all(x == 0 for x in scan.rom[a:b])
        out.append((a, b, pro, zero))
        a = b
    return out


def analyse(path, listdir=None, check=False):
    rom = open(path, "rb").read()
    info = detect(rom)
    res = {"file": os.path.basename(path), "info": info}
    if info["scheme"] == "unknown":
        return res
    s = Scan(rom, info)
    s.run()
    tfmt = Counter()
    tops = Counter()
    for a, d in s.t.items():
        tfmt[d["fmt"]] += 1
        tops[(d["fmt"], d["op"])] += 1
    aops = Counter(d["op"] + ("" if d["cond"] == "AL" else " (cond)")
                   for d in s.a.values())
    thumb_bytes = sum(d["len"] for d in s.t.values())
    lit_bytes = 4 * len([l for l in s.lits if s.cover.get(l) == "L"])
    lo, hi = s.code_extent()
    # Literal value classes
    lv = defaultdict(set)
    for lit, v in s.lits.items():
        if 0x40000000 <= v < 0x40000000 + 0x10000:
            lv["ram"].add(v)
        elif v >= 0xE0000000:
            lv["mmio"].add(v)
        elif v < len(rom):
            lv["rom_odd" if v & 1 else "rom_even"].add(v)
        else:
            lv["other"].add(v)
    rom_data = sorted(v for v in lv["rom_even"] if s.cover.get(v) not in ("T", "A"))
    res.update({
        "thumb_insns": len(s.t),
        "thumb_bytes": thumb_bytes,
        "thumb_halfwords": sum(d["len"] // 2 for d in s.t.values()),
        "arm_insns": len(s.a),
        "arm_ranges": [(hex(a), hex(b + 4)) for a, b in ranges_of(s.a)],
        "literal_bytes": lit_bytes,
        "case_tables": len(s.case_tables),
        "case_table_bytes": sum(t[3] for t in s.case_tables),
        "case_kinds": dict(Counter(t[1] for t in s.case_tables)),
        "code_extent": (hex(lo), hex(hi)),
        "code_span_bytes": hi - lo,
        "functions_bl": len(s.funcs),
        "pointer_entries": sum(1 for v in s.entries.values() if v.startswith("pointer")),
        "thumb_formats": {"%d %s" % (k, FMT_NAMES[k]): v for k, v in sorted(tfmt.items())},
        "thumb_ops": {"%02d %s" % k: v for k, v in sorted(tops.items())},
        "arm_ops": dict(sorted(aops.items())),
        "arm_targets": {hex(k): v for k, v in s.arm_targets.items()},
        "unresolved_indirect": dict(s.unresolved),
        "unresolved_at": [hex(a) for a in sorted(s.unresolved_at)],
        "mul_c_readers": mul_flag_readers(s),
        "returns": dict(s.returns),
        "lit_ram": (hex(min(lv["ram"])), hex(max(lv["ram"]))) if lv["ram"] else None,
        "lit_ram_count": len(lv["ram"]),
        "lit_ram_odd": sorted(hex(v) for v in lv["ram"] if v & 1),
        "lit_mmio": sorted(hex(v) for v in lv["mmio"]),
        "lit_rom_data": (hex(rom_data[0]), hex(rom_data[-1])) if rom_data else None,
        "lit_rom_data_count": len(rom_data),
        "lit_rom_data_below_code": len([v for v in rom_data if v < lo]),
        "lit_rom_data_above_code": len([v for v in rom_data if v >= hi]),
        "crt0": crt0(s),
        "driver_periph": [(hex(a), PERIPH.get(addr, hex(addr)),
                           None if v is None else hex(v))
                          for a, addr, v in driver_periph(rom, info["driver_size"])],
        "callfn_sites": len(callfn_sites(rom, info)),
        "callfn_at": [hex(a) for a in callfn_sites(rom, info)],
        "riot_timer_loads": [(hex(a), n, v, c) for a, n, v, c in riot_timer_loads(rom, info)],
        "gap_bytes": sum(b - a for a, b, _, z in gaps(s, lo, hi) if not z),
        "gap_runs": len(gaps(s, lo, hi)),
        "gap_prologues": sum(pp for _, _, pp, _ in gaps(s, lo, hi)),
        "gap_big": [(hex(a), b - a, pp) for a, b, pp, z in gaps(s, lo, hi)
                    if b - a >= 64 and not z],
        "notes": s.notes[:20],
        "bl_fallthrough_into_data": len(s.fell_into_data),
        "pointer_entry_list": sorted((hex(k), v) for k, v in s.entries.items()
                                     if v.startswith("pointer")),
        "thumb_in_driver": len([a for a in s.t if a < info["driver_size"]]),
        "thumb_ranges": len(ranges_of(s.t)),
    })
    if check:
        good, bad = check_objdump(path, s)
        res["objdump_agree"] = good
        res["objdump_disagree"] = bad[:20]
        res["objdump_disagree_count"] = len(bad)
    if listdir:
        os.makedirs(listdir, exist_ok=True)
        base = os.path.splitext(os.path.basename(path))[0]
        with open(os.path.join(listdir, base + ".lst"), "w") as out:
            out.write("; reached code only (daria_scan.py); game-derived, do not commit\n")
            objdump_ranges(path, [(a, b + 4) for a, b in ranges_of(s.a)], False, out)
            tr = []
            for a, b in ranges_of(s.t):
                tr.append((a, b + s.t[b]["len"]))
            objdump_ranges(path, tr, True, out)
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("roms", nargs="+")
    ap.add_argument("--json")
    ap.add_argument("--listdir")
    ap.add_argument("--check", action="store_true",
                    help="cross-check the Thumb decode against objdump")
    a = ap.parse_args()
    results = [analyse(p, a.listdir, a.check) for p in a.roms]
    for r in results:
        i = r["info"]
        if i["scheme"] == "unknown":
            print("%s: not a DPC+/CDF image" % r["file"])
            continue
        print("%-44s %-5s %6d B  entry 0x%04x  Thumb %5d insns %6d B  ARM %3d  "
              "span %s  lit %5d B  case %d" % (
                  r["file"], i["scheme"], i["size"], i["entry"], r["thumb_insns"],
                  r["thumb_bytes"], r["arm_insns"], r["code_extent"],
                  r["literal_bytes"], r["case_tables"]))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(results, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
