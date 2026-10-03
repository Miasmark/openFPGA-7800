#!/usr/bin/env python3
"""Check Unicorn against the reference RTL on the real firmware.

  iss_fw_replay.py GAME.a78 REF.trace [MAX] [--romhex FILE]

Runs the CoreTone firmware (default src/fpga/mister/rtl/bupchip.hex) on
Unicorn as an ARM926, with the ARSC block of GAME.a78 in the asset window,
against a retire trace of the same run written by tb_ref_trace.sv (+trace).
Every peripheral read (the trace's M events) is answered with the value the
reference saw, in order, so the poll loops iterate exactly as they did on the
RTL. Then, instruction by instruction, it compares the PC, the encoding, all
15 registers (rebuilt from the trace's changes, starting from zero like the
reference) and NZCV, and stops at the first divergence or after MAX
instructions. This is the lockstep check with the independent model standing
in for the new core. Needs the unicorn package (setup_dev.sh).
"""
import struct
import sys

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm_const import UC_CPU_ARM_926, UC_ARM_REG_R0, UC_ARM_REG_R13, UC_ARM_REG_R14, UC_ARM_REG_CPSR

args = [a for a in sys.argv[1:]]
romhex = None
if "--romhex" in args:
    i = args.index("--romhex")
    romhex = args[i + 1]
    del args[i:i + 2]
game, tracef = args[0], args[1]
limit = int(args[2]) if len(args) > 2 else 1 << 62
if romhex is None:
    import os
    romhex = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../src/fpga/mister/rtl/bupchip.hex")
fw = b"".join(struct.pack("<I", int(l, 16)) for l in open(romhex) if l.strip())
img = open(game, "rb").read()
arsc = img[128 + int.from_bytes(img[49:53], "big"):]

# Reference records: (pc, insn, {reg: value}, flags or None); MMIO reads in order.
ref, mm = [], []
for line in open(tracef):
    if len(ref) >= limit:
        break
    body = line.split("#")[0].split()
    regs, flags = {}, None
    for t in body[3:]:
        if t.startswith("r"):
            k, v = t[1:].split("=")
            regs[int(k)] = int(v, 16)
        elif t.startswith("f="):
            flags = int(t[2:], 16)
        elif t.startswith("M"):
            a, v = t[1:].split("=")
            mm.append((int(a, 16), int(v, 16)))
    ref.append((int(body[1], 16), int(body[2], 16), regs, flags))

uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
uc.ctl_set_cpu_model(UC_CPU_ARM_926)
uc.mem_map(0, 0x4000)
uc.mem_write(0, fw[:0x4000])
uc.mem_map(0x40000000, 0x4000)
if arsc:
    uc.mem_map(0x02000000, (len(arsc) + 0xfff) & ~0xfff)
    uc.mem_write(0x02000000, arsc)

st = {"mi": 0, "pcm": 0, "fault": None}


def mmio_read(uc, off, size, _):
    a = 0xE0009000 + off
    if st["mi"] >= len(mm):
        uc.emu_stop()
        return 0
    ra, v = mm[st["mi"]]
    st["mi"] += 1
    if ra != a:
        bad[0] = f"peripheral read #{st['mi']}: Unicorn {a:#x}, reference {ra:#x}"
        uc.emu_stop()
    return v


def mmio_write(uc, off, size, value, _):
    if off == 0x10:
        st["pcm"] += 1
    if off == 0x1c:
        st["fault"] = value


uc.mmio_map(0xE0009000, 0x1000, mmio_read, None, mmio_write, None)

REG = [UC_ARM_REG_R0 + i for i in range(13)] + [UC_ARM_REG_R13, UC_ARM_REG_R14]
n, bad = [0], [None]
shadow, sflags = [0] * 15, [0]          # the reference's state, rebuilt from the diffs


def check_prev(uc):
    """The registers now hold the state after ref[n-1]: compare all 15 and NZCV."""
    i = n[0] - 1
    if i < 0:
        return
    _, _, regs, flags = ref[i]
    for k, v in regs.items():
        shadow[k] = v
    if flags is not None:
        sflags[0] = flags
    for k in range(15):
        got = uc.reg_read(REG[k])
        if got != shadow[k]:
            bad[0] = f"#{i + 1} pc {ref[i][0]:08x}: r{k} Unicorn {got:08x} reference {shadow[k]:08x}"
            return
    f = uc.reg_read(UC_ARM_REG_CPSR) >> 28
    if f != sflags[0]:
        bad[0] = f"#{i + 1} pc {ref[i][0]:08x}: NZCV Unicorn {f:x} reference {sflags[0]:x}"


def on_code(uc, addr, size, _):
    if bad[0] is None:
        check_prev(uc)
    if bad[0] is None and n[0] < len(ref):
        pc, insn = ref[n[0]][0], ref[n[0]][1]
        got = struct.unpack("<I", uc.mem_read(addr, 4))[0]
        if addr != pc or got != insn:
            bad[0] = f"#{n[0] + 1}: Unicorn pc {addr:08x} {got:08x}, reference {pc:08x} {insn:08x}"
    if bad[0] is not None or n[0] >= len(ref):
        uc.emu_stop()
        return
    n[0] += 1


uc.hook_add(UC_HOOK_CODE, on_code)
uc.reg_write(UC_ARM_REG_CPSR, 0xd3)    # the reference core's reset CPSR; QEMU's sets Z and A
uc.emu_start(0, 0x4000)
print(f"replay: {n[0]} of {len(ref)} reference instructions checked, {st['mi']} of {len(mm)} "
      f"peripheral reads replayed, {st['pcm']} PCM pushes, fault {st['fault']}")
if bad[0]:
    print("FIRST DIVERGENCE: " + bad[0])
    sys.exit(1)
print("MATCH: PC, encoding, r0-r14 and NZCV agree at every retire")
