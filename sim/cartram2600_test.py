#!/usr/bin/env python3
"""2600 cartridge-RAM tests in the whole core (DARIA step 7, Fix B).

Test images (our own code, no game data), the run matrix on tb_cartram
(tb_load + the +cartram monitor, sim/tb_cartram.sv), the directed s19 run,
and the checks, each with an exit code (0 pass, 1 fail, 2 usage or build
error). docs/DARIA_CORE.md, "Fix B" section 4; docs/daria_step7/plan.md 1.2
row 6 and 3.6.

  cartram2600_test.py MAPPER > image.bin
      one image per RAM mapper: f8sc f4sc fa cv e7 3e wd cty, and hi_MAPPER
      for the same with the RAM areas at $Fxxx (A15 = 1, as Superchip code
      running at $F000-$FFFF addresses them) instead of $1xxx. Prints its
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
  cartram2600_test.py check-reset LOG --run RUN [--profile P] [--ref REF_LOG]
      one reset run's verdict (RUN: a name from the reset list below)
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
  cartram2600_test.py reset [--work DIR] [--build] [--rtl-tree DIR]
                            [--profile P] [--only RUN,...] [--ref-logs DIR]
      the console-reset reproduction (Fix B's review finding; plan P2 as
      amended): tb_cartram's +rsmode resets, each rising K clk_sys after E1
      of a cart-RAM cycle, K swept over 0..23 (the cycle and the next), on
      the A15 = 1 images hi_f8sc and hi_e7 (read and write cycles), the
      Supercharger's full load (its RAM writes), with Flicker Blend, by
      reset_in and by a reload of the image (with the bank-switch override,
      and once with the mapper detected), the A15 = 0 control (f8sc), and
      K = 0 eight times on three of them; the P2 assertion stays live in
      every run (a coincidence stops it). Pass, per run: every reset done;
      every strobe the mapper showed at E1 issued by sram_ctrl, a write with
      its byte, a read at s13 or before (c_rdata by s19); no strobe at E1
      only where expected (the detected-mapper reload at K = 0); no P2
      coincidence; and the matrix's monitor checks (no wrong or stale byte,
      writes issued = strobes, shadow = SRAM, none past s19, the build's
      buckets with the post-reset allowance below; a mapper image's pass
      code, which it shows before the first reset, and no fail code). --ref-logs DIR: another
      build's reset logs (aeee6d2's), whose per-reset cartridge accesses
      this build's must equal.
  cartram2600_test.py midswap [--work DIR] [--build] [--rtl-tree DIR]
      Fix B's address compare (plan 3.4 item 2, the nocmp mutant): +midswap
      changes the address inside a held, registered 2600 read strobe; the
      new key must be served.
  cartram2600_test.py forcecoinc [--work DIR] [--build] [--rtl-tree DIR]
      plan P2's assertion: +forcecoinc=c_rd forces a 7800 strobe into the
      clk_sdram cycle of a new 2600 request (200 times): the 2600 access
      must be served and the assertion must not fire (m_new yields: the
      nohold mutant fires it); +forcecoinc=m_new forces m_new itself there:
      the assertion must fire (it is live).
  Each of matrix, s19, reset, midswap and forcecoinc takes --mutant NAME
  (nohold: m_new without ~t_new; nocmp: t_new the registered strobe's rise
  only, no address compare): sram_ctrl.sv is mutated in a copy of the tree's
  tracked src/fpga in WORK/mut_NAME, built and run there, and the verdict is
  inverted: CAUGHT (exit 0) when the checks fail, NOT CAUGHT (exit 1) when
  they pass. The mutant is built once in its work directory (again with
  --build). nohold must be caught by reset (the K = 0 runs) and by
  forcecoinc; nocmp by midswap.

Profiles (--profile, default auto: from the CARTRAM sram_ctrl line, which
tb_cartram prints from SIM_FIXB, set by run_sim.sh when sram_ctrl.sv has
t_new): the latency buckets each build may show, Flicker Blend off / on:
  base  (aeee6d2)  off: 11 normal, 7 repeated address;  on: 11 or 14, 9
  fixb  (F, D)     off: 15 normal, 11 repeated address; on: 15, 11 or 14
Every bucket must be one of these; no read may land past s19; on the 8
mapper images the normal bucket holds more reads than the repeated one. The
first CPU read of cart RAM after each release of the console reset (the
CARTRAM post-reset line) may also land one bucket later, at s15 (base) or
s19 (fixb): another client's access can still be in flight then (a run with
a console reset showed it once on each build).
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
    # the tape load (--arfw, 22 s): aeee6d2 and F alike (lane I2's comparison)
    "artape": (6228868, 25262, 6144),
}
RUN_MS = {m: 60 for m in MAPPERS}
RUN_MS.update(arfull=300, armulti=1300, artape=22000, armimg=60)
BUCKETS = {   # (profile, blend): (normal, repeated address)
    ("base", 0): ({11}, {7}), ("base", 1): ({11, 14}, {9}),
    ("fixb", 0): ({15}, {11}), ("fixb", 1): ({15}, {11, 14}),
}
LIMIT = 19     # the c_rdata multicycle: a byte for the latch at s24 must be written by s19
POST = {"base": 15, "fixb": 19}   # the bucket the first read after a console reset may also use

# sram_ctrl.sv mutants (--mutant): (the text, its replacement)
MUTANTS = {
    "nohold": ("wire        m_new  = ((c_rd & ~c_rd_q) | (c_wr & ~c_wr_q)) & ~t_new;\n",
               "wire        m_new  = (c_rd & ~c_rd_q) | (c_wr & ~c_wr_q);\n"),
    "nocmp": ("wire        t_new = (t_rd_q | t_wr_q) & (~t_last_v | (t_key != t_last));\n",
              "reg t_rd_s = 1'b0, t_wr_s = 1'b0;\n"
              "always @(posedge clk) begin t_rd_s <= t_rd_q; t_wr_s <= t_wr_q; end\n"
              "wire        t_new = (t_rd_q & ~t_rd_s) | (t_wr_q & ~t_wr_s);\n"),
}


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


def program(areas, hi=False):
    it = [0x78, 0xD8, 0xA2, 0xFF, 0x9A,
          0xA9, 0x04, 0x85, AUDC0, 0xA9, 0x0F, 0x85, AUDV0,
          0xA9, 0x01, 0x85, AUDF0,
          0xA9, 0x00, 0x85, SEED,
          ("label", "iter")]
    for k, (setup, w, r, n, off) in enumerate(areas):
        if hi:      # the same RAM at $Fxxx: A15 = 1 (A13-A14 are not decoded)
            w, r = w | 0xE000, r | 0xE000
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
    hi = name.startswith("hi_")
    if hi:
        name = name[3:]
    prog = program(areas_for(name), hi)
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
    m = re.search(r"^CARTRAM ports: .*?: reads (\d+), writes (\d+); .*?: reads (\d+), writes (\d+) of cart RAM; (\d+) in the BIOS", t, re.M)
    r["ports"] = tuple(int(x) for x in m.groups()) if m else None
    m = re.search(r"^CARTRAM post-reset reads: (\d+) .*histogram:(.*)$", t, re.M)
    r["post"] = {int(a): int(b) for a, b in re.findall(r"(\d+):(\d+)", m.group(2))} if m else {}
    m = re.search(r"^RST armed: .*?, mode (\w+),", t, re.M)
    r["rst_mode"] = m.group(1) if m else None
    r["rst"] = []
    for m in re.finditer(r"^RST (\d+) K=(\d+): strobe (.*?); (.*?); cart(.*?); bios reads (\d+); bus before E6 (\w+); "
                         r"P2 coincidences (\d+)$", t, re.M):
        i, k, strobe, iss, cart, bios, bus, co = m.groups()
        e = re.match(r"issued at s(-?\d+)(?: data (\w+))?", iss)
        r["rst"].append(dict(i=int(i), k=int(k), strobe=strobe, issued=bool(e), edge=int(e.group(1)) if e else None,
                             data=e.group(2) if e else None, nos=(iss == "-"), cart=cart.split(), bios=int(bios),
                             bus=bus, coinc=int(co)))
    m = re.search(r"^RST summary: (\d+) of (\d+) resets", t, re.M)
    r["rst_done"] = (int(m.group(1)), int(m.group(2))) if m else None
    r["rst_incomplete"] = bool(re.search(r"^RST INCOMPLETE", t, re.M))
    m = re.search(r"^MIDSWAP verdict: (.*)$", t, re.M)
    r["midswap"] = m.group(1).strip() if m else None
    m = re.search(r"^MIDSWAP at .*cart accesses for the new key (\d+), for the old key (\d+)", t, re.M)
    r["midswap_n"] = (int(m.group(1)), int(m.group(2))) if m else None
    m = re.search(r"^FORCECOINC: (\d+) forced \((\w+)\) in 2600 mode; m_new (\d+) \(in 2600 mode (\d+)\)", t, re.M)
    r["forcecoinc"] = (int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4))) if m else None
    r["p2_fired"] = bool(re.search(r"P2: sram_ctrl m_new and t_new in the same clk_sdram cycle", t))
    m = re.search(r"^exit (-?\d+)$", t, re.M)
    r["exit"] = int(m.group(1)) if m else None
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
    if r["ports"] and r["ports"][3] and name != "ram7800":
        bad.append(f"the 7800/BIOS port issued {r['ports'][3]} writes of cartridge RAM in a 2600 run")
    if prof in ("base", "fixb"):
        normal, rep = BUCKETS[(prof, blend)]
        # the first read after each console reset release may also use POST[prof]
        post = r.get("post") or {}
        main = {k: v - post.get(k, 0) for k, v in r["hist"].items() if v - post.get(k, 0) > 0}
        extra = sorted(set(main) - normal - rep)
        if extra:
            bad.append(f"buckets {extra} outside {sorted(normal | rep)} ({prof}, blend {blend})")
        pextra = sorted(set(post) - normal - rep - {POST[prof]})
        if pextra:
            bad.append(f"post-reset reads in buckets {pextra} outside {sorted(normal | rep | {POST[prof]})} ({prof}, blend {blend})")
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
    # one Verilator for every build (plan 7.5): 5.040 unless VERILATOR names
    # another (run_sim.sh alone would take PATH's, which may be 5.020)
    if not env.get("VERILATOR"):
        v = "/opt/verilator-5.040/bin/verilator"
        env["VERILATOR"] = v if os.access(v, os.X_OK) else "verilator"
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
        p = subprocess.run([vtb] + args, cwd=run_dir, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        f.write(f"exit {p.returncode}\n".encode())


def images(a):
    d = os.path.join(a.work, "cartram", "img")
    os.makedirs(d, exist_ok=True)
    for m in MAPPERS:
        open(os.path.join(d, m + ".bin"), "wb").write(image(m))
    for m in ("f8sc", "e7"):
        open(os.path.join(d, "hi_" + m + ".bin"), "wb").write(image("hi_" + m))
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


# ------------------------------------------------------- console resets
# (name, image, extra plusargs, expectation): the reproduction of Fix B's
# review finding (plan P2 as amended). W runs the image for 400 ms; the
# resets start at 20 ms (30 for the Supercharger, 45 for hi_e7, whose first
# iteration over its two RAM areas, and so its first pass code, ends at about
# 37 ms: a reset every 3 ms restarts the program before it ends another one)
# and end the run.
RST_W = ["+arprobe", "+wav=400"]
RST_SW = ["+rssweep", "+rsn=24"]
RST_RUNS = [
    ("rst_hif8_rd_rst", "hi_f8sc", ["+rsmode=rd", "+rssrc=rst"] + RST_SW),
    ("rst_hif8_wr_rst", "hi_f8sc", ["+rsmode=wr", "+rssrc=rst"] + RST_SW),
    ("rst_hie7_rd_rst", "hi_e7", ["+rsstart=45", "+rsmode=rd", "+rssrc=rst"] + RST_SW),
    ("rst_hie7_wr_rst", "hi_e7", ["+rsstart=45", "+rsmode=wr", "+rssrc=rst"] + RST_SW),
    ("rst_ar_rst", "arfull", ["+rsstart=30", "+rsmode=ar", "+rssrc=rst"] + RST_SW),
    ("rst_hif8_rd_rst_b1", "hi_f8sc", ["+blend", "+rsmode=rd", "+rssrc=rst"] + RST_SW),
    # a reload with the bank-switch override set, so the mapper survives the
    # load's first edge (detect2600 clears force_bs and sc there)
    ("rst_hie7_rd_load", "hi_e7", ["+rsstart=45", "+rsmode=rd", "+rssrc=load"] + RST_SW),
    ("rst_hie7_wr_load", "hi_e7", ["+rsstart=45", "+rsmode=wr", "+rssrc=load"] + RST_SW),
    ("rst_ar_load", "arfull", ["+bs=15", "+rsstart=30", "+rsmode=ar", "+rssrc=load"] + RST_SW),
    # a reload with the mapper detected: at K = 0 the load clears it on E1 itself
    ("rst_hif8_rd_load_auto", "hi_f8sc", ["+rsmode=rd", "+rssrc=load"] + RST_SW),
    # the control: RAM at $1xxx (A15 = 0), where bios_sel stays low
    ("rst_lof8_wr_rst", "f8sc", ["+rsmode=wr", "+rssrc=rst"] + RST_SW),
    # K = 0, eight times each
    ("rst_hif8_rd_rst_k0", "hi_f8sc", ["+rsmode=rd", "+rssrc=rst", "+rsk0=0", "+rsn=8"]),
    ("rst_hie7_wr_load_k0", "hi_e7", ["+rsstart=45", "+rsmode=wr", "+rssrc=load", "+rsk0=0", "+rsn=8"]),
    ("rst_ar_rst_k0", "arfull", ["+rsstart=30", "+rsmode=ar", "+rssrc=rst", "+rsk0=0", "+rsn=8"]),
]


def reset_args(img, image_name, extra):
    base = image_name[3:] if image_name.startswith("hi_") else image_name
    args = [f"+image={img}/{image_name}.bin", "+cartram"] + RST_W
    if base in BS and BS[base] and not any(x.startswith("+bs=") for x in extra):
        args.append(f"+bs={BS[base]}")
    return args + list(extra)


def check_reset(log, run_name, image_name, profile="auto", ref=None):
    """One reset run's verdict: (ok, reasons, summary)."""
    r = parse(log)
    bad = []
    if r["fatal"]:
        bad.append("P2 assertion fired" if r["p2_fired"] else "simulator: " + r["fatal"][0][:120])
    if r["exit"] not in (0, None):
        bad.append(f"exit {r['exit']}")
    if r["rst_done"] is None or r["rst_done"][0] != r["rst_done"][1] or r["rst_incomplete"]:
        bad.append(f"resets incomplete ({r['rst_done'][0] if r['rst_done'] else len(r['rst'])} done)")
    rs = r["rst"]
    lost = [x for x in rs if not x["nos"] and not x["issued"]]
    if lost:
        bad.append("NOT issued at K=" + ",".join(str(x["k"]) for x in lost))
    nos = [x for x in rs if x["nos"]]
    if run_name.endswith("_auto"):
        if sorted(x["k"] for x in nos) != sorted(x["k"] for x in rs if x["k"] == 0):
            bad.append("no strobe at E1 at K=" + ",".join(str(x["k"]) for x in nos) + " (expected exactly at K=0)")
    elif nos:
        bad.append(f"{len(nos)} resets without a strobe at E1")
    # the strobe at E1 is the kind the run's mode asks for: a read in an rd
    # run, a write in a wr or ar run (a cycle search that drifts to the other
    # kind would test the wrong path unseen)
    want_kind = {"rd": "read", "wr": "write", "ar": "write"}.get(r["rst_mode"])
    if r["rst"] and want_kind is None:
        bad.append(f"no run mode in the RST armed line (mode {r['rst_mode']})")
    elif want_kind:
        wk = [x for x in rs if not x["nos"] and not x["strobe"].startswith(want_kind + " ")]
        if wk:
            bad.append(f"{len(wk)} resets saw a strobe of the other kind than mode {r['rst_mode']}'s ({want_kind}) "
                       f"at K=" + ",".join(str(x["k"]) for x in wk))
    wd = [x for x in rs if x["issued"] and x["data"] is not None and not x["strobe"].endswith("data " + x["data"])]
    if wd:
        bad.append(f"{len(wd)} writes issued with another byte than the strobe's")
    late = [x for x in rs if x["issued"] and x["data"] is None and x["edge"] + 6 > LIMIT]
    if late:
        bad.append(f"a read issued after s{LIMIT - 6} (c_rdata after s{LIMIT}) at K=" +
                   ",".join(f"{x['k']} (s{x['edge']})" for x in late))
    co = sum(x["coinc"] for x in rs)
    if co:
        bad.append(f"{co} m_new/t_new coincidences")
    # the matrix's monitor checks (a mapper image's pass and fail codes too); the
    # counts are the resets' own
    base = image_name[3:] if image_name.startswith("hi_") else image_name
    ok_m, bad_m, summ = check(log, base if base in MAPPERS else "reset", 1 if "_b1" in run_name else 0,
                              profile, expect_counts=False)
    bad += [b for b in bad_m if not b.startswith("simulator")]
    if ref is not None:
        if not os.path.exists(ref):
            bad.append(f"no reference log {ref}")
        else:
            rr = {x["i"]: x for x in parse(ref)["rst"]}
            cd = [x for x in rs if x["i"] in rr and sorted(x["cart"]) != sorted(rr[x["i"]]["cart"])]
            sd = [x for x in rs if x["i"] in rr and x["strobe"] != rr[x["i"]]["strobe"]]
            if sd:
                bad.append(f"{len(sd)} resets saw another strobe than the reference build")
            if cd:
                bad.append("cartridge accesses differ from the reference build's at K=" + ",".join(str(x["k"]) for x in cd))
    edges = sorted({x["edge"] for x in rs if x["issued"]})
    summ = (f"{sum(1 for x in rs if x['issued'])}/{len(rs)} issued at " + ",".join(f"s{e}" for e in edges) +
            f"; {summ}")
    return not bad, bad, summ


