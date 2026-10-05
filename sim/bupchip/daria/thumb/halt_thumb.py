#!/usr/bin/env python3
"""Halt tests of DARIA's Thumb (docs/DARIA_CORE.md, "What halts" and
"Verification", the "Halts" row): every row of the halt table at a known
address, with the expected halt code and halt_pc, and the neighbours that
must not halt.

  halt_thumb.py WORKDIR IMAGE.a78 TB TB_LATE REF_TRACE LOCKSTEP [NAME ...]

TB and TB_LATE are build_tb.sh's tb_thumb (plain and LATE_RF=1), REF_TRACE
../../verif's tb_ref_trace and LOCKSTEP its tb_lockstep built with DUT=bup
THUMB=1. IMAGE.a78 must hold 1 KiB of assets (run_halts.sh makes it), so
that 0x02000400 is the first byte past the asset window. NAMEs pick cases
(substrings); JOBS (default 2) cases run at once.

Each case is a program: directed/common.inc's start-up (ARM, then BX into
Thumb), a set-up (r0 = r3 = 0x40001000, r1 = 1, r2 = 2, r5 = 0x5555AAAA,
r6 = 0, r7 = 0x40002000), the case, and the end marker, which a core that
does not halt reaches. "expect_halt:" labels the instruction responsible.
"@at ADDR" moves the rest of the case to ADDR (through r4), for targets
past the end of the code space and for running off it; at 0x3FF0 and
above there is no end marker after it. Frame "arm" is an ARM-only program
(the BupChip profile's cases, run with +arm_only=1).

Every halting case runs on the core alone (tb_thumb) three ways: plain,
built with LATE_RF, and with +throttle=25 +await=40 (seed 7). Each must
halt with the expected code at the expected address; an UNDEF or FLAGS
halt must not have retired the instruction (halt at once), and a FETCH or
THUMB halt must have retired it (halt one clock later). Then:
  ref "exc": tb_ref_trace must take its undefined-instruction or SWI
    exception at the same address (the first EXC retire), and stop at the
    vector's FAULT write (0xE1 or 0xE2);
  ref "natural": the reference runs the encoding without an exception and
    reaches the end marker (BX with H1 or SBZ bits, the H1 = H2 = 0 forms);
  data halts (5, 6, 7): the reference's behaviour is reported, and where
    it takes a data abort the case also runs in lockstep with +abort_ok=1,
    which must pass (the core halts, everything before it matched).
Code 0 cases must not halt: the core alone reaches the end marker in all
three ways, the reference reaches it with no exception, and the lockstep
passes.
Prints one line per case, then the pass counts per check; exit status 1
if any case fails.
SPDX-License-Identifier: MIT
"""
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

NONE, UNDEF, REG, THUMB, FETCH, DATA, RO, BLOCK, FLAGS = 0, 1, 2, 3, 4, 5, 6, 7, 8
NAMES = {0: "none", 1: "UNDEF", 2: "REG", 3: "THUMB", 4: "FETCH", 5: "DATA", 6: "RO", 7: "BLOCK", 8: "FLAGS"}

# The readers of C after a MUL (each must halt with FLAGS), the writers
# (after each, a reader must not halt), and a MUL to start from.
MUL = "muls r1, r2\n"
TOARM = "ldr r4, =1f\nbx r4\n.balign 4\n.arm\n1:\n"


def hw(h):
    return ".hword 0x%04x" % h


def undef(h, ref="exc"):
    return (UNDEF, "expect_halt: " + hw(h) + "\n.hword 0xde00", {"ref": ref})


CASES = []


def case(name, code, body, **o):
    CASES.append((name, code, body, o))


# ---- 1 UNDEF ----------------------------------------------------------------
for h in (0xdf00, 0xdf12, 0xdfff):
    case("swi_%04x" % h, UNDEF, "expect_halt: " + hw(h), ref="exc")
for h in (0xde00, 0xde7f, 0xdeff):
    case("bcc14_%04x" % h, UNDEF, "movs r6, #0\nexpect_halt: " + hw(h), ref="exc")
