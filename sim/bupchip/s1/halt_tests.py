#!/usr/bin/env python3
"""Halt tests of the S1 core: one program per case, each of which must stop
the core with the expected halt code at the instruction labelled
expect_halt (docs/BUPCHIP_CORE.md: an encoding is exact or it halts).

  halt_tests.py TB_S1_BINARY WORKDIR IMAGE.a78

TB_S1_BINARY is build_s1.sh's tb_s1, run in program mode (+romhex).
IMAGE.a78 must hold 1 KiB of assets (run_directed.sh makes it), so that
0x02000400 is the first byte past the asset window. Each program is the
directed tests' start-up (directed/common.inc), a few set-up instructions,
the case, and the end marker, which a core that does not halt reaches.
Exit status 1 if any case fails.
"""
import os
import re
import subprocess
import sys

UNDEF, REG, THUMB, FETCH, DATA, RO, BLOCK = 1, 2, 3, 4, 5, 6, 7

# name, expected code, body ("expect_halt:" marks the instruction responsible)
CASES = [
    ("swi", UNDEF, "expect_halt: swi 0"),
    ("swp", UNDEF, "expect_halt: swp r0, r1, [r12]"),
    ("coprocessor", UNDEF, "expect_halt: mrc p15, 0, r0, c0, c0, 0"),
    ("undefined", UNDEF, "expect_halt: .word 0xe6000010"),
    ("ldrd", UNDEF, "expect_halt: .word 0xe1cc00d0"),
    ("mrs_spsr", UNDEF, "expect_halt: mrs r0, spsr"),
    ("msr_spsr", UNDEF, "expect_halt: msr spsr_f, r0"),
    ("msr_x", UNDEF, "expect_halt: msr cpsr_x, r0"),
    ("msr_mode", UNDEF, "expect_halt: msr cpsr_c, #0x10"),
    ("msr_thumb_bit", UNDEF, "mov r0, #0xf3\nexpect_halt: msr cpsr_c, r0"),
    ("msr_reserved", UNDEF, "expect_halt: msr cpsr_f, #0x0f000000"),
    ("muls", UNDEF, "expect_halt: muls r0, r1, r2"),
    ("smull", UNDEF, "expect_halt: smull r0, r1, r2, r3"),
    ("umlal", UNDEF, "expect_halt: umlal r0, r1, r2, r3"),
    ("ldm_pc", UNDEF, "expect_halt: ldmia r12, {r0, pc}"),
    ("ldm_user", UNDEF, "expect_halt: ldmia r12, {r0}^"),
    ("ldm_empty", UNDEF, "expect_halt: .word 0xe89c0000"),
    ("mov_pc", REG, "expect_halt: mov pc, lr"),
    ("cmp_p", REG, "expect_halt: .word 0xe15ff000"),
    ("regshift_pc", REG, "mov r2, #1\nexpect_halt: add r0, pc, r1, lsl r2"),
    ("regshift_rs_pc", REG, "expect_halt: .word 0xe1a00f11"),
    ("str_pc", REG, "expect_halt: str pc, [r12]"),
    ("ldr_wb_pc", REG, "expect_halt: .word 0xe5bf0004"),
    ("ldrb_pc", REG, "expect_halt: .word 0xe5dcf000"),
    ("ldrh_pc", REG, "expect_halt: .word 0xe1dcf0b0"),
    ("regoff_pc", REG, "expect_halt: .word 0xe79c000f"),
    ("bx_pc", REG, "expect_halt: bx pc"),
    ("mul_pc", REG, "expect_halt: .word 0xe00f0291"),
    ("umull_same", REG, "expect_halt: .word 0xe0800291"),
    ("ldm_base_pc", REG, "expect_halt: .word 0xe89f0001"),
    ("mrs_pc", REG, "expect_halt: .word 0xe10ff000"),
    ("bx_thumb", THUMB, "ldr r1, =0x101\nexpect_halt: bx r1"),
    ("b_out", FETCH, "expect_halt: b 0x4000"),
    ("bl_out", FETCH, "expect_halt: bl 0x4000"),
    ("bx_out", FETCH, "ldr r1, =0x40000000\nexpect_halt: bx r1"),
    ("bx_unaligned", FETCH, "ldr r1, =0x102\nexpect_halt: bx r1"),
    ("ldr_pc_out", FETCH, "expect_halt: ldr pc, =0x40000404"),
    ("ldr_pc_unaligned", FETCH, "expect_halt: ldr pc, =0x102"),
    ("load_nowhere", DATA, "ldr r1, =0x10000000\nexpect_halt: ldr r0, [r1]"),
    ("load_past_rom", DATA, "mov r1, #0x4000\nexpect_halt: ldr r0, [r1]"),
    ("load_past_ram", DATA, "ldr r1, =0x40004000\nexpect_halt: ldrh r0, [r1]"),
    ("load_past_assets", DATA, "ldr r1, =0x02000400\nexpect_halt: ldrb r0, [r1]"),
    ("load_past_mmio", DATA, "ldr r1, =0xe0009100\nexpect_halt: ldr r0, [r1]"),
    ("wild_store", DATA, "ldr r1, =0x40004000\nexpect_halt: str r0, [r1]\nmov r0, r0"),
    ("store_nowhere", DATA, "ldr r1, =0x80000000\nexpect_halt: strb r0, [r1]"),
    ("store_rom", RO, "mov r1, #0x100\nexpect_halt: str r0, [r1]"),
    ("store_assets", RO, "ldr r1, =0x02000000\nexpect_halt: strb r0, [r1]"),
    ("stm_rom", RO, "mov r1, #0x100\nexpect_halt: stmia r1, {r0, r2}"),
    ("ldm_mmio", BLOCK, "ldr r1, =0xe0009000\nexpect_halt: ldmia r1, {r0}"),
    ("ldm_assets", BLOCK, "ldr r1, =0x02000000\nexpect_halt: ldmia r1, {r0, r2}"),
    ("stm_past_ram", BLOCK, "ldr r1, =0x40003ffc\nexpect_halt: stmia r1, {r0, r2}"),
]