def mutant_tree(a, name):
    """A copy of the tree's tracked src/fpga in WORK/mut_NAME with sram_ctrl.sv
    mutated; returns the mutant's own work directory (also its RTL tree)."""
    if name not in MUTANTS:
        print(f"unknown mutant {name}: {', '.join(MUTANTS)}", file=sys.stderr)
        sys.exit(2)
    tree = os.path.abspath(a.rtl_tree) if a.rtl_tree else os.path.dirname(HERE)
    d = os.path.join(a.work, "mut_" + name)
    files = subprocess.run(["git", "-C", tree, "ls-files", "src/fpga"], capture_output=True, text=True, check=True).stdout.split()
    for f in files:
        dst = os.path.join(d, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(tree, f), dst)
    p = os.path.join(d, "src", "fpga", "core", "sram_ctrl.sv")
    t = open(p).read()
    old, new = MUTANTS[name]
    if t.count(old) != 1:
        print(f"mutant {name}: its line is not in {p} once", file=sys.stderr)
        sys.exit(2)
    open(p, "w").write(t.replace(old, new))
    print(f"-- mutant {name}: sram_ctrl.sv mutated in {d}")
    return d


def mutant_setup(a):
    """--mutant: run in the mutant's own work directory, built from its tree."""
    if not getattr(a, "mutant", None):
        return
    a.work = mutant_tree(a, a.mutant)
    a.rtl_tree = a.work
    # built once per mutant work directory (again with --build)
    a.build = a.build or not os.path.exists(os.path.join(a.work, "obj_cartram", "vtb"))