for h in (0xb100, 0xb1ff, 0xb200, 0xb280, 0xb2c0, 0xb300, 0xb3ff,
          0xb600, 0xb650, 0xb660, 0xb6ff, 0xb700, 0xb7ff, 0xb800, 0xb9ff, 0xba00, 0xba40, 0xbac0, 0xbb00, 0xbbff,
          0xbe00, 0xbeff, 0xbf00, 0xbf10, 0xbfff,
          0xe800, 0xe801, 0xebff, 0xec00, 0xefff):
    case("undef_%04x" % h, UNDEF, "expect_halt: " + hw(h), ref="exc")
# BX with H1 = 1, or with bits 2:0 set: the reference does a plain BX to Rm,
# so Rm holds the next instruction.
for h, rm in ((0x4788, "r1"), (0x4780, "r0"), (0x47c0, "r8"), (0x47f0, "lr"),
              (0x4701, "r0"), (0x4704, "r0"), (0x4721, "r4"), (0x4747, "r8"), (0x4777, "lr")):
    set_rm = ("ldr r4, =1f + 1\nmov %s, r4\n" % rm) if rm in ("r8", "lr") or rm != "r4" else "ldr r4, =1f + 1\n"
    if rm in ("r0", "r1"):
        set_rm = "ldr %s, =1f + 1\n" % rm
    case("bx_%04x" % h, UNDEF, set_rm + ".balign 4\nexpect_halt: " + hw(h) + "\n.hword 0xde00\n.balign 4\n1:",
         ref="natural")
# BX PC with bits 2:0 set (0x477F): the reference's BX PC; at a word-aligned
# address it goes to ARM at the address + 4.
case("bx_477f", UNDEF, ".balign 4\nexpect_halt: .hword 0x477f\n.hword 0xde00\n.arm\nadr r4, 1f + 1\nbx r4\n.thumb\n1:",
     ref="natural")
# ADD, CMP, MOV with H1 = H2 = 0 (natural on the reference).
for h in (0x4400, 0x4411, 0x443f, 0x4500, 0x4511, 0x453f, 0x4600, 0x4611, 0x463f):
    case("lolo_%04x" % h, UNDEF, "expect_halt: " + hw(h), ref="natural")
# Empty lists.
for h in (0xc000, 0xc300, 0xc700, 0xc800, 0xcb00, 0xcf00, 0xb400, 0xbc00):
    case("empty_%04x" % h, UNDEF, "expect_halt: " + hw(h))

