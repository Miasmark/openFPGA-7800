#!/usr/bin/env python3
"""2600 cartridge-RAM tests in the whole core (DARIA step 7, Fix B).

Test images (our own code, no game data), the run matrix on tb_cartram
(tb_load + the +cartram monitor, sim/tb_cartram.sv), the directed s19 run,
and the checks, each with an exit code (0 pass, 1 fail, 2 usage or build
error). docs/DARIA_CORE.md, "Fix B" section 4; docs/daria_step7/plan.md 1.2
row 6 and 3.6.

  cartram2600_test.py MAPPER > image.bin
      one image per RAM mapper: f8sc f4sc fa cv e7 3e wd cty. Prints its
      +bs= index on stderr. Each image runs, for every RAM area of its
      mapper, over and over: STA W,X (a dummy read of the write port
      first), CMP R,X; STA (pw),Y and CMP (pr),Y at a second offset; a
      routine copied into RAM through W and run from R, whose STA writes
      the opcode of its own next instruction (INX), fetched from RAM in the
      very next cycle. AUDF0 (tb_load +arprobe logs it) is 1 at start,
      16 + (iteration & 7) after each passing iteration, 2 + 5 * area +
      phase on a failure.
  cartram2600_test.py ram7800 > image.a78
      a 7800 RAM cartridge (A78 type 0x0004, RAM at $4000): writes and reads
      back 256 bytes, runs a routine from $4100, then AUDF0 = 7 (pass) or 31
      (fail); tb_load's TONE line tells them apart.
  cartram2600_test.py check LOG --image NAME [--blend 0|1] [--profile P]
                             [--ref REF_LOG]
      one run's verdict (NAME: a mapper, arfull, artape, armulti, armimg or
      ram7800; --ref: the reference build's log of the same case, for
      artape's colours).
  cartram2600_test.py matrix [--work DIR] [--build] [--rtl-tree DIR]
                             [--profile P] [--only NAME,...] [--arfw FILE]
                             [--ref-logs DIR] [--fp]
      every mapper image with Flicker Blend off and on (60 ms each), the
      Supercharger's full load (blend off and on, with the RAM dump check)
      and multiload, the 7800 RAM cartridge, and a synthetic DPC+ image
      (fe_dir/mkimg.py) that must make no cart-RAM access at all; with
      --arfw FILE (the Supercharger BIOS) also the full load from tape
      (artape, 22 simulated seconds, about an hour); then the verdicts.
      --ref-logs DIR: the reference build's matrix logs (its WORK's
      cartram/logs), whose artape colours this run's must equal. --fp: every
      run also writes its tb_load +fp fingerprint to WORK/fp/cartram_<case>.csv,
      for comparing two builds frame by frame (sim/check/frame_gate.py
      --strict; plan 7.5 row 5).
  cartram2600_test.py s19 [--work DIR] [--build] [--rtl-tree DIR]
                          [--profile P] [--images e7,...] [--fp]
      the directed s19 run: +inject=sweep places a BIOS download write at
      every clk_sdram edge of the 6507 cycle in turn. With Fix B the read
      whose cycle has it at s8 lands at s19: the run must reach s19 and go
      no further. Before Fix B it measures today's worst case (s15).

Profiles (--profile, default auto: from the CARTRAM sram_ctrl line, which
tb_cartram prints from SIM_FIXB, set by run_sim.sh when sram_ctrl.sv has
t_new): the latency buckets each build may show, Flicker Blend off / on:
  base  (aeee6d2)  off: 11 normal, 7 repeated address;  on: 11 or 14, 9
  fixb  (F, D)     off: 15 normal, 11 repeated address; on: 15, 11 or 14
Every bucket must be one of these; no read may land past s19; on the 8
mapper images the normal bucket holds more reads than the repeated one.
With the fixb profile, chosen or detected, every run must also show the P2
assertion armed (tb_load's "P2 armed" line, from SIM_FIXB): Fix B buckets
on a build without the assertion fail.

The Supercharger loads: arfull (the core's loader stub) must show magenta
$54 / AUDF0 5 and the RAM dump equal to the image (ARCHECK 0). artape (the
BIOS, from tape) takes seconds, and the BIOS plays its own tones (AUDF0
counting down) while it loads: the load has run when AUDF0 5 follows the
tape stopping (extra_tests_check.py's rule), with ARCHECK 0. The colour the
program then sets depends on what the BIOS leaves in $80 (ar_test.py; on
aeee6d2, white $0e, not magenta): with --ref (--ref-logs) it must equal the
reference build's, and without one it is reported, not judged.

The runs: --work DIR is a run_sim.sh work directory (default $WORK, else
sim/work): obj_cartram/ there (built by run_sim.sh with BUILD_TOP=tb_cartram
when --build is given, from --rtl-tree's RTL when given, else this tree's),
and the images and logs in DIR/cartram/. VERILATOR and VL_JOBS pass through
to run_sim.sh.
SPDX-License-Identifier: MIT
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AUDC0, AUDF0, AUDV0 = 0x15, 0x17, 0x19
SEED, PW, PR = 0x90, 0x92, 0x94      # zero page
ORG = 0xFC00
MAPPERS = ("f8sc", "f4sc", "fa", "cv", "e7", "3e", "wd", "cty")
BS = {"f8sc": 0, "f4sc": 0, "fa": 0, "cv": 9, "e7": 12, "3e": 16, "wd": 18, "cty": 22}

# Per image, at its run length: (CPU reads of cart RAM, write strobes, bytes
# in the shadow). The counts do not depend on the build (step 1 measured the
# same on 2.1.2 + Fix A and on the Fix B prototype); a lost or extra access
# changes them (the nocmp mutant: DARIA_CORE.md, plan 3.4).
EXPECT = {
    "f8sc": (1855, 3943, 128), "f4sc": (1855, 3943, 128), "fa": (1819, 3993, 256),
    "cv": (1819, 3993, 512), "e7": (1819, 3995, 768), "3e": (1819, 3995, 1024),
    "wd": (1918, 3898, 64), "cty": (1935, 3871, 60),
    "arfull": (232458, 6144, 6144), "armulti": (1516502, 512, 256),
}
RUN_MS = {m: 60 for m in MAPPERS}
RUN_MS.update(arfull=300, armulti=1300, artape=22000, armimg=60)
BUCKETS = {   # (profile, blend): (normal, repeated address)
    ("base", 0): ({11}, {7}), ("base", 1): ({11, 14}, {9}),
    ("fixb", 0): ({15}, {11}), ("fixb", 1): ({15}, {11, 14}),
}
LIMIT = 19     # the c_rdata multicycle: a byte for the latch at s24 must be written by s19


# ------------------------------------------------------------------ images
def asm(org, items):
    labels, pc = {}, org
    for it in items:
        if isinstance(it, tuple) and it[0] == "label":
            labels[it[1]] = pc
        else:
            pc += 2 if isinstance(it, tuple) and it[0] == "abs" else 1
    out, pc = [], org
    for it in items:
        if isinstance(it, int):
            out.append(it); pc += 1
        elif it[0] == "abs":
            a = labels[it[1]] if isinstance(it[1], str) else it[1]
            out += [a & 0xFF, (a >> 8) & 0xFF]; pc += 2
        elif it[0] == "rel":
            off = labels[it[1]] - (pc + 1); assert -128 <= off < 128, it
            out.append(off & 0xFF); pc += 1
    return bytes(out), labels


def A(a):
    return ("abs", a)


# An area: (setup items, W, R, N, offset)
def areas_for(name):
    sc = [([], 0x1000, 0x1080, 128, 0)]
    if name in ("f8sc", "f4sc"):
        return sc
    if name == "fa":
        return [([], 0x1000, 0x1100, 256, 0)]
    if name == "cv":
        return [([], 0x1400, 0x1000, 256, 0x300)]
    if name == "e7":
        return [([0xAD, A(0x1FE7)], 0x1000, 0x1400, 256, 0x300),       # bank 7: 1K RAM
                ([0xAD, A(0x1FEA)], 0x1800, 0x1900, 256, 0)]           # 256-byte bank 2
    if name == "3e":
        return [([0xA9, 0x00, 0x85, 0x3E], 0x1400, 0x1000, 256, 0x300),  # RAM bank 0
                ([0xA9, 0x05, 0x85, 0x3E], 0x1400, 0x1000, 256, 0x100)]  # RAM bank 5
    if name == "wd":
        return [([], 0x1040, 0x1000, 64, 0)]
    if name == "cty":
        return [([], 0x1004, 0x1044, 60, 0)]
    raise SystemExit("unknown mapper " + name)


def program(areas):
    it = [0x78, 0xD8, 0xA2, 0xFF, 0x9A,
          0xA9, 0x04, 0x85, AUDC0, 0xA9, 0x0F, 0x85, AUDV0,
          0xA9, 0x01, 0x85, AUDF0,
          0xA9, 0x00, 0x85, SEED,
          ("label", "iter")]
    for k, (setup, w, r, n, off) in enumerate(areas):
        nn = n & 0xFF
        L = lambda s: f"{s}{k}"
        fail = lambda ph: 2 + 5 * k + ph
        it += list(setup)
        # 1. STA W,X
        it += [0xA2, 0x00, ("label", L("p1")), 0x8A, 0x45, SEED, 0x9D, A(w),
               0xE8, 0xE0, nn, 0xD0, ("rel", L("p1"))]
        # 2. CMP R,X
        it += [0xA2, 0x00, ("label", L("p2")), 0x8A, 0x45, SEED, 0xDD, A(r),
               0xD0, ("rel", L("f1")), 0xE8, 0xE0, nn, 0xD0, ("rel", L("p2"))]
        # 3. STA (pw),Y at W+off
        it += [0xA9, (w + off) & 0xFF, 0x85, PW, 0xA9, (w + off) >> 8, 0x85, PW + 1,
               0xA9, (r + off) & 0xFF, 0x85, PR, 0xA9, (r + off) >> 8, 0x85, PR + 1,
               0xA0, 0x00, ("label", L("p3")), 0x98, 0x18, 0x65, SEED, 0x91, PW,
               0xC8, 0xC0, nn, 0xD0, ("rel", L("p3"))]
        # 4. CMP (pr),Y
        it += [0xA0, 0x00, ("label", L("p4")), 0x98, 0x18, 0x65, SEED, 0xD1, PR,
               0xD0, ("rel", L("f2")), 0xC8, 0xC0, nn, 0xD0, ("rel", L("p4"))]
        # 5. routine into RAM at offset 0, run from R: LDA #$E8; STA W+5; (NOP->INX); RTS
        rout = [0xA9, 0xE8, 0x8D, (w + 5) & 0xFF, (w + 5) >> 8, 0xEA, 0x60]
        it += [0xA2, 0x00, ("label", L("p5")), 0xBD, A(L("rt")), 0x9D, A(w),
               0xE8, 0xE0, len(rout), 0xD0, ("rel", L("p5")),
               0xA2, 0x00, 0x20, A(r), 0xE0, 0x01, 0xD0, ("rel", L("f3")),
               0x4C, A(L("next"))]
        it += [("label", L("f1")), 0xA9, fail(1), 0x4C, A("hang"),
               ("label", L("f2")), 0xA9, fail(2), 0x4C, A("hang"),
               ("label", L("f3")), 0xA9, fail(3), 0x4C, A("hang"),
               ("label", L("rt")), *rout,
               ("label", L("next"))]
    it += [0xE6, SEED, 0xA5, SEED, 0x29, 0x07, 0x09, 0x10, 0x85, AUDF0,
           0x4C, A("iter"),
           ("label", "hang"), 0x85, AUDF0, ("label", "h2"), 0x4C, A("h2")]
    return asm(ORG, it)[0]


def bank4k(prog, sc):
    b = bytearray([0xFF] * 0x1000)
    b[0:0x100] = bytes(0x100) if sc else bytes((i * 37 + 11) & 0xFF for i in range(0x100))
    b[0xC00:0xC00 + len(prog)] = prog
    for v in (0xFFA, 0xFFC, 0xFFE):
        b[v], b[v + 1] = ORG & 0xFF, ORG >> 8
    return b


def image(name):
    prog = program(areas_for(name))
    assert len(prog) < 0x3E0, len(prog)
    if name in ("f8sc", "f4sc", "fa", "cty"):
        size = {"f8sc": 0x2000, "f4sc": 0x8000, "fa": 0x3000, "cty": 0x8000}[name]
        return bytes(bank4k(prog, name in ("f8sc", "f4sc")) * (size // 0x1000))
    if name == "cv":                     # 2K: ROM at $1800-$1FFF
        b = bytearray([0xFF] * 0x800)
        b[0x400:0x400 + len(prog)] = prog
        for v in (0x7FA, 0x7FC, 0x7FE):
            b[v], b[v + 1] = ORG & 0xFF, ORG >> 8
        return bytes(b)
    size, at = {"e7": (0x4000, 0x3C00), "3e": (0x2000, 0x1C00), "wd": (0x2000, 0x0C00)}[name]
    b = bytearray([0xFF] * size)
    b[at:at + len(prog)] = prog
    for v in (at + 0x3FA, at + 0x3FC, at + 0x3FE):
        b[v], b[v + 1] = ORG & 0xFF, ORG >> 8
    return bytes(b)


def ram7800_rom(audf=7):
    """16 KB at $C000: write $4000-$40FF, read it back, copy a routine to
    $4100 and run it (its STA writes its own next opcode), AUDF0 = audf or 31."""
    prog, lab = asm(0xC000, [
        0x78, 0xD8, 0xA9, 0x07, 0x85, 0x01, 0xA2, 0xFF, 0x9A,
        0xA9, 0x04, 0x85, 0x15, 0xA9, 0x0F, 0x85, 0x19,
        0xA2, 0x00, ("label", "w"), 0x8A, 0x49, 0x5A, 0x9D, A(0x4000), 0xE8, 0xD0, ("rel", "w"),
        0xA2, 0x00, ("label", "r"), 0x8A, 0x49, 0x5A, 0xDD, A(0x4000), 0xD0, ("rel", "fail"), 0xE8, 0xD0, ("rel", "r"),
        0xA2, 0x00, ("label", "c"), 0xBD, A("rt"), 0x9D, A(0x4100), 0xE8, 0xE0, 7, 0xD0, ("rel", "c"),
        0xA2, 0x00, 0x20, A(0x4100), 0xE0, 0x01, 0xD0, ("rel", "fail"),
        0xA9, audf, 0x85, 0x17, ("label", "idle"), 0x4C, A("idle"),
        ("label", "fail"), 0xA9, 31, 0x85, 0x17, 0x4C, A("idle"),
        ("label", "rt"), 0xA9, 0xE8, 0x8D, 0x05, 0x41, 0xEA, 0x60,
        ("label", "rti"), 0x40])
    img = bytearray([0xFF] * 0x4000)
    img[0:len(prog)] = prog
    for vec, a in ((0x3FFA, lab["rti"]), (0x3FFC, 0xC000), (0x3FFE, lab["rti"])):
        img[vec], img[vec + 1] = a & 0xFF, a >> 8
    return bytes(img)


def write_ram7800(path):
    binp = path + ".bin"
    open(binp, "wb").write(ram7800_rom())
    a78 = subprocess.run([sys.executable, os.path.join(HERE, "make_a78.py"), "--bin", binp, "--type", "0x0004"],
                         capture_output=True, check=True).stdout
    open(path, "wb").write(a78)


# ------------------------------------------------------------------ checks
def parse(log):
    t = open(log, "rb").read().decode("utf-8", "replace")
    r = {"text": t}
    m = re.search(r"^CARTRAM sram_ctrl: (.*)$", t, re.M)
    r["sram"] = m.group(1) if m else None
    m = re.search(r"^CARTRAM reads: (\d+) CPU reads of cart RAM, (\d+) wrong byte, (\d+) without a fresh access, "
                  r"c_rdata at E0\+(-?\d+)\.\.(-?\d+) clk_sdram, min margin to the latch (-?\d+) clk_sdram, "
                  r"(\d+) past E0\+19", t, re.M)
    r["reads"] = tuple(int(x) for x in m.groups()) if m else None
    m = re.search(r"^CARTRAM latency histogram \(clk_sdram from E0: count\):(.*)$", t, re.M)
    r["hist"] = {int(a): int(b) for a, b in re.findall(r"(\d+):(\d+)", m.group(1))} if m else None
    m = re.search(r"^CARTRAM writes: (\d+) strobes at the mappers, (\d+) cart writes issued, (\d+) bytes in the shadow, "
                  r"(\d+) differ from the SRAM; (\d+) data changes inside a strobe", t, re.M)
    r["writes"] = tuple(int(x) for x in m.groups()) if m else None
    m = re.search(r"^CARTRAM traffic: .*address or direction changes inside a held strobe (\d+)", t, re.M)
    r["mid"] = int(m.group(1)) if m else None
    r["audf"] = [int(x) for x in re.findall(r"^AR \d+ ms: AUDF0 = (\d+)$", t, re.M)]
    r["colubk"] = re.findall(r"^AR \d+ ms: COLUBK = \$([0-9a-f]{2})$", t, re.M)
    m = re.search(r"^ARCHECK (\d+) pages, (\d+) of (\d+) RAM bytes differ", t, re.M)
    r["archeck"] = tuple(int(x) for x in m.groups()) if m else None
    m = re.search(r"^TONE from loaded cart AUDF0=(\d+): .* ratio ([0-9.]+)$", t, re.M)
    r["tone"] = (int(m.group(1)), float(m.group(2))) if m else None
    r["inject"] = [(int(d), int(n), int(a), int(b)) for d, n, a, b in
                   re.findall(r"^CARTRAM inject phase s(\d+): (\d+) reads, c_rdata at E0\+(-?\d+)\.\.(-?\d+)$", t, re.M)]
    r["fatal"] = re.findall(r"^(?:\[\d+\] )?%(?:Error|Fatal).*$", t, re.M)
    r["p2"] = bool(re.search(r"^P2 armed:", t, re.M))
    # the tones that follow the tape stopping (the BIOS's own count down
    # comes before): one per load
    loads, stopped = [], False
    for l in t.splitlines():
        if re.match(r"^AR \d+ ms: tape stops", l):
            stopped = True
        m = re.match(r"^AR \d+ ms: AUDF0 = (\d+)$", l)
        if m and stopped and m.group(1) != "0":
            loads.append(int(m.group(1)))
            stopped = False
    r["tape_loads"] = loads
    r["md5"] = re.findall(r"^-- tb_cartram: (obj_cartram/vtb md5 \S+)", t, re.M)
    return r


def profile_of(r, want):
    if want != "auto":
        return want
    if r["sram"] is None:
        return None
    return "fixb" if r["sram"].startswith("Fix B") else "base"


def check(log, name, blend, profile="auto", expect_counts=True, ref=None):
    """Returns (ok, reasons, summary). ref: the reference build's log of the
    same case (artape's colours)."""
    r = parse(log)
    bad = []
    if r["fatal"]:
        bad.append("simulator: " + r["fatal"][0][:120])
    if profile_of(r, profile) == "fixb" and not r["p2"]:
        bad.append("fixb profile, but the P2 assertion is not armed (no 'P2 armed' line: SIM_FIXB not defined)")
    if name == "ram7800":
        if not r["tone"]:
            bad.append("no TONE line")
        elif not (0.99 <= r["tone"][1] <= 1.01):
            bad.append(f"TONE ratio {r['tone'][1]} (31 = the program's fail code)")
        summ = f"tone ratio {r['tone'][1] if r['tone'] else '-'}"
        return not bad, bad, summ
    prof = profile_of(r, profile)
    if prof is None:
        bad.append("no CARTRAM sram_ctrl line (not tb_cartram, or no +cartram)")
    if name == "armimg":
        if not r["reads"] or not r["writes"]:
            bad.append("CARTRAM lines missing")
        elif r["reads"][0] or r["writes"][0] or r["writes"][1]:
            bad.append(f"an ARM image reached the SRAM's cart RAM: reads {r['reads'][0]}, strobes {r['writes'][0]}, "
                       f"writes issued {r['writes'][1]} (all must be 0)")
        return not bad, bad, f"reads {r['reads'][0] if r['reads'] else '-'} strobes {r['writes'][0] if r['writes'] else '-'}"
    if not r["reads"] or r["hist"] is None or not r["writes"] or r["mid"] is None:
        bad.append("CARTRAM lines missing")
        return False, bad, "-"
    n, wrong, stale, lo, hi, margin, late = r["reads"]
    strobes, issued, sh_n, sh_bad, dchg = r["writes"]
    if wrong: bad.append(f"{wrong} wrong bytes")
    if stale: bad.append(f"{stale} reads without a fresh access")
    if late or hi > LIMIT: bad.append(f"c_rdata past s{LIMIT}: max s{hi}, {late} reads")
    if strobes != issued: bad.append(f"writes issued {issued} != strobes {strobes}")
    if sh_bad: bad.append(f"{sh_bad} shadow bytes differ from the SRAM")
    if dchg: bad.append(f"{dchg} data changes inside a strobe")
    if r["mid"]: bad.append(f"{r['mid']} address/direction changes inside a held strobe")
    if n == 0: bad.append("no reads")
    if expect_counts and name in EXPECT:
        er, ew, es = EXPECT[name]
        if (n, strobes, sh_n) != (er, ew, es):
            bad.append(f"counts reads/writes/shadow {n}/{strobes}/{sh_n}, expected {er}/{ew}/{es}")
    if prof in ("base", "fixb"):
        normal, rep = BUCKETS[(prof, blend)]
        extra = sorted(set(r["hist"]) - normal - rep)
        if extra:
            bad.append(f"buckets {extra} outside {sorted(normal | rep)} ({prof}, blend {blend})")
        if name in MAPPERS:
            nn = sum(v for k, v in r["hist"].items() if k in normal)
            nr = sum(v for k, v in r["hist"].items() if k in rep)
            if nn <= nr:
                bad.append(f"normal buckets {sorted(normal)} hold {nn} reads, repeated {sorted(rep)} {nr}")
    # pass and fail codes
    if name in MAPPERS:
        fails = [v for v in r["audf"] if 2 <= v < 16]
        if fails: bad.append(f"fail code AUDF0 {fails[0]}")
        if not [v for v in r["audf"] if 16 <= v <= 23]: bad.append("no pass code (AUDF0 16-23)")
    elif name == "arfull":
        if 5 not in r["audf"] or "54" not in r["colubk"]: bad.append("no magenta $54 / AUDF0 5")
        if r["archeck"] is None: bad.append("no ARCHECK line")
        elif r["archeck"][1]: bad.append(f"ARCHECK {r['archeck'][1]} RAM bytes differ")
    elif name == "artape":
        if r["tape_loads"][:1] != [5]:
            bad.append(f"tones after the tape stopped {r['tape_loads']}, expected 5 (the full load)")
        if r["archeck"] is None: bad.append("no ARCHECK line")
        elif r["archeck"][1]: bad.append(f"ARCHECK {r['archeck'][1]} RAM bytes differ")
        if ref is not None:
            if not os.path.exists(ref):
                bad.append(f"no reference log {ref}")
            else:
                rc_ = parse(ref)["colubk"]
                if rc_ != r["colubk"]:
                    bad.append(f"colours {r['colubk']} differ from the reference build's {rc_}")
    elif name == "armulti":
        if r["audf"][:1] != [7] or 14 not in r["audf"] or "c4" not in r["colubk"]:
            bad.append(f"multiload codes {r['audf']} (expect 7, then 14)")
    hist = " ".join(f"{k}:{v}" for k, v in sorted(r["hist"].items()))
    summ = f"{prof} reads {n} writes {strobes} shadow {sh_n} hist {hist}"
    if name == "artape":
        cols = [c for c in r["colubk"] if c != "00"]
        summ += (f"; colours {' '.join('$' + c for c in cols) or '-'}"
                 + (" (equal to the reference's)" if ref is not None and not bad else
                    "" if ref is not None else " (no reference given: not judged)"))
    return not bad, bad, summ


# ------------------------------------------------------------------ runs
def build(a):
    env = dict(os.environ, WORK=a.work, BUILD_TOP="tb_cartram", VL_JOBS=os.environ.get("VL_JOBS", "2"))
    if a.rtl_tree:
        env["RTL_TREE"] = os.path.abspath(a.rtl_tree)
    r = subprocess.run(["bash", os.path.join(HERE, "run_sim.sh")], env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.stdout.write(r.stderr)
        sys.exit(2)


def vtb_md5(a):
    import hashlib
    return hashlib.md5(open(os.path.join(a.work, "obj_cartram", "vtb"), "rb").read()).hexdigest()


def header(a):
    # plan P23: which binary these verdicts belong to
    print(f"-- tb_cartram: obj_cartram/vtb md5 {vtb_md5(a)} ({os.path.join(a.work, 'obj_cartram', 'vtb')})")
    sys.stdout.flush()


def fp_arg(a, case):
    if not getattr(a, "fp", False):
        return []
    os.makedirs(os.path.join(a.work, "fp"), exist_ok=True)
    return [f"+fp={os.path.join(a.work, 'fp', 'cartram_' + case + '.csv')}"]


def run(a, name, args, log):
    vtb = os.path.join(a.work, "obj_cartram", "vtb")
    run_dir = os.path.join(a.work, "cartram", "run")
    os.makedirs(run_dir, exist_ok=True)
    rtl = os.path.join(run_dir, "rtl")
    if not os.path.islink(rtl):
        os.symlink(os.path.join(a.work, "rtl"), rtl)
    with open(log, "wb") as f:
        subprocess.run([vtb] + args, cwd=run_dir, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)


def images(a):
    d = os.path.join(a.work, "cartram", "img")
    os.makedirs(d, exist_ok=True)
    for m in MAPPERS:
        open(os.path.join(d, m + ".bin"), "wb").write(image(m))
    for mode in ("full", "multi"):
        out = subprocess.run([sys.executable, os.path.join(HERE, "ar_test.py"), mode], capture_output=True, check=True).stdout
        open(os.path.join(d, f"ar{mode}.bin"), "wb").write(out)
    write_ram7800(os.path.join(d, "ram7800.a78"))
    # a synthetic DPC+ image (fe_dir/mkimg.py): an ARM scheme never reaches
    # the SRAM's cart RAM (Fix A, decision 4)
    subprocess.run([sys.executable, os.path.join(HERE, "bupchip", "daria", "fe_dir", "mkimg.py"),
                    os.path.join(d, "arm"), "smoke_dpc"], capture_output=True, check=True)
    shutil.copy(os.path.join(d, "arm", "smoke_dpc.bin"), os.path.join(d, "armimg.bin"))
    return d


def cases_matrix(only, tape=False):
    c = [(m, b) for m in MAPPERS for b in (0, 1)] + [("arfull", 0), ("arfull", 1), ("armulti", 0), ("ram7800", 0),
                                                       ("armimg", 0)] + ([("artape", 0)] if tape else [])
    return [x for x in c if not only or x[0] in only]


def case_args(img, name, blend, extra=()):
    if name == "ram7800":
        return [f"+image={img}/ram7800.a78", "+audf=7"]
    args = [f"+image={img}/{'arfull' if name == 'artape' else name}.bin", "+arprobe", "+cartram", f"+wav={RUN_MS[name]}"]
    if name in BS and BS[name]:
        args.append(f"+bs={BS[name]}")
    if blend:
        args.append("+blend")
    return args + list(extra)


def cmd_matrix(a):
    if a.build:
        build(a)
    header(a)
    img = images(a)
    logs = os.path.join(a.work, "cartram", "logs")
    os.makedirs(logs, exist_ok=True)
    ok_all = True
    only = set(a.only.split(",")) if a.only else None
    for name, blend in cases_matrix(only, bool(a.arfw)):
        log = os.path.join(logs, f"{name}_b{blend}.log")
        extra = []
        if name in ("arfull", "artape"):
            extra = [f"+ardump={logs}/ram_{name}_b{blend}.bin"]
        if name == "artape":
            extra.append(f"+arfw={os.path.abspath(a.arfw)}")
        extra += fp_arg(a, f"{name}_b{blend}")
        run(a, name, case_args(img, name, blend, extra), log)
        if name in ("arfull", "artape"):
            ck = subprocess.run([sys.executable, os.path.join(HERE, "ar_test.py"), "check",
                                 f"{logs}/ram_{name}_b{blend}.bin", f"{img}/arfull.bin"], capture_output=True, text=True)
            open(log, "a").write(ck.stdout)
        ref = os.path.join(a.ref_logs, f"{name}_b{blend}.log") if a.ref_logs and name == "artape" else None
        ok, bad, summ = check(log, name, blend, a.profile, ref=ref)
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} {name} blend {blend}: {summ}" + ("" if ok else "  <- " + "; ".join(bad)))
        sys.stdout.flush()
    print(f"CARTRAM_MATRIX {'pass' if ok_all else 'FAIL'}")
    return 0 if ok_all else 1


def cmd_s19(a):
    if a.build:
        build(a)
    header(a)
    img = images(a)
    logs = os.path.join(a.work, "cartram", "logs")
    os.makedirs(logs, exist_ok=True)
    ok_all = True
    for name in a.images.split(","):
        log = os.path.join(logs, f"s19_{name}.log")
        run(a, name, case_args(img, name, 0, ["+inject=sweep"] + fp_arg(a, f"s19_{name}")), log)
        ok, bad, summ = check(log, name, 0, a.profile, expect_counts=True)
        r = parse(log)
        prof = profile_of(r, a.profile)
        hist = r["hist"] or {}
        top = max(hist) if hist else -1
        worst = max(r["inject"], key=lambda x: x[3]) if r["inject"] else None
        # Here the extra buckets are the point: drop the bucket rule, keep the rest.
        bad = [b for b in bad if not b.startswith("buckets") and not b.startswith("normal buckets")]
        if not r["inject"]:
            bad.append("no CARTRAM inject lines")
        if prof == "fixb" and hist.get(LIMIT, 0) == 0:
            bad.append(f"no read reached s{LIMIT}: the directed run did not make the worst case")
        if top > LIMIT:
            bad.append(f"a read landed at s{top}, past s{LIMIT}")
        ok = not bad
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} s19 {name} ({prof}): latest hand-over s{top}"
              + (f" with the access at s{worst[0]}" if worst else "") + f"; {summ}"
              + ("" if ok else "  <- " + "; ".join(bad)))
    print(f"CARTRAM_S19 {'pass' if ok_all else 'FAIL'}")
    return 0 if ok_all else 1


