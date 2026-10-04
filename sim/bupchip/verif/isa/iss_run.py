#!/usr/bin/env python3
"""Golden model for the ISA tests: run a test binary on Unicorn and dump its
signature.

  iss_run.py TEST.bin SIG.out [NSIG] [--trace TRACE.out]

Unicorn (QEMU's ARM) runs as an ARM926 (ARMv5TE, the nearest model to the
ARM7TDMI's ARMv4T it has) with the BupChip memory map: ROM at 0, RAM at
0x40000000, the peripheral page at 0xE0009000 (IDENT reads 0x42555001). The
run stops at the write to the FAULT register (0xE000901C); then NSIG words
(default 2048) from 0x40000000 go to SIG.out, one hex word per line, the
format tb_ref_trace.sv's +sig dump uses. --trace writes "<n> <pc> <insn>" per
executed instruction, the first three fields of tb_ref_trace.sv's trace, for
a first-divergence diff.

Tests must stay inside the subset where ARMv4T and ARMv5TE agree: no
unaligned LDR/LDRH, no flag-setting multiplies, no interworking through
LDR PC. Needs the unicorn package (sim/bupchip/setup_dev.sh puts it in a
virtualenv).
"""
import struct
import sys

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_MEM_WRITE, UC_HOOK_CODE
from unicorn.arm_const import UC_CPU_ARM_926, UC_ARM_REG_CPSR

binf, sigf = sys.argv[1], sys.argv[2]
nsig = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 2048
tracef = sys.argv[sys.argv.index("--trace") + 1] if "--trace" in sys.argv else None

uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
uc.ctl_set_cpu_model(UC_CPU_ARM_926)
uc.mem_map(0x00000000, 0x4000)                 # firmware ROM
uc.mem_map(0x40000000, 0x4000)                 # RAM
uc.mem_map(0xE0009000, 0x1000)                 # peripheral (page granular)
uc.mem_write(0, open(binf, "rb").read())
uc.mem_write(0xE0009000, struct.pack("<I", 0x42555001))   # IDENT
uc.reg_write(UC_ARM_REG_CPSR, 0xd3)            # the reference core's reset CPSR

done = {"code": None}


def on_write(uc, access, addr, size, value, _):
    if addr == 0xE000901C:
        done["code"] = value & 0xff
        uc.emu_stop()


uc.hook_add(UC_HOOK_MEM_WRITE, on_write, begin=0xE0009000, end=0xE00090FF)

n = [0]
tfd = open(tracef, "w") if tracef else None


def on_code(uc, addr, size, _):
    n[0] += 1
    if tfd:
        insn = struct.unpack("<I", uc.mem_read(addr, 4))[0]
        tfd.write(f"{n[0]} {addr:08x} {insn:08x}\n")
    if n[0] > 10_000_000:
        uc.emu_stop()


uc.hook_add(UC_HOOK_CODE, on_code)
uc.emu_start(0, 0x4000)
sig = uc.mem_read(0x40000000, 4 * nsig)
open(sigf, "w").write("".join(f"{struct.unpack_from('<I', sig, 4 * i)[0]:08x}\n" for i in range(nsig)))
end = "none" if done["code"] is None else f"{done['code']:02x}"
print(f"ISS: {n[0]} instructions, end code {end}")