# ---- 4 FETCH: a target outside the code space, one clock later ------------------
case("b_out_fwd", FETCH, "@at 0x3c00\nexpect_halt: b . + 0x7fe")            # imm11 0x3FF: 0x4402
case("b_out_back", FETCH, "expect_halt: .hword 0xe400")                      # -2048 from below 0x800
case("bcc_out_fwd", FETCH, "@at 0x3f80\ncmp r6, #0\nexpect_halt: .hword 0xd07f")   # beq +254: 0x4084
case("bcc_out_back", FETCH, "cmp r6, #0\nexpect_halt: .hword 0xd080")        # beq -256 from below 0x100
case("bl_out_fwd", FETCH, ".hword 0xf004\nexpect_halt: .hword 0xf800")       # LR = A + 4 + 0x4000
case("bl_out_back", FETCH, ".hword 0xf7f0\nexpect_halt: .hword 0xf800")      # LR = A + 4 - 0x10000
case("bl_out_far", FETCH, "@at 0x3ff0\n.hword 0xf000\nexpect_halt: .hword 0xf7ff")  # 0x3FF6 + 0xFFE
case("bl_suffix_ram", FETCH, "ldr r4, =0x40000001\nmov lr, r4\nexpect_halt: .hword 0xf800")
case("bx_out_thumb_ram", FETCH, "ldr r1, =0x40000001\nexpect_halt: bx r1")
case("bx_out_arm_ram", FETCH, "ldr r1, =0x40000000\nexpect_halt: bx r1")
case("bx_out_4001", FETCH, "ldr r1, =0x4001\nexpect_halt: bx r1")
case("bx_out_4000", FETCH, "ldr r1, =0x4000\nexpect_halt: bx r1")
case("bx_out_neg", FETCH, "ldr r1, =0xfffffffc\nmov r9, r1\nexpect_halt: bx r9")
case("movpc_out", FETCH, "ldr r1, =0x4000\nexpect_halt: mov pc, r1")
case("movpc_out_hi", FETCH, "ldr r1, =0x80000001\nmov r8, r1\nexpect_halt: mov pc, r8")
case("addpc_out", FETCH, "ldr r1, =0x4000\nexpect_halt: add pc, r1")
case("addpc_out_neg", FETCH, "ldr r1, =0xfffffe00\nexpect_halt: add pc, r1")
case("addpc_out_hi", FETCH, "ldr r1, =0x02000000\nmov r12, r1\nexpect_halt: add pc, r12")
case("pop_pc_out", FETCH, "ldr r1, =0x40000001\npush {r1}\nexpect_halt: pop {pc}")
case("pop_pc_out_list", FETCH, "ldr r1, =0x4000\npush {r0-r1}\nexpect_halt: pop {r2, pc}")
case("bx_arm_bit1", FETCH, "ldr r1, =0x102\nexpect_halt: bx r1")
case("bx_arm_bit1_hi", FETCH, "ldr r1, =0x1006\nmov r10, r1\nexpect_halt: bx r10")
case("bx_pc_2mod4", FETCH, ".balign 4\nnop\nexpect_halt: bx pc\n.hword 0xde00\n.hword 0xde00")
# Running on past the last halfword, 0x3FFE: an instruction of each kind
# there; 0x3FFC (the low half) must not halt.
for nm, ins in (("alu", "movs r1, #1"), ("bcc_fails", "bne . + 4"), ("b_lone_prefix", ".hword 0xf000"),
                ("ldr", "ldr r1, [r0, #4]"), ("ldr_pc", "ldr r1, [pc, #0]"), ("str", "str r1, [r0, #4]"),
                ("str_reg", "str r1, [r0, r2]"), ("str_mmio", "str r5, [r4, #0x10]"),
                ("asset", "ldrsh r1, [r4, r2]"), ("shift_reg", "lsls r1, r2"), ("mul", "muls r1, r2"),
                ("push", "push {r1, r2}"), ("pop", "pop {r1}"), ("stmia", "stmia r0!, {r1, r2}"),
                ("ldmia", "ldmia r0!, {r1, r2}"), ("add_sp", "add sp, #4"), ("mov_hi", "mov r8, r1")):
    pre = {"str_mmio": "ldr r4, =0xe0009000\n", "asset": "ldr r4, =0x02000000\n",
           "pop": "push {r1}\n"}.get(nm, "")
    case("romend_" + nm, FETCH, pre + "@at 0x3ffc\nmovs r6, #0\nexpect_halt: " + ins)

