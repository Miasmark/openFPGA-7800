#!/usr/bin/env python3
"""More halt cases for the BupChip CPU, and edge cases that must not halt,
on the S1 testbench (../../s1/tb_s1.sv in program mode).

  vhalt.py TB_S1_BINARY WORKDIR IMAGE.a78

Beyond ../../s1/halt_tests.py: the ARMv5 and coprocessor encodings an
ARM7TDMI does not have, r15 in the remaining operand positions, the PSR
forms the core does not implement, multiplies with S or signed, block
transfers with PC, S or an empty list, branches below address 0, loads and
stores just past the end of each window. Then the "go" cases, which must run
to the end marker: the last byte or word of each window (an unaligned word
load whose first byte is the last ROM or asset byte included), LDM from the
ROM, MSR forms that write only what the core has, and condition-failed forms
of halting encodings. IMAGE.a78 must hold 1 KiB of assets (run.sh makes it).
Exit status 1 if any case fails. With THUMB=1 (or MODES=1) in the
environment the binary is DARIA's core, whose MODES 1 accepts SYS mode and
the I and F bits: those two MSR cases then must run on instead of halting.
SPDX-License-Identifier: MIT
"""
import os
import re
import subprocess
import sys

UNDEF, REG, THUMB, FETCH, DATA, RO, BLOCK = 1, 2, 3, 4, 5, 6, 7
GO = 0
# MODES 1 (DARIA's core, also in the BupChip profile) takes MSR to SYS mode
# and with I or F clear; MODES 0 halts on both.
MODES1 = os.environ.get("THUMB", "0") != "0" or os.environ.get("MODES", "0") != "0"

