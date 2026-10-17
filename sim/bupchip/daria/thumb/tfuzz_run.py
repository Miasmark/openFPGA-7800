#!/usr/bin/env python3
"""Run one tfuzz.py program on DARIA's core in lockstep with the reference.

  tfuzz_run.py LOCKSTEP WORKDIR IMAGE.a78 SEED [CELLS] [+plusarg ...]

LOCKSTEP is ../../verif/run_lockstep.sh --build's binary with THUMB=1
DUT=bup; IMAGE.a78 is an image without assets (make_synth_arsc.py --none).
Extra plusargs (+await=20 +throttle=10, say) go to every run, with
+seed=SEED added.

1. tfuzz.py SEED CELLS is assembled (../../verif/isa/link.ld) into
   WORKDIR/tfuzzSEED.hex; its cell list, with the halt each cell must take,
   goes to tfuzzSEED.json. The program must stay below 0x3C00, so that every
   PC-relative load (F6) is inside the ROM.
2. Every predicted halt is checked on its own: the program starts at that
   cell (the word start_cell patched), every other predicted halt is
   replaced with a NOP (mov r8, r8), and the lockstep run must end with the
   DUT halted with the predicted code at the predicted halfword, every
   retire before it matching the reference. Nothing else may differ: the
   only mismatches allowed are the DUT's halt, the reference taking an
   exception (UNDEF and SWI space, or the aimed target of a FETCH), and the
   stall once the DUT has stopped. DATA, RO and BLOCK halts run with
   +abort_ok=1, and the reference must take a data abort in the same
   instruction.
3. The whole program, with every predicted halt replaced with a NOP, runs in
   lockstep from the first cell to the end marker. Every cell must match
   the reference retire by retire, with no halt and no exception or abort
   on either side.
Prints one PASS or FAIL line with the counts.
SPDX-License-Identifier: MIT
"""
import collections
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tfuzz  # noqa: E402

