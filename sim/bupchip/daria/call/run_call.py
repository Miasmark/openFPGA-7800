#!/usr/bin/env python3
"""DARIA's 2600 memory map and call port on the core alone (tb_call.sv).

Each test is a small program, assembled here, with what must happen: every
call's readout (FIQ r8-r13), words of cart RAM, and the halt (code and PC)
or a clean return to parked. docs/DARIA_CORE.md, "The memory system", 4 and
5; bup_cpu.sv's header.

  run_call.py [NAME ...]        (default: every test; also with +await,
                                 +throttle and LATE_RF builds, see VARIANTS)

Environment: WORK (default sim/work/bupchip/daria/call, or call_w<WIN_KB>),
CORE_SV (another bup_cpu.sv), VARIANTS ("plain,await,laterf" by default),
WIN_KB (the core's window, default 128: the beyond-window tests follow it,
and the sources see it as the symbol WIN).
SPDX-License-Identifier: MIT
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../../../.."))
WIN_KB = int(os.environ.get("WIN_KB", "128"))
WIN = WIN_KB * 1024
WORK = os.environ.get("WORK", os.path.join(ROOT, "sim/work/bupchip/daria/call" +
                                           ("" if WIN_KB == 128 else "_w%d" % WIN_KB)))
os.makedirs(WORK, exist_ok=True)

S0, SEED0, FREQ0 = 0x40001F00, 0x1000, 0x2000
SENT = 0xF0000000


def stack(k):
    return S0 - 0x100 * k


def seeds(k):
    return [SEED0 + 0x100 * i + k for i in range(3)] + [FREQ0 + 0x100 * i + k for i in range(3)]


# Word 0 is undefined in both states (ARM: 0xE7F0DE1F; Thumb: 0xDE1F, B<cond>
# 1110): the clock after a jump to the sentinel fetches it (0xF000_0000's
# bits 16:2 are 0), and must not decode it.
HEAD = """	.syntax unified
	.text
	.org 0
	.arm
	.word 0xE7F0DE1F
"""

TESTS = {}


def test(name, src, ro=None, halt=None, ram=None, **kw):
    TESTS[name] = dict(src=HEAD + src, ro=ro, halt=halt, ram=ram or {}, **kw)


# ---- launch: registers at entry, the CPSR, the banks kept between calls -------------
def launch_ram():
    ram = {}
    for k in range(2):
        s = stack(k)
        for a in range(s - 32, s, 4):
            ram[a] = 0                          # push {r0-r7}
        for i, a in enumerate(range(s - 60, s - 40, 4)):
            ram[a] = 0                          # r8-r12
        ram[s - 40] = SENT                      # lr
        ram[s - 36] = s - 32                    # sp after the first push
        b = s - 0x80
        ram[b] = 0x1F                           # CPSR: SYS, ARM after BX, I F clear, NZCV 0
        for i, v in enumerate(seeds(k)):
            ram[b + 4 + 4 * i] = v              # FIQ r8-r13
        ram[b + 28] = 0x11 * k                  # FIQ r14, kept from the call before
        ram[b + 32] = 0x22 * k                  # SVC r13
        ram[b + 36] = 0x33 * k                  # SVC r14
    return ram


test("launch", """
	.org 0x20
	.thumb
	.thumb_func
entry:
	push {r0-r7}
	mov r0, r8
	mov r1, r9
	mov r2, r10
	mov r3, r11
	mov r4, r12
	mov r5, lr
	mov r6, sp
	push {r0-r6}
	ldr r0, =arm_part
	bx r0
	.ltorg
	.align 2
	.arm
arm_part:
	mrs r0, cpsr
	sub r1, sp, #0x44
	str r0, [r1], #4
	msr cpsr_c, #0xD1
	stmia r1!, {r8-r14}
	add r8, r8, #1
	add r9, r9, #2
	add r10, r10, #3
	add r11, r11, #4
	add r12, r12, #5
	add r13, r13, #6
	add r14, r14, #0x11
	msr cpsr_c, #0xD3
	stmia r1!, {r13, r14}
	add r13, r13, #0x22
	add r14, r14, #0x33
	msr cpsr_c, #0x1F
	mov r0, #0xA0
	mov r1, #0xA1
	mov r2, #0xA2
	mov r3, #0xA3
	mov r4, #0xA4
	mov r5, #0xA5
	mov r6, #0xA6
	mov r7, #0xA7
	mov r8, #0xA8
	mov r9, #0xA9
	mov r10, #0xAA
	mov r11, #0xAB
	mov r12, #0xAC
	msr cpsr_f, #0xF0000000
	bx lr