# ---- 5, 6, 7: data outside every window, for every Thumb form ---------------------
case("ldr_nowhere", DATA, "ldr r1, =0x10000000\nexpect_halt: ldr r2, [r1, #0]")
case("ldrb_past_rom", DATA, "ldr r1, =0x4000\nexpect_halt: ldrb r2, [r1, r6]")
case("ldrh_past_ram", DATA, "ldr r1, =0x40004000\nexpect_halt: ldrh r2, [r1, #0]")
case("ldrsb_past_assets", DATA, "ldr r1, =0x02000400\nexpect_halt: ldrsb r2, [r1, r6]")
case("ldrsh_past_mmio", DATA, "ldr r1, =0xe0009100\nexpect_halt: ldrsh r2, [r1, r6]")
case("ldr_reg_nowhere", DATA, "ldr r1, =0x20000000\nexpect_halt: ldr r2, [r1, r6]")
case("ldrb_imm_past_assets", DATA, "ldr r1, =0x020003ff\nexpect_halt: ldrb r2, [r1, #1]")
case("ldr_pc_past_rom", DATA, "@at 0x3e00\nexpect_halt: ldr r2, [pc, #1020]")
case("ldr_sp_past_ram", DATA, "ldr r1, =0x40003ff0\nmov sp, r1\nexpect_halt: ldr r2, [sp, #16]")
case("str_wild", DATA, "ldr r1, =0x40004000\nexpect_halt: str r2, [r1, #0]\nnop")
case("strh_nowhere", DATA, "ldr r1, =0x80000000\nexpect_halt: strh r2, [r1, #0]")
case("strb_reg_nowhere", DATA, "ldr r1, =0x80000000\nexpect_halt: strb r2, [r1, r6]")
case("str_reg_past_mmio", DATA, "ldr r1, =0xe0009100\nexpect_halt: str r2, [r1, r6]")
case("str_sp_past_ram", DATA, "ldr r1, =0x40003ffc\nmov sp, r1\nexpect_halt: str r2, [sp, #4]")
case("str_rom", RO, "movs r1, #0x80\nlsls r1, r1, #1\nexpect_halt: str r2, [r1, #0]")
case("strh_reg_rom", RO, "movs r1, #0x80\nlsls r1, r1, #1\nexpect_halt: strh r2, [r1, r6]")
case("strb_assets", RO, "ldr r1, =0x02000000\nexpect_halt: strb r2, [r1, #0]")
case("str_sp_rom", RO, "movs r1, #0x80\nlsls r1, r1, #1\nmov sp, r1\nexpect_halt: str r2, [sp, #0]")
case("stmia_rom", RO, "movs r1, #0x80\nlsls r1, r1, #1\nexpect_halt: stmia r1!, {r2, r3}")
case("push_rom", RO, "movs r1, #0x80\nlsls r1, r1, #1\nmov sp, r1\nexpect_halt: push {r2}")
case("ldmia_mmio", BLOCK, "ldr r1, =0xe0009000\nexpect_halt: ldmia r1!, {r2}")
case("ldmia_assets", BLOCK, "ldr r1, =0x02000000\nexpect_halt: ldmia r1!, {r2, r3}")
case("ldmia_nowhere", BLOCK, "ldr r1, =0x10000000\nexpect_halt: ldmia r1!, {r2}")
case("stmia_past_ram", BLOCK, "ldr r1, =0x40003ffc\nexpect_halt: stmia r1!, {r2, r3}")
case("stmia_mmio", BLOCK, "ldr r1, =0xe0009010\nexpect_halt: stmia r1!, {r2}")
case("push_below_ram", BLOCK, "ldr r1, =0x40000000\nmov sp, r1\nexpect_halt: push {r2}")
case("pop_past_ram", BLOCK, "ldr r1, =0x40004000\nmov sp, r1\nexpect_halt: pop {r2}")
case("pop_pc_mmio", BLOCK, "ldr r1, =0xe0009000\nmov sp, r1\nexpect_halt: pop {pc}")
case("push_lr_mmio", BLOCK, "ldr r1, =0xe0009020\nmov sp, r1\nexpect_halt: push {lr}")

# ---- 8 FLAGS: a C reader after a Thumb MUL ------------------------------------------
for nm, rd in (("bcs", "bcs . + 4"), ("bcc", "bcc . + 4"), ("bhi", "bhi . + 4"), ("bls", "bls . + 4"),
               ("adc", "adcs r3, r1"), ("sbc", "sbcs r3, r1")):
    case("mul_" + nm, FLAGS, MUL + "expect_halt: " + rd)
    # after pass-throughs, which keep C unknown
    case("mul_pass_" + nm, FLAGS, MUL + "movs r3, #1\nlsls r3, r3, #0\nmovs r3, r1\nands r3, r1\neors r3, r2\n"
         "orrs r3, r1\nbics r3, r2\nmvns r3, r3\ntst r1, r2\nlsls r3, r6\nrors r3, r6\nmov r8, r1\nadd r3, r8\n"
         "ldr r4, [r7, #0]\nstr r4, [r7, #4]\npush {r1}\npop {r1}\nb 1f\n1:\nbeq 1f\n1:\nbmi 1f\n1:\nbvs 1f\n1:\n"
         "expect_halt: " + rd)