# (name, expected code or GO, set-up lines, the instruction under test)
CASES = [
    ("strh_pc", REG, [], ".word 0xe1ccf0b0"),             # strh pc, [r12]
    ("msr_from_pc", REG, [], ".word 0xe129f00f"),          # msr cpsr_fc, pc
    ("umull_lo_pc", REG, [], ".word 0xe081f392"),          # umull pc, r1, r2, r3
    ("umull_rm_pc", REG, [], ".word 0xe081039f"),          # umull r0, r1, pc, r3
    ("mla_acc_pc", REG, [], ".word 0xe020f291"),           # mla r0, r1, r2, pc
    ("movs_pc_lr", REG, [], "movs pc, lr"),
    ("ldrsb_pc", REG, [], ".word 0xe1dcf0d0"),             # ldrsb pc, [r12]
    ("str_regoff_rm_pc", REG, [], ".word 0xe78c000f"),     # str r0, [r12, pc]
    ("ldrh_regoff_rm_pc", REG, [], ".word 0xe19c00bf"),    # ldrh r0, [r12, pc]
    ("ldr_post_pc_base", REG, [], ".word 0xe49f0004"),     # ldr r0, [pc], #4
    ("cdp", UNDEF, [], "cdp p1, 0, c0, c0, c0, 0"),
    ("ldc", UNDEF, [], "ldc p1, c0, [r12]"),
    ("mcr", UNDEF, [], "mcr p15, 0, r0, c1, c0, 0"),
    ("swpb", UNDEF, [], "swpb r0, r1, [r12]"),
    ("blx_reg", UNDEF, [], ".word 0xe12fff31"),
    ("clz", UNDEF, [], ".word 0xe16f0f11"),
    ("bkpt", UNDEF, [], ".word 0xe1200070"),
    ("qadd", UNDEF, [], ".word 0xe1010052"),
    ("smlabb", UNDEF, [], ".word 0xe1000281"),
    ("strd", UNDEF, [], ".word 0xe1cc00f0"),
    ("mrs_sbz", UNDEF, [], ".word 0xe10f0001"),
    ("msr_s_field", UNDEF, [], ".word 0xe124f000"),        # msr cpsr_s, r0
    ("msr_fs", UNDEF, [], ".word 0xe12cf000"),             # msr cpsr_fs, r0
    ("msr_sys_mode", GO if MODES1 else UNDEF, ["mov r0, #0xdf"], "msr cpsr_c, r0"),
    ("msr_irq_enable", GO if MODES1 else UNDEF, ["mov r0, #0x53"], "msr cpsr_c, r0"),
    ("msr_fc_reserved", UNDEF, ["ldr r0, =0x010000d3"], "msr cpsr_fc, r0"),
    ("umulls", UNDEF, [], ".word 0xe0910392"),
    ("smlal", UNDEF, [], ".word 0xe0e10392"),
    ("mlas", UNDEF, [], "mlas r0, r1, r2, r3"),
    ("stm_user", UNDEF, [], "stmia r12, {r0}^"),
    ("stm_empty", UNDEF, [], ".word 0xe88c0000"),
    ("stm_pc", UNDEF, [], "stmia r12, {r0, pc}"),
    ("ldr_pc_bit0", FETCH, ["ldr r1, =0x101", "str r1, [r12, #0x40]"], "ldr pc, [r12, #0x40]"),
    ("b_below_zero", FETCH, [], ".word 0xeaffff00"),
    ("bx_thumb_and_bit1", THUMB, ["ldr r1, =0x103"], "bx r1"),
    ("bx_past_rom", FETCH, ["mov r1, #0x4000"], "bx r1"),
    ("ldrh_past_assets", DATA, ["ldr r1, =0x02000400"], "ldrh r0, [r1]"),
    ("ldr_asset_past_16m", DATA, ["ldr r1, =0x03000000"], "ldr r0, [r1]"),
    ("ldr_below_ram", DATA, ["ldr r1, =0x3ffffffc"], "ldr r0, [r1]"),
    ("ldr_near_mmio", DATA, ["ldr r1, =0xe0008ffc"], "ldr r0, [r1]"),
    ("str_past_mmio", DATA, ["ldr r1, =0xe0009100"], "str r0, [r1]"),
    ("str_rom_regoff", RO, ["mov r2, #0x100"], "str r0, [r2, r2]"),
    ("strh_rom", RO, ["mov r2, #0x100"], "strh r0, [r2]"),
    ("strb_asset_regoff", RO, ["ldr r1, =0x02000000", "mov r2, #1"], "strb r0, [r1, r2]"),
    ("stmdb_below_ram", BLOCK, ["ldr r1, =0x40000004"], "stmdb r1, {r0, r2, r3}"),
    ("ldm_past_rom", BLOCK, ["ldr r1, =0x3ffc"], "ldmia r1, {r0, r2}"),
    ("ldm_ram_wrap", BLOCK, ["ldr r1, =0x40003ff8"], "ldmia r1, {r0, r2, r3}"),
    # go: these must run on to the end marker
    ("go_ldr_rom_last_word", GO, ["ldr r1, =0x3ffc"], "ldr r0, [r1]"),
    ("go_ldr_rom_unaligned_end", GO, ["ldr r1, =0x3fff"], "ldr r0, [r1]"),
    ("go_ldm_rom", GO, ["mov r1, #0x100"], "ldmia r1, {r0, r2, r3}"),
    ("go_asset_last_byte", GO, ["ldr r1, =0x020003ff"], "ldrsb r0, [r1]"),
    ("go_asset_last_halfword_odd", GO, ["ldr r1, =0x020003ff"], "ldrh r0, [r1]"),
    ("go_asset_word_straddles_end", GO, ["ldr r1, =0x020003fe"], "ldr r0, [r1]"),
    ("go_ram_last_byte", GO, ["ldr r1, =0x40003fff", "ldrb r0, [r1]"], "strb r0, [r1]"),
    ("go_ram_stm_last_words", GO, ["ldr r1, =0x40003ff8"], "stmia r1, {r0, r2}"),
    ("go_mmio_last_byte", GO, ["ldr r1, =0xe00090ff"], "ldrb r0, [r1]"),
    ("go_mmio_last_word_store", GO, ["ldr r1, =0xe00090fc"], "str r0, [r1]"),
    ("go_msr_fc_d3", GO, ["ldr r0, =0xf00000d3"], "msr cpsr_fc, r0"),
    ("go_msr_f_low_garbage", GO, ["ldr r0, =0xa00000ff"], "msr cpsr_f, r0"),
    ("go_msr_c_high_garbage", GO, ["ldr r0, =0x0f0000d3"], "msr cpsr_c, r0"),
    ("go_condfail_umull_same", GO, ["movs r0, #0"], ".word 0x10800291"),   # umullne r0, r0, ...
    ("go_condfail_stm_pc", GO, ["movs r0, #0"], "stmiane r12, {r0, pc}"),
    ("go_condfail_msr_mode", GO, ["movs r0, #0"], "msrne cpsr_c, #0x10"),
    ("go_condfail_b_below_zero", GO, ["movs r0, #0"], ".word 0x1affff00"),
    ("go_condfail_ldr_pc_bit0", GO, ["ldr r1, =0x101", "str r1, [r12, #0x40]", "movs r0, #0"],
     "ldrne pc, [r12, #0x40]"),
    ("go_condfail_wild_store", GO, ["ldr r1, =0x40004000", "movs r0, #0"], "strne r0, [r1]"),
    ("go_condfail_clz", GO, ["movs r0, #0"], ".word 0x116f0f11"),
]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    tb, work, image = sys.argv[1:4]
    here = os.path.dirname(os.path.abspath(__file__))
    common = os.path.normpath(os.path.join(here, "..", "..", "s1", "directed"))
    link = os.path.normpath(os.path.join(here, "..", "isa", "link.ld"))
    bin2hex = os.path.normpath(os.path.join(here, "..", "isa", "bin2hex.py"))
    os.makedirs(work, exist_ok=True)
    fails = 0
    for name, code, setup, ins in CASES:
        b = os.path.join(work, name)
        body = "".join("\t%s\n" % s for s in setup)
        body += "expect_halt:\n\t%s\n" % ins
        open(b + ".S", "w").write('#include "common.inc"\n\tSTART\n\tmov\tr0, #0x5a\n%s\tEND\n' % body)
        r = run(["arm-none-eabi-gcc", "-mcpu=arm7tdmi", "-marm", "-nostdlib", "-nostartfiles",
                 "-I", common, "-Wl,-T," + link, "-Wl,--no-warn-rwx-segments", "-o", b + ".elf", b + ".S"])
        if r.returncode == 0:
            r = run(["arm-none-eabi-objcopy", "-O", "binary", "-j", ".text", b + ".elf", b + ".bin"])
        if r.returncode == 0:
            r = run(["python3", bin2hex, b + ".bin", b + ".hex"])
        if r.returncode != 0:
            print("FAIL %-28s does not build: %s" % (name, (r.stderr or r.stdout).strip().splitlines()[-1]))
            fails += 1
            continue
        nm = run(["arm-none-eabi-nm", b + ".elf"]).stdout
        at = int(re.search(r"^([0-9a-f]+) . expect_halt$", nm, re.M).group(1), 16)
        out = run([tb, "+romhex=" + b + ".hex", "+rom=" + image, "+maxcyc=200000"]).stdout
        open(b + ".log", "w").write(out)
        m = re.search(r"^result: halted=(\d) code=(\d+) pc=([0-9a-f]+) fault=([0-9a-f]+)", out, re.M)
        if not m:
            got, ok = "no result line", False
        elif code == GO:
            ok = m.group(1) == "0" and m.group(4) == "aa"
            got = "end marker" if ok else "halted=%s code %s at %04x" % (m.group(1), m.group(2), int(m.group(3), 16))
        else:
            ok = (m.group(1), int(m.group(2)), int(m.group(3), 16)) == ("1", code, at)
            got = "code %s at %04x" % (m.group(2), int(m.group(3), 16)) if m.group(1) == "1" else "no halt"
        fails += not ok
        want = "the end marker" if code == GO else "code %d at %04x" % (code, at)
        print("%s %-28s want %s, got %s" % ("PASS" if ok else "FAIL", name, want, got))
    print("vhalt: %d of %d pass" % (len(CASES) - fails, len(CASES)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