def mutant_verdict(a, rc, tag):
    if not getattr(a, "mutant", None):
        return rc
    caught = rc != 0
    print(f"MUTANT {a.mutant} {tag}: {'CAUGHT' if caught else 'NOT CAUGHT'}")
    return 0 if caught else 1


def cmd_reset(a):
    if a.build:
        build(a)
    header(a)
    img = images(a)
    logs = os.path.join(a.work, "cartram", "logs")
    os.makedirs(logs, exist_ok=True)
    only = set(a.only.split(",")) if a.only else None
    ok_all = True
    for name, image_name, extra in RST_RUNS:
        if only and name not in only:
            continue
        log = os.path.join(logs, name + ".log")
        run(a, name, reset_args(img, image_name, extra), log)
        ref = os.path.join(a.ref_logs, name + ".log") if a.ref_logs else None
        ok, bad, summ = check_reset(log, name, image_name, a.profile, ref)
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} {name}: {summ}" + ("" if ok else "  <- " + "; ".join(bad)))
        sys.stdout.flush()
    print(f"CARTRAM_RESET {'pass' if ok_all else 'FAIL'}")
    return 0 if ok_all else 1


def cmd_midswap(a):
    if a.build:
        build(a)
    header(a)
    img = images(a)
    logs = os.path.join(a.work, "cartram", "logs")
    os.makedirs(logs, exist_ok=True)
    log = os.path.join(logs, "midswap_f8sc.log")
    run(a, "f8sc", [f"+image={img}/f8sc.bin", "+arprobe", "+cartram", "+wav=60", "+midswap=20"], log)
    r = parse(log)
    bad = []
    if r["fatal"]:
        bad.append("simulator: " + r["fatal"][0][:120])
    if r["midswap"] is None:
        bad.append("no MIDSWAP verdict (not a Fix B build, or no held read strobe)")
    elif not r["midswap"].startswith("new key served"):
        bad.append("MIDSWAP: " + r["midswap"])
    ok = not bad
    print(f"{'PASS' if ok else 'FAIL'} midswap f8sc: accesses for the new key / the old key "
          f"{r['midswap_n'] if r['midswap_n'] else '-'}" + ("" if ok else "  <- " + "; ".join(bad)))
    print(f"CARTRAM_MIDSWAP {'pass' if ok else 'FAIL'}")
    return 0 if ok else 1