def main():
    if len(sys.argv) == 2 and sys.argv[1] in MAPPERS:
        sys.stdout.buffer.write(image(sys.argv[1]))
        print(BS[sys.argv[1]], file=sys.stderr)
        return 0
    if len(sys.argv) == 2 and sys.argv[1] == "ram7800":
        with tempfile.TemporaryDirectory() as d:
            write_ram7800(os.path.join(d, "ram7800.a78"))
            sys.stdout.buffer.write(open(os.path.join(d, "ram7800.a78"), "rb").read())
        return 0
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("log")
    c.add_argument("--image", required=True)
    c.add_argument("--blend", type=int, default=0)
    c.add_argument("--profile", default="auto", choices=("auto", "base", "fixb"))
    c.add_argument("--no-counts", action="store_true")
    c.add_argument("--ref", help="the reference build's log of the same case (artape's colours)")
    for name in ("matrix", "s19"):
        s = sub.add_parser(name)
        s.add_argument("--work", default=os.environ.get("WORK", os.path.join(HERE, "work")))
        s.add_argument("--build", action="store_true")
        s.add_argument("--rtl-tree")
        s.add_argument("--profile", default="auto", choices=("auto", "base", "fixb"))
        s.add_argument("--fp", action="store_true", help="tb_load +fp fingerprints to WORK/fp/cartram_<case>.csv")
        if name == "matrix":
            s.add_argument("--only")
            s.add_argument("--arfw", help="the Supercharger BIOS: adds the full load from tape (artape, 22 s)")
            s.add_argument("--ref-logs", help="the reference build's cartram/logs (artape's colours)")
        else:
            s.add_argument("--images", default="e7")
    a = p.parse_args()
    if a.cmd == "check":
        ok, bad, summ = check(a.log, a.image, a.blend, a.profile, not a.no_counts, ref=a.ref)
        print(f"{'PASS' if ok else 'FAIL'} {a.image} blend {a.blend}: {summ}" + ("" if ok else "  <- " + "; ".join(bad)))
        return 0 if ok else 1
    a.work = os.path.abspath(a.work)
    if getattr(a, "ref_logs", None):
        a.ref_logs = os.path.abspath(a.ref_logs)
    if not a.build and not os.path.exists(os.path.join(a.work, "obj_cartram", "vtb")):
        print("no obj_cartram/vtb in --work: add --build", file=sys.stderr)
        return 2
    return cmd_matrix(a) if a.cmd == "matrix" else cmd_s19(a)


if __name__ == "__main__":
    sys.exit(main())