VERIF = os.path.normpath(os.path.join(HERE, "..", "..", "verif"))
NAMES = {1: "UNDEF", 4: "FETCH", 5: "DATA", 6: "RO", 7: "BLOCK", 8: "FLAGS"}
NOP = 0x46C0
# After a halt other than DATA, RO or BLOCK the reference may take an exception
# or an abort (the UNDEF space, an empty list's random base, an aimed target).
OK_LINES = ("MISMATCH DUT halted (", "MISMATCH reference took an exception at ", "MISMATCH nothing compared for ",
            "MISMATCH reference data abort at ")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    lock, work, image, seed = sys.argv[1:5]
    rest = sys.argv[5:]
    cells = int(rest.pop(0)) if rest and not rest[0].startswith("+") else 200
    extra = rest + (["+seed=" + seed] if rest else [])
    os.makedirs(work, exist_ok=True)
    b = os.path.join(work, "tfuzz%s" % seed)

    def fail(why):
        print("FAIL tfuzz seed %s: %s" % (seed, why))
        sys.exit(1)

    asm, meta = tfuzz.generate(int(seed), cells)
    open(b + ".S", "w").write(asm)
    json.dump(meta, open(b + ".json", "w"), indent=0)
    for cmd in (["arm-none-eabi-gcc", "-mcpu=arm7tdmi", "-nostdlib", "-nostartfiles",
                 "-Wl,-T," + os.path.join(VERIF, "isa", "link.ld"), "-Wl,--no-warn-rwx-segments",
                 "-o", b + ".elf", b + ".S"],
                ["arm-none-eabi-objcopy", "-O", "binary", "-j", ".text", b + ".elf", b + ".bin"],
                ["python3", os.path.join(VERIF, "isa", "bin2hex.py"), b + ".bin", b + ".hex"]):
        r = run(cmd)
        if r.returncode:
            fail("does not build: " + (r.stderr or r.stdout).strip().splitlines()[-1])
    if os.path.getsize(b + ".bin") > 0x3C00:
        fail("the program is %d bytes; it must stay below 0x3C00" % os.path.getsize(b + ".bin"))
    sym = {}
    for line in run(["arm-none-eabi-nm", b + ".elf"]).stdout.splitlines():
        m = re.match(r"([0-9a-f]+) . (\w+)$", line)
        if m:
            sym[m.group(2)] = int(m.group(1), 16)
    rom = [int(x, 16) for x in open(b + ".hex").read().split()]

    def patch(words, addr, hw):
        i = addr >> 2
        words[i] = (words[i] & 0xFFFF) | hw << 16 if addr & 2 else (words[i] & 0xFFFF0000) | hw

    def where(c):
        return sym[("fz%d" if c["exp"][1] == "fz" else "cp%d") % c["k"]]

    for c in meta:
        if (sym["fz%d" % c["k"]] >> 1) & 1 != c["align"]:
            fail("fz%d at %08x, not at the alignment tfuzz.py laid out" % (c["k"], sym["fz%d" % c["k"]]))
    exp = [c for c in meta if c["exp"]]
    # Every predicted halt out: a NOP at the halfword, and at the cell's probe.
    nopped = list(rom)
    for c in exp:
        if c["exp"][1] == "fz":
            patch(nopped, sym["fz%d" % c["k"]], NOP)
        if "cp%d" % c["k"] in sym:
            patch(nopped, sym["cp%d" % c["k"]], NOP)

    def lockstep(words, start, plus):
        words = list(words)
        words[sym["start_cell"] >> 2] = start
        h = b + ".run.hex"
        open(h, "w").write("".join("%08x\n" % w for w in words))
        return run([lock, "+rom=" + image, "+romhex=" + h, "+maxret=10000000"] + plus + extra).stdout

    # 2. Each predicted halt, from its own cell.
    halts = collections.Counter()
    ref_exc = collections.Counter()
    for c in exp:
        code, at = c["exp"][0], where(c)
        words = list(nopped)
        if c["exp"][1] == "fz":
            patch(words, at, rom[at >> 2] >> (16 if at & 2 else 0) & 0xFFFF)
        else:
            patch(words, sym["cp%d" % c["k"]], rom[at >> 2] >> (16 if at & 2 else 0) & 0xFFFF)
        mem = code in (5, 6, 7)
        out = lockstep(words, c["k"], ["+stall=3000", "+maxfail=50"] + (["+abort_ok=1"] if mem else []))
        open(b + ".halt%d.log" % c["k"], "w").write(out)
        m = re.search(r"^bup_cpu halted: code (\d+), pc ([0-9a-f]+)", out, re.M)
        desc = "cell %d (%s %s, %s)" % (c["k"], c["fmt"], "%04x" % c["hw"] if c["hw"] != "bl" else "bl",
                                         c["exp"][2])
        if not m:
            first = [l for l in out.splitlines() if l.startswith(("MISMATCH", "stop"))][:3]
            fail("%s: expected %s at %08x, the DUT did not halt (%s.halt%d.log): %s" % (
                desc, NAMES[code], at, b, c["k"], " | ".join(first)))
        got = (int(m.group(1)), int(m.group(2), 16))
        if got != (code, at):
            fail("%s: expected %s at %08x, the DUT halted with %s at %08x (%s.halt%d.log)" % (
                desc, NAMES[code], at, NAMES.get(got[0], got[0]), got[1], b, c["k"]))
        if mem:
            if not ("LOCKSTEP PASS" in out and re.search(r"^stop: reference abort, DUT halted", out, re.M)
                    and re.search(r"^reference data abort at", out, re.M)):
                first = [l for l in out.splitlines() if l.startswith(("MISMATCH", "stop", "reference data abort"))][:3]
                fail("%s: %s at %08x, but the reference does not abort there (%s.halt%d.log): %s" % (
                    desc, NAMES[code], at, b, c["k"], " | ".join(first)))
        else:
            bad = [l for l in out.splitlines() if l.startswith("MISMATCH") and not l.startswith(OK_LINES)]
            if bad:
                fail("%s: before the halt (%s.halt%d.log): %s" % (desc, b, c["k"], " | ".join(bad[:3])))
            # The reference's own view: UNDEF space traps at the halfword; an
            # aimed FETCH target aborts (or runs on, for BX to ARM with bit 1).
            if ("MISMATCH reference took an exception at %08x" % at if code == 1 else
                    "MISMATCH reference took an exception at ") in out:
                ref_exc[code] += 1
        halts[code] += 1

    # 3. Everything else, from the first cell to the end marker.
    out = lockstep(nopped, 0, ["+abort_ok=1", "+stall=20000"])
    open(b + ".lock.log", "w").write(out)
    if not ("LOCKSTEP PASS" in out and re.search(r"^stop: FAULT write", out, re.M)):
        first = [l for l in out.splitlines() if l.startswith(("MISMATCH", "stop", "reference data abort", "bup_cpu"))][:4]
        m = re.search(r"^bup_cpu halted: code (\d+), pc ([0-9a-f]+)", out, re.M)
        if m:
            pc = int(m.group(2), 16)
            cell = [c for c in meta if sym["c%d" % c["k"]] <= pc][-1]
            first.insert(0, "unpredicted %s halt in cell %d (%s %s, %s)" % (
                NAMES.get(int(m.group(1)), m.group(1)), cell["k"], cell["fmt"],
                "%04x" % cell["hw"] if cell["hw"] != "bl" else "bl", cell["note"] or cell["kind"]))
        fail("lockstep (%s.lock.log): %s" % (b, " | ".join(first)))
    m = re.search(r"^compared: (\d+) retires, (\d+) RAM stores", out, re.M)
    ncskip = re.search(r"^C not compared in (\d+) retires", out, re.M)
    nfz = sum(1 for c in meta if not (c["exp"] and c["exp"][1] == "fz"))
    nprobe = sum(1 for c in meta if c["probe"])
    print("PASS tfuzz seed %s: %d cells, %d ran in lockstep (%s retires, %s stores, C masked in %s), "
          "%d halted as predicted: %s; %d probes" % (
              seed, cells, nfz, m.group(1), m.group(2), ncskip.group(1) if ncskip else 0, sum(halts.values()),
              ", ".join("%s %d%s" % (NAMES[k], v, " (reference: exception %d)" % ref_exc[k] if k in (1, 4) else "")
                        for k, v in sorted(halts.items())), nprobe))
    json.dump(dict(seed=int(seed), cells=cells, ran=nfz, halts={NAMES[k]: v for k, v in halts.items()},
                   ref_exc={NAMES[k]: v for k, v in ref_exc.items()},
                   fmt_ran=collections.Counter(c["fmt"] for c in meta if not (c["exp"] and c["exp"][1] == "fz")),
                   retires=int(m.group(1)), stores=int(m.group(2))), open(b + ".result.json", "w"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