# Rd = Rm, and a second MUL
case("mul_rdrm_bhi", FLAGS, "muls r1, r1\nexpect_halt: bhi . + 4")
case("mul_twice_adc", FLAGS, "adds r3, r1, #0\nmuls r1, r2\nmuls r2, r1\nexpect_halt: adcs r3, r1")
# In ARM state after a BX there.
for nm, rd in (("cs", "addcs r3, r3, #1"), ("cc", "addcc r3, r3, #1"), ("hi", "addhi r3, r3, #1"),
               ("ls", "addls r3, r3, #1"), ("bcs", "bcs 2f\n2:"), ("adc", "adc r3, r1, r2"),
               ("sbc", "sbc r3, r1, r2"), ("rsc", "rsc r3, r1, r2"), ("adcs", "adcs r3, r1, r2"),
               ("rrx", "mov r3, r1, rrx"), ("rrxs", "movs r3, r1, rrx"), ("rrx_operand", "add r3, r2, r1, rrx"),
               ("ldr_rrx", "ldr r3, [r0, r6, rrx]"), ("mrs", "mrs r3, cpsr")):
    case("mul_arm_" + nm, FLAGS, MUL + TOARM + "expect_halt: " + rd)
case("mul_arm_pass_cs", FLAGS, MUL + TOARM + "movs r3, r1\nands r3, r3, r2\nmovs r3, #1\ntst r1, #3\nmov r3, r2, lsl #4\n"
     "movs r3, r1, lsl r6\nmul r3, r1, r2\nexpect_halt: addcs r3, r3, #1")

# ---- 0: must not halt ---------------------------------------------------------------
case("ok_b000", NONE, ".hword 0xb000")                                      # add sp, #0
case("ok_b080", NONE, ".hword 0xb080")                                      # sub sp, #0
case("ok_b500", NONE, ".hword 0xb500\npop {r3}")                            # push {lr}
case("ok_bd00", NONE, "ldr r1, =1f + 1\npush {r1}\n.hword 0xbd00\n.hword 0xde00\n.balign 4\n1:")  # pop {pc}
case("ok_dd00", NONE, "cmp r1, r2\n.hword 0xdd00\nnop\ncmp r2, r1\n.hword 0xdd00\nnop")  # ble .+4
case("ok_ddff", NONE, "cmp r1, r2\n.hword 0xddff\ncmp r2, r1\n.hword 0xddff\nnop")      # ble .+2
case("ok_dd80", NONE, "cmp r2, r1\n.hword 0xdd80\nnop")                                  # ble -256, not taken
case("ok_lone_f000", NONE, ".hword 0xf000\nmov r3, lr")
case("ok_lone_f7ff", NONE, ".hword 0xf7ff\nmov r3, lr")
case("ok_lone_f800", NONE, "ldr r4, =1f + 1\nmov lr, r4\n.hword 0xf800\n1:\nmov r3, lr")
case("ok_lone_f801", NONE, "ldr r4, =1f - 2\nmov lr, r4\n.hword 0xf801\n.balign 4\n1:\nmov r3, lr")
for h, d in ((0x4440, "add r0, r8"), (0x4480, "add r8, r0"), (0x4478, "add r0, pc"), (0x4540, "cmp r0, r8"),
             (0x4580, "cmp r8, r0"), (0x4578, "cmp r0, pc"), (0x4587, "cmp pc, r0"), (0x4640, "mov r0, r8"),
             (0x4680, "mov r8, r0"), (0x4678, "mov r0, pc"), (0x46c0, "mov r8, r8")):
    case("ok_hi_%04x" % h, NONE, "ldr r4, =0x12345678\nmov r8, r4\n" + hw(h))
case("ok_bx_4740", NONE, "ldr r4, =1f + 1\nmov r8, r4\n.hword 0x4740\n.hword 0xde00\n.balign 4\n1:")
case("ok_mul_rdrm", NONE, "ldr r1, =0x12345\nmuls r1, r1\nmovs r2, r1\nmuls r2, r2\nadds r3, r2, #0\nbcs 1f\n1:")
case("ok_mul_flags_nz", NONE, MUL + "beq 1f\n1:\nbne 1f\n1:\nbmi 1f\n1:\nbpl 1f\n1:\nbvs 1f\n1:\nbvc 1f\n1:\n"
     "bge 1f\n1:\nblt 1f\n1:\nbgt 1f\n1:\nble 1f\n1:")