tb, work, image = sys.argv[1:4]
here = os.path.dirname(os.path.abspath(__file__))
verif = os.path.join(here, "..", "verif")
os.makedirs(work, exist_ok=True)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


fails = 0
for name, code, body in CASES:
    b = os.path.join(work, name)
    with open(b + ".S", "w") as f:
        f.write('#include "common.inc"\n\tSTART\n\tmov r0, #0x5a\n')
        for line in body.split("\n"):
            label, _, ins = line.rpartition(":") if line.startswith("expect_halt:") else ("", "", line)
            f.write(("expect_halt:\n" if label else "") + "\t" + ins.strip() + "\n")
        f.write("\tEND\n")
    r = run(["arm-none-eabi-gcc", "-mcpu=arm7tdmi", "-marm", "-nostdlib", "-nostartfiles",
             "-I", os.path.join(here, "directed"), "-Wl,-T," + os.path.join(verif, "isa", "link.ld"),
             "-Wl,--no-warn-rwx-segments", "-o", b + ".elf", b + ".S"])
    if r.returncode == 0:
        r = run(["arm-none-eabi-objcopy", "-O", "binary", "-j", ".vectors", "-j", ".text", b + ".elf", b + ".bin"])
    if r.returncode == 0:
        r = run(["python3", os.path.join(verif, "isa", "bin2hex.py"), b + ".bin", b + ".hex"])
    if r.returncode != 0:
        print("FAIL %-18s does not build: %s" % (name, (r.stderr or r.stdout).strip().splitlines()[-1]))
        fails += 1
        continue
    nm = run(["arm-none-eabi-nm", b + ".elf"]).stdout
    want_pc = int(re.search(r"^([0-9a-f]+) . expect_halt$", nm, re.M).group(1), 16)
    out = run([tb, "+romhex=" + b + ".hex", "+rom=" + image, "+maxcyc=200000"]).stdout
    open(b + ".log", "w").write(out)
    m = re.search(r"^result: halted=(\d) code=(\d+) pc=([0-9a-f]+)", out, re.M)
    got = (int(m.group(1)), int(m.group(2)), int(m.group(3), 16)) if m else None
    ok = got == (1, code, want_pc)
    fails += not ok
    print("%s %-18s want code %d at %04x, got %s" % ("PASS" if ok else "FAIL", name, code, want_pc,
          "code %d at %04x" % (got[1], got[2]) if got and got[0] else "no halt"))
print("halt tests: %d of %d pass" % (len(CASES) - fails, len(CASES)))
sys.exit(1 if fails else 0)