def cmd_forcecoinc(a):
    if a.build:
        build(a)
    header(a)
    img = images(a)
    logs = os.path.join(a.work, "cartram", "logs")
    os.makedirs(logs, exist_ok=True)
    ok_all = True
    modes = a.modes.split(",")
    for mode in modes:
        log = os.path.join(logs, f"forcecoinc_{mode}.log")
        run(a, "e7", [f"+image={img}/e7.bin", "+arprobe", "+cartram", "+wav=60", f"+bs={BS['e7']}",
                      f"+forcecoinc={mode}"], log)
        r = parse(log)
        bad = []
        fc = r["forcecoinc"]
        if mode == "c_rd":
            # m_new yields: no coincidence, the 2600 accesses served as always
            ok_m, bad_m, summ = check(log, "e7", 0, a.profile, expect_counts=True)
            bad += bad_m
            if fc is None or fc[0] == 0:
                bad.append("no 7800 strobe forced (no FORCECOINC line, or none in 2600 mode)")
        else:
            # the assertion must fire
            summ = "the P2 assertion " + ("fired" if r["p2_fired"] else "did not fire")
            if not r["p2_fired"]:
                bad.append("m_new forced beside t_new, and the P2 assertion did not fire")
        ok = not bad
        ok_all &= ok
        print(f"{'PASS' if ok else 'FAIL'} forcecoinc {mode}: {summ}" + ("" if ok else "  <- " + "; ".join(bad)))
        sys.stdout.flush()
    print(f"CARTRAM_FORCECOINC {'pass' if ok_all else 'FAIL'}")
    return 0 if ok_all else 1