""", calls=2, ro=[[v + d for v, d in zip(seeds(k), range(1, 7))] for k in range(2)],
     ram=launch_ram(), dump_base=0x40001D00, dump=128)

# ---- every way back, and two that must halt ------------------------------------------
same = lambda n: [seeds(k) for k in range(n)]
test("ret_bx_thumb", """
	.org 0x20
	.thumb
	bx lr
""", calls=3, ro=same(3))
test("ret_pop", """
	.org 0x20
	.thumb
	ldr r0, =0xF0000001
	push {r0}
	pop {pc}
	.ltorg
""", calls=2, ro=same(2))
test("ret_mov_pc", """
	.org 0x20
	.thumb
	mov pc, lr
""", calls=2, ro=same(2))
test("ret_add_pc", """
	.org 0x20
	.thumb
	ldr r1, =0xF0000000
	mov r2, pc
	subs r1, r1, r2
	subs r1, #6
	add pc, r1
	.ltorg
""", calls=2, ro=same(2))
test("ret_bx_arm", """
	.org 0x20
	.thumb
	ldr r0, =a
	bx r0
	.ltorg
	.align 2
	.arm
a:	cmp r0, #1
	bxeq lr
	bx lr
""", calls=2, ro=same(2))
test("ret_ldr_pc", """
	.org 0x20
	.thumb
	ldr r0, =a
	bx r0
	.ltorg
	.align 2
	.arm
a:	ldr pc, lit
lit:	.word 0xF0000000
""", calls=2, ro=same(2))
test("ret_arm_entry", """
	.org 0x40
	.arm
	bx lr
""", calls=2, ro=same(2), entry=0x40)
test("bad_ret_f0000002", """
	.org 0x20
	.thumb
	ldr r0, =0xF0000002
fault:	bx r0
	.ltorg
""", halt=(4, "fault"))
test("bad_ret_pop_f0000004", """
	.org 0x20
	.thumb
	ldr r0, =0xF0000004
	push {r0}
fault:	pop {pc}
	.ltorg
""", halt=(4, "fault"))

# ---- the 2600 memory map -----------------------------------------------------------------
test("map_rom_32k", """
	.org 0x20
	.thumb
	ldr r3, =0x40000000
	ldr r1, =0x7FFC
	ldr r0, [r1]
	str r0, [r3]
	ldr r1, =0x8000
fault:	ldr r0, [r1]
	.ltorg
	.org 0x7FFC
	.word 0xCAFEF00D