# A writer after a MUL, then the readers: no halt.
for nm, w in (("adds", "adds r3, r1, r2"), ("subs", "subs r3, r1, #0"), ("adds8", "adds r3, #1"),
              ("cmp", "cmp r1, #5"), ("cmp_reg", "cmp r1, r2"), ("cmn", "cmn r1, r2"), ("negs", "negs r3, r1"),
              ("cmp_hi", "cmp r1, r8"), ("lsls1", "lsls r3, r1, #1"), ("lsrs32", "lsrs r3, r1, #32"),
              ("asrs1", "asrs r3, r1, #1"), ("lsls_reg", "lsls r3, r2"), ("rors_reg", "rors r3, r2")):
    case("ok_mul_" + nm, NONE, "ldr r4, =0x80000000\nmov r8, r4\n" + MUL + w +
         "\nbcs 1f\n1:\nbcc 1f\n1:\nbhi 1f\n1:\nbls 1f\n1:\nadcs r3, r1\nsbcs r3, r2")
for nm, w in (("adds", "adds r3, r1, r2"), ("movs_lsl", "movs r3, r1, lsl #1"), ("movs_rot", "movs r3, #0x80000000"),
              ("msr", "msr cpsr_f, #0x20000000"), ("cmp", "cmp r1, r2"), ("tst_lsr", "tst r1, r2, lsr #1"),
              ("movs_reg", "movs r3, r1, lsl r2")):
    case("ok_mul_arm_" + nm, NONE, MUL + TOARM + w +
         "\naddcs r3, r3, #1\naddls r3, r3, #1\nadc r3, r1, r2\nrsc r3, r1, r2\nmov r3, r1, rrx\nmrs r3, cpsr\n"
         "adr r4, 2f + 1\nbx r4\n.thumb\n2:")

# ---- 3 THUMB: the BupChip profile (arm_only), ARM only ---------------------------------
case("armonly_bx_odd", THUMB, "ldr r1, =0x101\nexpect_halt: bx r1", frame="arm", arm_only=True)
case("armonly_bx_thumb", THUMB, "adr r1, 1f + 1\nexpect_halt: bx r1\n1:\nnop", frame="arm", arm_only=True)
case("armonly_bx_ram_odd", THUMB, "ldr r1, =0x40000001\nexpect_halt: bx r1", frame="arm", arm_only=True)
case("armonly_bx_even", NONE, "adr r1, 1f\nbx r1\n1:\nnop", frame="arm", arm_only=True)

START_THUMB = """#include "common.inc"
\tSTART
thumb_main:
\tldr\tr0, =0x40001000
\tmovs\tr1, #1
\tmovs\tr2, #2
\tldr\tr3, =0x40001000
\tldr\tr5, =0x5555aaaa
\tmovs\tr6, #0
\tldr\tr7, =DATA
\tPOOL
"""
START_ARM = """\t.syntax unified
\t.cpu arm7tdmi
\t.section .vectors, "ax"
\t.arm
\t.global _start
_start:
\tb\treset
\t.rept 7
\tb\t.
\t.endr
\t.text
reset:
\tldr\tsp, =__stack_top
\tldr\tr0, =0x40001000
\tmov\tr1, #1
\tmov\tr2, #2
"""
END_ARM = """\tldr\tr1, =0xe000901c
\tmov\tr0, #0xaa
\tstr\tr0, [r1]
\tb\t.
\t.ltorg
"""