def main():
    if len(sys.argv) == 2 and (sys.argv[1] in MAPPERS or (sys.argv[1].startswith("hi_") and sys.argv[1][3:] in MAPPERS)):
        sys.stdout.buffer.write(image(sys.argv[1]))
        print(BS[sys.argv[1].replace("hi_", "")], file=sys.stderr)
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
    c = sub.add_parser("check-reset")
    c.add_argument("log")
    c.add_argument("--run", required=True, choices=[x[0] for x in RST_RUNS])
    c.add_argument("--profile", default="auto", choices=("auto", "base", "fixb"))
    c.add_argument("--ref", help="the reference build's log of the same run (per-reset accesses)")
    for name in ("matrix", "s19", "reset", "midswap", "forcecoinc"):
        s = sub.add_parser(name)
        s.add_argument("--work", default=os.environ.get("WORK", os.path.join(HERE, "work")))
        s.add_argument("--build", action="store_true")
        s.add_argument("--rtl-tree")
        s.add_argument("--profile", default="auto", choices=("auto", "base", "fixb"))
        s.add_argument("--fp", action="store_true", help="tb_load +fp fingerprints to WORK/fp/cartram_<case>.csv")
        s.add_argument("--mutant", choices=sorted(MUTANTS),
                       help="build and run a mutant of sram_ctrl.sv in WORK/mut_NAME: exit 0 when CAUGHT")
        if name == "matrix":
            s.add_argument("--only")
            s.add_argument("--arfw", help="the Supercharger BIOS: adds the full load from tape (artape, 22 s)")
            s.add_argument("--ref-logs", help="the reference build's cartram/logs (artape's colours)")
        elif name == "s19":
            s.add_argument("--images", default="e7")
        elif name == "reset":
            s.add_argument("--only", help="RUN,...: " + ",".join(x[0] for x in RST_RUNS))
            s.add_argument("--ref-logs", help="another build's cartram/logs (aeee6d2's): per-reset accesses must equal")
        elif name == "forcecoinc":
            s.add_argument("--modes", default="c_rd,m_new")
    a = p.parse_args()
    if a.cmd == "check":
        ok, bad, summ = check(a.log, a.image, a.blend, a.profile, not a.no_counts, ref=a.ref)
        print(f"{'PASS' if ok else 'FAIL'} {a.image} blend {a.blend}: {summ}" + ("" if ok else "  <- " + "; ".join(bad)))
        return 0 if ok else 1
    if a.cmd == "check-reset":
        image_name = {x[0]: x[1] for x in RST_RUNS}[a.run]
        ok, bad, summ = check_reset(a.log, a.run, image_name, a.profile, a.ref)
        print(f"{'PASS' if ok else 'FAIL'} {a.run}: {summ}" + ("" if ok else "  <- " + "; ".join(bad)))
        return 0 if ok else 1
    a.work = os.path.abspath(a.work)
    if getattr(a, "ref_logs", None):
        a.ref_logs = os.path.abspath(a.ref_logs)
    mutant_setup(a)
    if not a.build and not os.path.exists(os.path.join(a.work, "obj_cartram", "vtb")):
        print("no obj_cartram/vtb in --work: add --build", file=sys.stderr)
        return 2
    fn = {"matrix": cmd_matrix, "s19": cmd_s19, "reset": cmd_reset, "midswap": cmd_midswap,
          "forcecoinc": cmd_forcecoinc}[a.cmd]
    return mutant_verdict(a, fn(a), a.cmd)


if __name__ == "__main__":
    sys.exit(main())