""", ram={0x40000000: 0xCAFEF00D}, halt=(5, "fault"), dump=4)


def big_pattern(i):
    return (i * 7 + (i >> 8)) & 0xFF


def bw(a, n):
    v = 0
    for j in range(n):
        v |= big_pattern(a + j) << (8 * j)
    return v


test("map_beyond_window", """
	.org 0x20
	.thumb
	ldr r3, =0x40000000
	ldr r1, =WIN
	ldr r0, [r1]
	str r0, [r3]
	ldrh r0, [r1, #6]
	str r0, [r3, #4]
	ldrb r0, [r1, #11]
	str r0, [r3, #8]
	movs r2, #13
	ldrsb r0, [r1, r2]
	str r0, [r3, #12]
	ldr r1, =WIN + 0x7FFC
	ldr r0, [r1]
	str r0, [r3, #16]
	ldr r1, =WIN + 0x8000
fault:	ldr r0, [r1]
	.ltorg
""", img_size=WIN + 0x8000, pattern=True, dump=8,
     ram={0x40000000: bw(WIN, 4), 0x40000004: bw(WIN + 6, 2), 0x40000008: bw(WIN + 0xB, 1),
          0x4000000C: (bw(WIN + 0xD, 1) | (0xFFFFFF00 if bw(WIN + 0xD, 1) & 0x80 else 0)),
          0x40000010: bw(WIN + 0x7FFC, 4)},
     halt=(5, "fault"))
test("map_ldm_beyond", """
	.org 0x20
	.thumb
	ldr r1, =WIN
fault:	ldmia r1!, {r0, r2}
	.ltorg
""", img_size=WIN + 0x8000, pattern=True, halt=(7, "fault"))
test("map_fetch_window", """
	.org 0x20
	.thumb
	ldr r0, =WIN + 1
fault:	bx r0
	.ltorg
""", img_size=WIN + 0x8000, pattern=True, halt=(4, "fault"))
test("map_str_rom", """
	.org 0x20
	.thumb
	ldr r1, =0x100
fault:	str r0, [r1]
	.ltorg
""", halt=(6, "fault"))
test("map_stm_rom", """
	.org 0x20
	.thumb
	ldr r1, =0x100
fault:	stmia r1!, {r0, r2}
	.ltorg
""", halt=(6, "fault"))
test("map_ram_8k", """
	.org 0x20
	.thumb
	ldr r1, =0x40001FFC
	ldr r0, =0x11223344
	str r0, [r1]
	ldr r1, =0x40002000
fault:	str r0, [r1]
	.ltorg
""", ram={0x40001FFC: 0x11223344}, halt=(5, "fault"), dump_base=0x40001FF0, dump=4)
test("map_ram_32k", """
	.org 0x20
	.thumb
	ldr r1, =0x40007FFC
	ldr r0, =0x11223344
	str r0, [r1]
	ldr r1, =0x40008000
fault:	str r0, [r1]
	.ltorg
""", ram32=1, ram={0x40007FFC: 0x11223344}, halt=(5, "fault"), dump_base=0x40007FF0, dump=4)
test("map_mmio", """
	.org 0x20
	.thumb
	ldr r3, =0x40000000
	ldr r1, =0xE01FC000
	ldr r0, =0x12345678
	str r0, [r1]
	movs r0, #0xAB
	strb r0, [r1]
	ldr r0, [r1]
	str r0, [r3]
	ldrb r0, [r1, #1]
	str r0, [r3, #4]
	ldr r1, =0xE0000000
	ldr r0, [r1]
	str r0, [r3, #8]
	ldr r1, =0xE0200000
fault:	ldr r0, [r1]
	.ltorg
""", ram={0x40000000: 0x123456AB, 0x40000004: 0, 0x40000008: 0}, halt=(5, "fault"), dump=4)
test("map_fetch_out", """
	.org 0x20
	.thumb
	ldr r0, =0x8001
fault:	bx r0
	.ltorg
""", halt=(4, "fault"))
test("map_runoff", """
	.org 0x7FF8
	.thumb
	nop
	nop
	nop
fault:	nop
""", entry=0x7FF9, halt=(4, "fault"))
test("map_entry_out", """
	.org 0x20
	.thumb
	bx lr
""", entry=0x9001, halt=(4, 0x9000))
test("map_entry_arm_odd", """
	.org 0x20
	.arm
	bx lr
""", entry=0x22, halt=(4, 0x22))

# ---- the BupChip profile with CODE_AW 15: its code space stays 16 KB (item 18) -----------
test("bup_fetch_out", """
	ldr r0, =0x4000
fault:	bx r0
	.ltorg
""", prof26=0, halt=(4, "fault"), size=0x8000, start_arm=True)
test("bup_data_out", """
	ldr r1, =0x4000
fault:	ldr r2, [r1]
	.ltorg
""", prof26=0, halt=(5, "fault"), size=0x8000, start_arm=True)
test("bup_runoff", """
	b fault
	.org 0x3FFC
fault:	mov r0, r0
""", prof26=0, halt=(4, "fault"), size=0x8000, start_arm=True)
test("bup_sentinel", """
	ldr lr, =0xF0000000
fault:	bx lr
	.ltorg
""", prof26=0, halt=(4, "fault"), size=0x8000, start_arm=True)


def build_image(name, t):
    d = os.path.join(WORK, "img")
    os.makedirs(d, exist_ok=True)
    s, o, e, b = (os.path.join(d, name + x) for x in (".S", ".o", ".elf", ".bin"))
    src = t["src"]
    if t.get("start_arm"):
        src = src.replace("\t.word 0xE7F0DE1F\n", "", 1)   # the BupChip profile runs from 0
    open(s, "w").write(src)
    subprocess.run(["arm-none-eabi-as", "-mcpu=arm7tdmi", "--defsym", "WIN=%d" % WIN, "-o", o, s], check=True)
    subprocess.run(["arm-none-eabi-ld", "-Ttext=0", "-e", "0", "--no-warn-rwx-segments", "-o", e, o], check=True)
    subprocess.run(["arm-none-eabi-objcopy", "-O", "binary", e, b], check=True)
    syms = {}
    for line in subprocess.run(["arm-none-eabi-nm", e], capture_output=True, text=True, check=True).stdout.splitlines():
        p = line.split()
        if len(p) == 3:
            syms[p[2]] = int(p[0], 16) & ~1
    t["syms"] = syms
    img = bytearray(open(b, "rb").read())
    size = t.get("img_size", t.get("size", 0x8000))
    if len(img) > size:
        size = len(img)
    img += bytes(size - len(img))
    if t.get("pattern"):
        for i in range(WIN, size):
            img[i] = big_pattern(i)
    open(b, "wb").write(img)
    return b, size


VARIANTS = {"plain": [], "await": ["+await=40", "+throttle=20", "+rseed=7"], "laterf": []}


def main():
    names = sys.argv[1:] or list(TESTS)
    variants = os.environ.get("VARIANTS", "plain,await,laterf").split(",")
    bins = {}
    for v in variants:
        env = dict(os.environ, WORK=WORK)
        if v == "laterf":
            env["LATE_RF"] = "1"
        r = subprocess.run([os.path.join(HERE, "build_call.sh")], env=env, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr)
            sys.exit(1)
        bins[v] = r.stdout.strip()
    fails = 0
    for name in names:
        t = TESTS[name]
        img, size = build_image(name, t)
        for v in variants:
            args = [bins[v], "+img=" + img, "+img_size=%d" % size, "+calls=%d" % t.get("calls", 1),
                    "+prof26=%d" % t.get("prof26", 1), "+ram32=%d" % t.get("ram32", 0),
                    "+entry=%x" % t.get("entry", 0x21), "+dump=%d" % t.get("dump", 64),
                    "+dump_base=%x" % t.get("dump_base", 0x40000000)] + VARIANTS[v]
            out = subprocess.run(args, capture_output=True, text=True).stdout
            why = check(t, out)
            if why:
                fails += 1
                log = os.path.join(WORK, "%s.%s.log" % (name, v))
                open(log, "w").write(out)
                print("FAIL %-22s %-7s %s (%s)" % (name, v, why, log))
            else:
                print("PASS %-22s %s" % (name, v))
    print("call: %d of %d runs pass" % (len(names) * len(variants) - fails, len(names) * len(variants)))
    sys.exit(1 if fails else 0)


def check(t, out):
    ro = {}
    ram = {}
    res = None
    for line in out.splitlines():
        m = re.match(r"ro: (\d+) (.*)", line)
        if m:
            ro[int(m.group(1))] = [int(x, 16) for x in m.group(2).split()]
        m = re.match(r"ram: (\w+) (\w+)", line)
        if m:
            ram[int(m.group(1), 16)] = int(m.group(2), 16)
        m = re.match(r"result: calls=(\d+) halted=(\d+) code=(\d+) pc=(\w+) parked=(\d+)", line)
        if m:
            res = [int(m.group(i)) for i in (1, 2, 3)] + [int(m.group(4), 16), int(m.group(5))]
    if res is None:
        return "no result line"
    calls, halted, code, pc, parked = res
    if t["halt"]:
        want = (t["halt"][0], t["syms"][t["halt"][1]] if isinstance(t["halt"][1], str) else t["halt"][1])
        if not halted or (code, pc) != want:
            return "halt: got halted=%d code=%d pc=%x, want code=%d pc=%x" % ((halted, code, pc) + want)
    else:
        if halted:
            return "halted with code %d at %x" % (code, pc)
        if t.get("prof26", 1) and not parked:
            return "not parked at the end"
        if calls != t.get("calls", 1):
            return "%d calls completed of %d" % (calls, t.get("calls", 1))
    for k, want in enumerate(t["ro"] or []):
        if ro.get(k) != want:
            return "call %d readout %s, want %s" % (k, [hex(x) for x in ro.get(k, [])], [hex(x) for x in want])
    for a, v in t["ram"].items():
        if ram.get(a) != v:
            return "RAM %08x = %s, want %08x" % (a, "%08x" % ram[a] if a in ram else "not dumped", v)
    return None


if __name__ == "__main__":
    main()