def source(code, body, o):
    arm = o.get("frame") == "arm"
    out = [START_ARM if arm else START_THUMB]
    end = True
    for line in body.split("\n"):
        line = line.strip()
        if line.startswith("@at "):
            at = int(line[4:], 16)
            out.append("\tldr\tr4, =case_at + 1\n\tbx\tr4\n\t.ltorg\n\t.org\t0x%x - 0x20\ncase_at:\n" % at)
            end = at < 0x3ff0
        elif line.startswith("expect_halt:"):
            out.append("expect_halt:\n\t%s\n" % line[len("expect_halt:"):].strip())
        elif line.endswith(":"):
            out.append(line + "\n")
        else:
            out.append("\t%s\n" % line)
    if end:
        out.append(END_ARM if arm else "\tEND\n")
    return "".join(out)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def result(out):
    m = re.search(r"^result: halted=(\d) code=(\d+) pc=([0-9a-f]+) fault=([0-9a-f]+) retired=(\d+) last=([0-9a-f]+)",
                  out, re.M)
    if not m:
        return None
    return {"halted": int(m.group(1)), "code": int(m.group(2)), "pc": int(m.group(3), 16),
            "fault": int(m.group(4), 16), "last": int(m.group(6), 16)}


def check(name, code, body, o, env):
    """Returns (ok, line, {check: ok})."""
    work, image, tb, tb_late, ref, lock, here, verif = env
    b = os.path.join(work, name)
    with open(b + ".S", "w") as f:
        f.write(source(code, body, o))
    r = run(["arm-none-eabi-gcc", "-mcpu=arm7tdmi", "-marm", "-nostdlib", "-nostartfiles",
             "-I", os.path.join(here, "directed"), "-Wl,-T," + os.path.join(verif, "isa", "link.ld"),
             "-Wl,--no-warn-rwx-segments", "-o", b + ".elf", b + ".S"])
    if r.returncode == 0:
        r = run(["arm-none-eabi-objcopy", "-O", "binary", "-j", ".vectors", "-j", ".text", b + ".elf", b + ".bin"])
    if r.returncode == 0:
        r = run(["python3", os.path.join(verif, "isa", "bin2hex.py"), b + ".bin", b + ".hex"])
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip().splitlines()
        return False, "FAIL %-24s does not build: %s" % (name, msg[-1] if msg else "?"), {"build": False}
    with open(b + ".dis", "w") as f:
        f.write(run(["arm-none-eabi-objdump", "-d", b + ".elf"]).stdout)
    nm = run(["arm-none-eabi-nm", b + ".elf"]).stdout
    m = re.search(r"^([0-9a-f]+) . expect_halt$", nm, re.M)
    want = int(m.group(1), 16) if m else None
    if code != NONE and want is None:
        return False, "FAIL %-24s no expect_halt label" % name, {"build": False}
    checks = {}
    why = []
    common = ["+romhex=" + b + ".hex", "+rom=" + image, "+maxcyc=200000"]
    if o.get("arm_only"):
        common.append("+arm_only=1")
    for var, binary, extra in (("plain", tb, []), ("late_rf", tb_late, []),
                               ("throttle", tb, ["+throttle=25", "+await=40", "+seed=7"])):
        out = run([binary] + common + extra).stdout
        with open("%s.%s.log" % (b, var), "w") as f:
            f.write(out)
        g = result(out)
        if g is None:
            ok, what = False, "no result"
        elif code == NONE:
            ok = not g["halted"] and g["fault"] == 0xaa
            what = "halted, code %d at %04x" % (g["code"], g["pc"]) if g["halted"] else "fault %02x" % g["fault"]
        else:
            ok = g["halted"] == 1 and g["code"] == code and g["pc"] == want
            if ok and code in (UNDEF, FLAGS):
                ok = g["last"] != want			# halts at once: never retired
            if ok and code in (FETCH, THUMB):
                ok = g["last"] == want			# one clock later: retired first
            what = ("code %d at %04x, last retire %04x" % (g["code"], g["pc"], g["last"]) if g["halted"]
                    else "no halt (fault %02x)" % g["fault"])
        checks[var] = ok
        if not ok:
            why.append("%s: %s" % (var, what))
    note = ""
    refk = o.get("ref")
    if code == NONE and not o.get("arm_only"):
        refk = "natural"
    if refk or code in (DATA, RO, BLOCK):
        out = run([ref, "+rom=" + image, "+romhex=" + b + ".hex", "+maxcyc=200000", "+trace=" + b + ".trace"]).stdout
        with open(b + ".ref.log", "w") as f:
            f.write(out)
        rm = re.search(r"^result: fault=([0-9a-f]+) .* aborts=(\d+) exceptions=(\d+)", out, re.M)
        rfault, raborts, rexc = (int(rm.group(1), 16), int(rm.group(2)), int(rm.group(3))) if rm else (None, None, None)
        exc_pc = None
        with open(b + ".trace") as f:
            for line in f:
                if " EXC" in line:
                    exc_pc = int(line.split()[1], 16)
                    break
        if refk == "exc":
            ok = exc_pc == want and rfault in (0xe1, 0xe2)
            note = "; reference: %s at %s" % ({0xe1: "undefined", 0xe2: "SWI"}.get(rfault, "fault %s" % rfault),
                                             "%04x" % exc_pc if exc_pc is not None else "none")
            checks["ref"] = ok
            if not ok:
                why.append("reference: exception at %s, fault %s" % (exc_pc, rfault))
        elif refk == "natural":
            ok = rfault == 0xaa and rexc == 0 and raborts == 0
            note = "; reference: no exception, end marker reached" if ok else ""
            checks["ref"] = ok
            if not ok:
                why.append("reference: fault %s, %s exceptions, %s aborts" % (rfault, rexc, raborts))
        else:
            # data halts: report, and lockstep with +abort_ok where the reference aborted
            if raborts:
                note = "; reference: data abort"
                lo = run([lock, "+rom=" + image, "+romhex=" + b + ".hex", "+abort_ok=1", "+maxret=100000"]).stdout
                with open(b + ".lock.log", "w") as f:
                    f.write(lo)
                ok = "LOCKSTEP PASS" in lo
                checks["abort_ok"] = ok
                note += ", lockstep +abort_ok %s" % ("PASS" if ok else "FAIL")
                if not ok:
                    why.append("lockstep +abort_ok: " + "; ".join(l for l in lo.splitlines() if l.startswith("MISMATCH"))[:200])
            else:
                note = "; reference: no data abort (fault %s, %s exceptions)" % (
                    "%02x" % rfault if rfault is not None else "none", rexc)
    if code == NONE and not o.get("arm_only"):
        lo = run([lock, "+rom=" + image, "+romhex=" + b + ".hex", "+maxret=100000"]).stdout
        with open(b + ".lock.log", "w") as f:
            f.write(lo)
        ok = "LOCKSTEP PASS" in lo
        checks["lockstep"] = ok
        if not ok:
            why.append("lockstep: " + "; ".join(l for l in lo.splitlines() if l.startswith("MISMATCH"))[:200])
        else:
            note += ", lockstep PASS"
    ok = all(checks.values())
    if code == NONE:
        head = "must not halt"
    else:
        head = "%s (%d) at %04x" % (NAMES[code], code, want)
    line = "%s %-24s %s%s" % ("PASS" if ok else "FAIL", name, head, note)
    if not ok:
        line += "\n    " + "\n    ".join(why)
    return ok, line, checks


def main():
    work, image, tb, tb_late, ref, lock = sys.argv[1:7]
    pick = sys.argv[7:]
    here = os.path.dirname(os.path.abspath(__file__))
    verif = os.path.normpath(os.path.join(here, "..", "..", "verif"))
    os.makedirs(work, exist_ok=True)
    env = (work, image, tb, tb_late, ref, lock, here, verif)
    cases = [c for c in CASES if not pick or any(p in c[0] for p in pick)]
    with ThreadPoolExecutor(max_workers=int(os.environ.get("JOBS", "2"))) as ex:
        res = list(ex.map(lambda c: check(c[0], c[1], c[2], c[3], env), cases))
    totals = {}
    fails = 0
    for (ok, line, checks) in res:
        print(line)
        fails += not ok
        for k, v in checks.items():
            t = totals.setdefault(k, [0, 0])
            t[0] += v
            t[1] += 1
    print("halt tests, per check (passed of run):")
    for k in ("plain", "late_rf", "throttle", "ref", "lockstep", "abort_ok", "build"):
        if k in totals:
            print("  %s: %d of %d" % (k, totals[k][0], totals[k][1]))
    print("halt tests: %d of %d pass" % (len(cases) - fails, len(cases)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
