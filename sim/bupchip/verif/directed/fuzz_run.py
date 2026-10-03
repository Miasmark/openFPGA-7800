#!/usr/bin/env python3
"""Run one fuzz.py program against the new core and the reference.

  fuzz_run.py TB_S1 LOCKSTEP WORKDIR IMAGE.a78 SEED [CELLS]

1. fuzz.py SEED CELLS is assembled (link.ld) into WORKDIR/fuzzSEED.hex.
2. The program runs on the new core (TB_S1, s1/build_s1.sh's binary, in
   program mode). Where it halts, the encoding there (a cell's fz<k>) is
   replaced with a NOP and the run repeats, until the end marker. A halt
   anywhere but a cell's encoding is a failure. A DATA or RO halt claims
   that the reference aborts there, so before the NOP goes in, the program
   runs in lockstep with +abort_ok=1: the reference must take a data abort
   in the same instruction, after the same retires.
3. The patched program runs in lockstep (LOCKSTEP, run_lockstep.sh --build
   with DUT=bup), plainly and with +await=40 +throttle=25: everything the
   core did not halt on must match the reference, and the reference must
   not abort or take an exception where the core did not halt.
Prints one PASS or FAIL line, plus the halts by code with an example each.
"""
import collections
import os
import re
import subprocess
import sys

tb, lock, work, image, seed = sys.argv[1:6]
cells = int(sys.argv[6]) if len(sys.argv) > 6 else 450
here = os.path.dirname(os.path.abspath(__file__))
verif = os.path.join(here, "..")
os.makedirs(work, exist_ok=True)
b = os.path.join(work, f"fuzz{seed}")
NOP = 0xE1A00000
NAMES = {1: "UNDEF", 2: "REG", 3: "THUMB", 4: "FETCH", 5: "DATA", 6: "RO", 7: "BLOCK"}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def fail(why):
    print(f"FAIL fuzz seed {seed}: {why}")
    sys.exit(1)


with open(b + ".S", "w") as f:
    r = run(["python3", os.path.join(here, "fuzz.py"), seed, str(cells)])
    if r.returncode:
        fail("fuzz.py: " + r.stderr.strip())
    f.write(r.stdout)
for cmd in (["arm-none-eabi-gcc", "-mcpu=arm7tdmi", "-marm", "-nostdlib", "-nostartfiles",
             "-Wl,-T," + os.path.join(verif, "isa", "link.ld"), "-Wl,--no-warn-rwx-segments",
             "-o", b + ".elf", b + ".S"],
            ["arm-none-eabi-objcopy", "-O", "binary", "-j", ".text", b + ".elf", b + ".bin"],
            ["python3", os.path.join(verif, "isa", "bin2hex.py"), b + ".bin", b + ".hex"]):
    r = run(cmd)
    if r.returncode:
        fail("does not build: " + (r.stderr or r.stdout).strip().splitlines()[-1])
labels = {}
for line in run(["arm-none-eabi-nm", b + ".elf"]).stdout.splitlines():
    m = re.match(r"([0-9a-f]+) . fz(\d+)$", line)
    if m:
        labels[int(m.group(1), 16)] = int(m.group(2))
rom = [int(x, 16) for x in open(b + ".hex").read().split()]

halts = collections.defaultdict(list)
for it in range(cells + 2):
    open(b + ".patched.hex", "w").write("".join(f"{w:08x}\n" for w in rom))
    out = run([tb, "+romhex=" + b + ".patched.hex", "+rom=" + image, "+maxcyc=2000000"]).stdout
    m = re.search(r"^result: halted=(\d) code=(\d+) pc=([0-9a-f]+) fault=([0-9a-f]+)", out, re.M)
    if not m:
        fail("tb_s1 gave no result line")
    halted, code, pc, fault = int(m.group(1)), int(m.group(2)), int(m.group(3), 16), m.group(4)
    if not halted:
        if fault != "aa":
            fail(f"the core neither halted nor reached the end marker (fault {fault})")
        break
    if pc not in labels:
        fail(f"halt code {code} at {pc:08x}, which is not a fuzzed encoding")
    if code in (5, 6):
        out = run([lock, "+rom=" + image, "+romhex=" + b + ".patched.hex", "+maxret=10000000",
                   "+abort_ok=1", "+stall=200000"]).stdout
        open(b + ".abort.log", "w").write(out)
        if not ("LOCKSTEP PASS" in out and re.search(r"^stop: reference abort, DUT halted", out, re.M)
                and re.search(r"^reference data abort at", out, re.M)
                and re.search(rf"^DUT halted \({pc:08x}\)", out, re.M)):
            first = [l for l in out.splitlines() if l.startswith(("MISMATCH", "stop", "reference data abort"))][:3]
            fail(f"{NAMES[code]} halt at fz{labels[pc]} ({rom[pc // 4]:08x}), but the reference does not abort "
                 f"there ({b}.abort.log): " + " | ".join(first))
    halts[code].append((labels[pc], rom[pc // 4]))
    rom[pc // 4] = NOP
open(b + ".patched.hex", "w").write("".join(f"{w:08x}\n" for w in rom))

nret = ""
for extra in ([], ["+await=40", "+throttle=25", "+seed=" + seed]):
    log = b + (".lock2.log" if extra else ".lock.log")
    out = run([lock, "+rom=" + image, "+romhex=" + b + ".patched.hex", "+maxret=10000000"] + extra).stdout
    open(log, "w").write(out)
    if "LOCKSTEP PASS" not in out:
        first = [l for l in out.splitlines() if l.startswith("MISMATCH") or "halted" in l][:3]
        fail(f"lockstep{' with waits and throttle' if extra else ''} failed ({log}): " + " | ".join(first))
    if not extra:
        m = re.search(r"^compared: (\d+) retires, (\d+) RAM stores", out, re.M)
        nret = f"{m.group(1)} retires, {m.group(2)} stores" if m else ""
nh = sum(len(v) for v in halts.values())
print(f"PASS fuzz seed {seed}: {cells} cells, {cells - nh} ran in lockstep ({nret}), {nh} halted: " +
      ", ".join(f"{NAMES.get(c, c)} {len(v)}" for c, v in sorted(halts.items())))
for c, v in sorted(halts.items()):
    k, w = v[0]
    print(f"    {NAMES.get(c, c):5} e.g. fz{k} {w:08x}")
