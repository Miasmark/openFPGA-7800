#!/usr/bin/env python3
"""Planted faults: each checker must pass a good input and fail each fault
(DARIA step 7, docs/daria_step7/plan.md 3.6 unit gate 1, 7.1 and 7.2 for I4).

  selftest.py --work DIR [--run-sim LOG] [--extra LOG --extra-ref REF
              [--extra-dir DIR]] [--fp FILE] [--cartram LOG] [--tools]

DIR receives the planted copies. Every case prints "ok" when the checker
gave the expected verdict, "WRONG" otherwise; the last line is SELFTEST
pass or FAIL, and so is the exit status (0 or 1).
  --run-sim LOG    a passing run_sim.sh log: wrong TONE ratio, BIOS_BOOT
                   FAIL, a skipped section, a missing PLL_REGION line, a
                   truncated log, a geometry change
  --extra LOG      a passing extra_tests.sh log, with its reference log
                   (--extra-ref) and, for a log from before step 7, its
                   extra/ directory (--extra-dir): an ARCHECK mismatch, a
                   POKEY statistic changed, a multisprite row shift (on a
                   copy of the frames), a SaveKey byte lost, the multiload
                   out of order; with AR_TAPE=1 in the log, the tape
                   multiload's second load and the tape full load's ARCHECK
  --fp FILE        a tb_load/tb_system fp.csv: frame_gate --strict on a
                   truncated copy, a one-frame shift, one RIOT hash, one
                   pixel (video) hash and a one-clock len_sys change
  --cartram LOG    a passing tb_cartram log (cartram2600_test.py's, E7 blend
                   off): a wrong byte, a lost write, a bucket past s19, a
                   changed read count, a fail code, a P2 $fatal; and a Fix B
                   log made from it, which passes with the P2 assertion armed
                   and fails without it (also with --profile fixb)
  --artape LOG     a passing artape log (the tape load with +cartram), with
                   --artape-ref the reference build's: an ARCHECK mismatch,
                   no tone 5 after the tape, another colour than the
                   reference's
  --tools          the guards on scratch git repositories in DIR:
                   pp_guards.py (a directive in an added comment, an
                   attribute in a comment, a .vhd and a .mif change, an extra
                   and a missing DARIA qsf line, an SDC code change; and the
                   changes it must let through), hygiene.sh (a cartridge
                   image, a PNG, a firmware file, a path into the temporary
                   directory, a listed name, no list, a list inside the
                   repository, a binary and an oversized file) and
                   pp_equiv.py on a small Quartus tree (a comment, a layout
                   and a dead-ifdef edit keep the hash; a code edit, a live
                   ifdef edit and a removed macro change it; --expect and
                   --max-token fail); needs git and VERILATOR
  always           frame_gate on synthetic R1/R2 run directories: identical;
                   a release_shift that is excused; one that lasts too long;
                   a RIOT difference with no shifted release; a video, a
                   len_sys and a cpu difference; a truncated file; a call
                   count and a late-call difference; the STATUS line's halts,
                   PSRAM violations, guard and unlocks; Spiders' excused
                   overrun frames, and the same frames when later ones differ
SPDX-License-Identifier: MIT
"""
import argparse
import os
import random
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.dirname(HERE)
results = []


def run(cmd, py=True, env=None):
    r = subprocess.run(([sys.executable] if py else []) + cmd, capture_output=True, text=True, env=env)
    crashed = "Traceback (most recent call last)" in r.stderr
    return (2 if crashed else r.returncode), r.stdout + (r.stderr if r.returncode not in (0, 1) or crashed else "")


def expect(name, cmd, want_pass, py=True, env=None):
    # a checker that crashes (a Python traceback) gives no verdict: WRONG,
    # whatever its exit status
    rc, out = run(cmd, py, env)
    ok = (rc == 0) == want_pass and rc in (0, 1)
    results.append(ok)
    last = out.strip().splitlines()[-1] if out.strip() else "(no output)"
    print(f"  {'ok   ' if ok else 'WRONG'} {name}: expected {'pass' if want_pass else 'fail'}, got rc {rc} ({last})")
    if not ok:
        print("\n".join("        " + l for l in out.splitlines()[-12:]))


def plant(src, dst, fn):
    t = open(src, "rb").read().decode("utf-8", "replace")
    t2 = fn(t)
    if t2 == t:
        raise SystemExit(f"selftest: the fault for {dst} changed nothing")
    open(dst, "w").write(t2)
    return dst


def sub1(pat, rep):
    return lambda t: re.sub(pat, rep, t, count=1, flags=re.M)


def run_sim_cases(log, w):
    chk = os.path.join(HERE, "run_sim_check.py")
    print("run_sim_check.py:")
    expect("the log as it is", [chk, log], True)
    cases = {
        "tone_ratio": sub1(r"^(TONE AUDC0=4 AUDF0=7: .* ratio )[0-9.]+$", r"\g<1>0.500"),
        "bios_fail": sub1(r"^BIOS_BOOT pass$", "BIOS_BOOT FAIL"),
        "skipped": lambda t: re.sub(r"^-- 7800 BIOS loaded.*?^BIOS_BOOT pass\n",
                                    "-- 7800 BIOS boot rule: skipped (no BIOS image at x; set BIOS=FILE)\n", t, flags=re.M | re.S),
        "no_pll_region": sub1(r"^PLL_REGION pass \(0 errors\)\n", ""),
        "truncated": lambda t: t[:len(t) // 2],
        "geometry": sub1(r"^(  \+overscan: 238804 clk_sys \(59\.958 Hz\), active lines )242", r"\g<1>241"),
        "bupchip_fail": sub1(r"^BUPCHIP_E2E pass$", "BUPCHIP_E2E FAIL"),
        # a case cut short: an earlier FRAME line with the right geometry
        "frame_number_border": sub1(r"^FRAME 17(: 238804 clk_sys \(59\.958 Hz\), active lines 224, active pixels/line 320)",
                                    r"FRAME 9\g<1>"),
        "frame_number_pal2600": sub1(r"^FRAME 75(: 284544)", r"FRAME 74\g<1>"),
        # a bench that exited non-zero in a piped case (its %Fatal line went
        # to grep): run_sim.sh's sim prints this line past the pipe
        "simulator_exit": sub1(r"^(-- border hidden:\n)", r"\g<1>SIMULATOR EXIT 1: ./obj/vtb +audf=0 +hide_border\n"),
    }
    for k, fn in cases.items():
        expect(k, [chk, plant(log, os.path.join(w, f"run_sim_{k}.log"), fn)], False)


def extra_cases(log, ref, xdir, w):
    chk = os.path.join(HERE, "extra_tests_check.py")
    base = [chk, log, "--ref", ref] + (["--extra-dir", xdir] if xdir else [])
    print("extra_tests_check.py:")
    expect("the log as it is", base, True)
    cases = {
        "archeck": sub1(r"^(ARCHECK 24 pages, )0( of 6144)", r"\g<1>3\g<2>"),
        "pokey_stat": sub1(r"^(  t=0\.50s min=\d+ max=)(\d+)", lambda m: m.group(1) + str(int(m.group(2)) + 1)),
        "savekey_lost": sub1(r"^SAVEKEY EEPROM \$1234\.\.\$123B in the save RAM: a5 5a", "SAVEKEY EEPROM $1234..$123B in the save RAM: a5 00"),
        "multiload_order": lambda t: t.replace("AUDF0 = 14\n", "AUDF0 = 13\n", 1),
        "no_ref": None,
    }
    if "With the BIOS, from tape" in open(log, errors="replace").read():
        last = lambda a, b: (lambda t: t[::-1].replace(a[::-1], b[::-1], 1)[::-1])
        cases["tape_multiload_tone"] = last("AUDF0 = 14\n", "AUDF0 = 13\n")
        cases["tape_archeck"] = last("ARCHECK 24 pages, 0 of", "ARCHECK 24 pages, 9 of")
    for k, fn in cases.items():
        if fn is None:
            expect(k, [chk, log] + (["--extra-dir", xdir] if xdir else []), False)
            continue
        expect(k, [chk, plant(log, os.path.join(w, f"extra_{k}.log"), fn), "--ref", ref]
               + (["--extra-dir", xdir] if xdir else []), False)
    # the multisprite rule on a copy of the frames with one sprite row shifted
    if xdir:
        from PIL import Image
        src = os.path.join(xdir, "multisprite")
        dst = os.path.join(w, "extra_ms", "multisprite")
        shutil.rmtree(os.path.join(w, "extra_ms"), ignore_errors=True)
        os.makedirs(os.path.join(dst, "gfx"))
        shutil.copy(os.path.join(src, "frame_001.ppm"), dst)
        shutil.copy(os.path.join(src, "gfx", "herodown1.png"), os.path.join(dst, "gfx"))
        im = Image.open(os.path.join(src, "frame_002.ppm")).convert("RGB")
        bg = Image.open(os.path.join(src, "frame_001.ppm")).convert("RGB")
        px, bp = im.load(), bg.load()
        w_, h_ = im.size
        rows = [y for y in range(h_) if sum(1 for x in range(w_) if px[x, y] != bp[x, y]) > 8]
        y = rows[len(rows) // 2]
        xs = [x for x in range(w_) if px[x, y] != bp[x, y]]
        seg = [px[x, y] for x in range(xs[0], xs[0] + 32)]
        for i, x in enumerate(range(xs[0] + 2, xs[0] + 34)):
            if x < w_:
                px[x, y] = seg[i]
        im.save(os.path.join(dst, "frame_002.ppm"))
        log2 = plant(log, os.path.join(w, "extra_ms.log"), lambda t: t.replace("MULTISPRITE pass\n", ""))  \
            if "MULTISPRITE pass" in open(log, errors="replace").read() else log
        expect("multisprite_row_shift", [chk, log2, "--ref", ref, "--extra-dir", os.path.join(w, "extra_ms")], False)
        expect("multisprite_row_shift (multisprite_check.py)", [os.path.join(HERE, "multisprite_check.py"), dst], False)


def fp_rows(path):
    lines = open(path).read().splitlines()
    return lines[0], [l.split(",") for l in lines[1:]]


def write_fp(path, head, rows):
    open(path, "w").write(head + "\n" + "".join(",".join(r) + "\n" for r in rows))


def fp_cases(fp, w):
    fg = os.path.join(HERE, "frame_gate.py")
    head, rows = fp_rows(fp)
    n = len(rows)
    print(f"frame_gate.py --strict on {fp} ({n} frames):")
    expect("identical copy", [fg, "--strict", fp, fp], True)
    k = n // 2
    cols = head.split(",")

    def changed(col, f):
        r = [list(x) for x in rows]
        i = cols.index(col)
        r[f][i] = str(int(r[f][i]) + 1) if col == "len_sys" else format(int(r[f][i], 16) ^ 1, "016x")
        return r

    def later(col):
        # the whole run one clk_sys later in an absolute-time column
        r = [list(x) for x in rows]
        i = cols.index(col)
        for x in r:
            x[i] = str(int(x[i]) + 1)
        return r
    cases = {
        "truncated": rows[:-1],
        "truncated_line": [list(x) for x in rows[:-1]] + [rows[-1][:3]],
        "one_frame_shift": [[str(i + 1)] + rows[i + 1][1:] for i in range(n - 1)] + [[str(n)] + rows[0][1:]],
        "riot_hash": changed("riot", k),
        "pixel_hash": changed("video", k),
        "len_sys_one_clock": changed("len_sys", k),
    }
    if "rst_sys" in cols:
        # a run shifted as a whole (every hash restarts with the reset), and
        # the console's reset released one clock later (plan P6)
        cases["t_sys_whole_run_one_clock_later"] = later("t_sys")
        cases["rst_sys_release_one_clock_later"] = later("rst_sys")
        rn = [list(x) for x in rows]
        rn[-1][cols.index("rst_n")] = str(int(rn[-1][cols.index("rst_n")]) + 1)
        cases["rst_n_one_more_release"] = rn
    for c, r in cases.items():
        p = os.path.join(w, f"fp_{c}.csv")
        write_fp(p, head, r)
        expect(c, [fg, "--strict", fp, p], False)
    if "rst_sys" in cols:
        # the same frames without the absolute-time columns (a fingerprint of
        # the bench before they existed): the columns differ
        p = os.path.join(w, "fp_without_time_columns.csv")
        keep = [i for i, c in enumerate(cols) if c not in ("t_sys", "rst_n", "rst_sys")]
        write_fp(p, ",".join(cols[i] for i in keep), [[x[i] for i in keep] for x in rows])
        expect("without_time_columns", [fg, "--strict", fp, p], False)
    # two empty files, and two with only the header: no frame is no pass
    e1, e2 = os.path.join(w, "fp_empty_a.csv"), os.path.join(w, "fp_empty_b.csv")
    open(e1, "w").close()
    open(e2, "w").close()
    expect("two zero-byte files", [fg, "--strict", e1, e2], False)
    h1, h2 = os.path.join(w, "fp_header_a.csv"), os.path.join(w, "fp_header_b.csv")
    write_fp(h1, head, [])
    write_fp(h2, head, [])
    expect("two header-only files", [fg, "--strict", h1, h2], False)


def cartram_cases(log, w):
    ct = os.path.join(SIM, "cartram2600_test.py")
    print("cartram2600_test.py check:")
    expect("E7 blend off as it is", [ct, "check", log, "--image", "e7", "--blend", "0"], True)
    cases = {
        "wrong_byte": sub1(r"(CPU reads of cart RAM, )0( wrong byte)", r"\g<1>1\g<2>"),
        "lost_write": sub1(r"(\d+)( cart writes issued)", lambda m: str(int(m.group(1)) - 1) + m.group(2)),
        "past_s19": sub1(r"^(CARTRAM latency histogram \(clk_sdram from E0: count\):.*)$", r"\g<1> 20:1"),
        "read_count": sub1(r"^CARTRAM reads: (\d+)", lambda m: "CARTRAM reads: " + str(int(m.group(1)) + 1)),
        "fail_code": lambda t: t + "AR 70 ms: AUDF0 = 3\n",
        "p2_fatal": lambda t: t + "[41000000] %Fatal: tb_load.sv:263: Assertion failed in tb_cartram.tb: "
                                  "P2: sram_ctrl m_new and t_new in the same clk_sdram cycle at 41.000 us\n",
    }
    for c, fn in cases.items():
        expect(c, [ct, "check", plant(log, os.path.join(w, f"cartram_{c}.log"), fn), "--image", "e7", "--blend", "0"], False)
    # The fixb profile needs the P2 assertion armed. From this log, a Fix B
    # one: the sram_ctrl line, Fix B's buckets (15 normal, 11 repeated) and
    # the "P2 armed" line; it must pass, and fail without the P2 line, also
    # with --profile fixb given explicitly.
    def as_fixb(t):
        t = re.sub(r"^CARTRAM sram_ctrl: .*$", "CARTRAM sram_ctrl: Fix B (the 2600 request registered on clk_sys, t_new)", t,
                   count=1, flags=re.M)
        t = re.sub(r"^(CARTRAM latency histogram \(clk_sdram from E0: count\):).*$",
                   lambda m: m.group(1) + " 11:" + str(sum(v for k, v in parse_hist(log).items() if k in (7, 9))) +
                   " 15:" + str(sum(v for k, v in parse_hist(log).items() if k not in (7, 9))), t, count=1, flags=re.M)
        t = re.sub(r"c_rdata at E0\+(-?\d+)\.\.(-?\d+) clk_sdram", "c_rdata at E0+11..15 clk_sdram", t, count=1)
        return ("P2 armed: sram_ctrl m_new and t_new checked on every clk_sdram\n" +
                t.replace("P2 armed: sram_ctrl m_new and t_new checked on every clk_sdram\n", ""))
    fx = plant(log, os.path.join(w, "cartram_fixb.log"), as_fixb)
    expect("a Fix B log (synthetic, from this one)", [ct, "check", fx, "--image", "e7", "--blend", "0"], True)
    nop2 = plant(fx, os.path.join(w, "cartram_fixb_no_p2.log"), lambda t: t.replace("P2 armed: sram_ctrl m_new and t_new checked on every clk_sdram\n", ""))
    expect("Fix B buckets with the P2 assertion not armed", [ct, "check", nop2, "--image", "e7", "--blend", "0"], False)
    expect("the same with --profile fixb", [ct, "check", nop2, "--image", "e7", "--blend", "0", "--profile", "fixb"], False)


def parse_hist(log):
    m = re.search(r"^CARTRAM latency histogram \(clk_sdram from E0: count\):(.*)$", open(log, errors="replace").read(), re.M)
    return {int(a): int(b) for a, b in re.findall(r"(\d+):(\d+)", m.group(1))} if m else {}


def artape_cases(log, ref, w):
    """The Supercharger tape load with +cartram (cartram2600_test.py's artape)."""
    ct = os.path.join(SIM, "cartram2600_test.py")
    print("cartram2600_test.py check, artape:")
    base = [ct, "check", log, "--image", "artape"] + (["--ref", ref] if ref else [])
    expect("artape as it is", base, True)
    last = lambda a, b: (lambda t: t[::-1].replace(a[::-1], b[::-1], 1)[::-1])
    cases = {
        "artape_archeck": sub1(r"^(ARCHECK 24 pages, )0( of 6144)", r"\g<1>5\g<2>"),
        "artape_no_tone_5_after_the_tape": last("AUDF0 = 5\n", "AUDF0 = 6\n"),
    }
    for c, fn in cases.items():
        expect(c, [ct, "check", plant(log, os.path.join(w, f"{c}.log"), fn), "--image", "artape"]
               + (["--ref", ref] if ref else []), False)
    # another colour than the reference build's
    col = plant(log, os.path.join(w, "artape_colour.log"), sub1(r"^(AR \d+ ms: COLUBK = \$)([0-9a-f]{2})$",
                                                               lambda m: m.group(1) + ("54" if m.group(2) != "54" else "0e")))
    expect("artape_colour_differs_from_the_reference", [ct, "check", col, "--image", "artape", "--ref", ref or log], False)


# ---------------------------------------------------------------- the guards (--tools)
def git_repo(d):
    """A scratch git repository at d with one commit 'base'; returns a helper."""
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    env = dict(os.environ, GIT_AUTHOR_NAME="selftest", GIT_AUTHOR_EMAIL="selftest@localhost",
               GIT_COMMITTER_NAME="selftest", GIT_COMMITTER_EMAIL="selftest@localhost")

    def g(*a):
        return subprocess.run(["git", "-C", d] + list(a), capture_output=True, text=True, check=True, env=env).stdout
    g("init", "-q")
    return g


def write(d, rel, text, mode="w"):
    p = os.path.join(d, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, mode) as f:
        f.write(text)


QSF = """# test project
set_global_assignment -name VERILOG_MACRO "POCKET_SRAM=1"
set_global_assignment -name QIP_FILE core/core.qip
set_global_assignment -name SDC_FILE core/core_constraints.sdc
set_global_assignment -name SEED 1
"""
SV_A = """// a.sv: test module
module a(input logic clk, output logic q);
	// a comment
	always_ff @(posedge clk) q <= ~q;
`ifdef POCKET_SRAM
	logic live;
`endif
`ifdef SOMETHING_ELSE
	logic dead;
`endif
endmodule
"""
SV_B = """module b(input logic d, output logic e);
	assign e = d;
endmodule
"""
QIP = """set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) a.sv ]
set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) b.sv ]
"""
SDC = """# clocks
create_clock -name clk -period 69.841 [get_ports clk]
"""


def tree(d):
    write(d, "src/fpga/ap_core.qsf", QSF)
    write(d, "src/fpga/core/core.qip", QIP)
    write(d, "src/fpga/core/a.sv", SV_A)
    write(d, "src/fpga/core/b.sv", SV_B)
    write(d, "src/fpga/core/core_constraints.sdc", SDC)
    write(d, "src/fpga/mister/rtl/dpram.vhd", "-- vhdl\nentity dpram is end;\n")
    write(d, "src/fpga/apf/build_id.mif", "DEPTH = 1;\n")


def guard_cases(w):
    pg = os.path.join(SIM, "tools", "pp_guards.py")
    d = os.path.join(w, "guards_repo")
    g = git_repo(d)
    tree(d)
    g("add", "-A")
    g("commit", "-q", "-m", "base")
    g("tag", "base")
    print("pp_guards.py on a scratch repository:")
    edit = lambda rel, old, new: write(d, rel, open(os.path.join(d, rel)).read().replace(old, new, 1))
    daria3 = ('set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"\n'
              'set_global_assignment -name QIP_FILE core/daria.qip\n'
              'set_global_assignment -name SDC_FILE core/daria_constraints.sdc\n')
    cases = [
        ("comment only", "comments", lambda: edit("src/fpga/core/a.sv", "// a comment", "// another comment"), True),
        ("SDC comment only", "comments", lambda: edit("src/fpga/core/core_constraints.sdc", "# clocks", "# the clocks"), True),
        ("the three DARIA qsf lines, SEED and a comment", "daria",
         lambda: write(d, "src/fpga/ap_core.qsf", QSF.replace("SEED 1", "SEED 2").replace("# test project", "# seed 2 chosen") + daria3), True),
        ("directive in an added comment", "comments", lambda: edit("src/fpga/core/a.sv", "// a comment", "// synthesis translate_off"), False),
        ("attribute inside a comment", "comments", lambda: edit("src/fpga/core/a.sv", "// a comment", "/* (* keep *) */"), False),
        ("altera_attribute in a comment", "comments", lambda: edit("src/fpga/core/b.sv", "assign e = d;", "assign e = d; // altera_attribute -name X"), False),
        (".vhd change", "comments", lambda: edit("src/fpga/mister/rtl/dpram.vhd", "-- vhdl", "-- vhdl changed"), False),
        (".mif change", "comments", lambda: edit("src/fpga/apf/build_id.mif", "DEPTH = 1;", "DEPTH = 2;"), False),
        ("an extra qsf line", "daria", lambda: write(d, "src/fpga/ap_core.qsf", QSF + daria3 + 'set_global_assignment -name VERILOG_MACRO "X=1"\n'), False),
        ("a DARIA qsf line missing", "daria", lambda: write(d, "src/fpga/ap_core.qsf", QSF + daria3.split("\n", 1)[1]), False),
        ("an SDC code change", "comments", lambda: edit("src/fpga/core/core_constraints.sdc", "69.841", "69.000"), False),
        ("a qsf code change", "comments", lambda: edit("src/fpga/ap_core.qsf", "SEED 1", "SEED 3"), False),
    ]
    for name, q, fn, want in cases:
        g("checkout", "-q", "-f", "base")
        fn()
        g("add", "-A")
        g("commit", "-q", "-m", name)
        expect(name, [pg, "--repo", d, "--from", "base", "--to", "HEAD", "--qsf", q], want)
        g("checkout", "-q", "-f", "base")


def hygiene_cases(w):
    hy = os.path.join(HERE, "hygiene.sh")
    d = os.path.join(w, "hygiene_repo")
    g = git_repo(d)
    write(d, "README", "test\n")
    g("add", "-A")
    g("commit", "-q", "-m", "base")
    g("tag", "base")
    # a made-up name stands in for the real list, which is never written in a tracked file
    names = os.path.join(w, "hygiene_names.txt")
    open(names, "w").write("# test list\nQuuxbot\n")
    env = {k: v for k, v in os.environ.items() if k != "HYGIENE_NAMES"}
    print("hygiene.sh on a scratch repository:")
    tmp = "/" + "tmp/x.log"          # spelled in pieces: hygiene.sh would flag this file
    big = "".join("%07d\n" % i for i in range(40000))
    cases = [
        ("clean change", lambda: write(d, "sim/x.py", "print('ok')\n"), True, ["--names", names]),
        ("cartridge image", lambda: write(d, "sim/game.a26", "x" * 64), False, ["--names", names]),
        ("PNG", lambda: write(d, "docs/shot.png", "x" * 64), False, ["--names", names]),
        ("user firmware", lambda: write(d, "src/fpga/mister/rtl/bupchip.hex", "00\n"), False, ["--names", names]),
        ("path into the temporary directory", lambda: write(d, "sim/x.sh", "cat " + tmp + "\n"), False, ["--names", names]),
        ("scratch directory", lambda: write(d, "sim/x.sh", "see scratch" + "pad/notes\n"), False, ["--names", names]),
        ("listed name", lambda: write(d, "docs/x.md", "written with quuxbot\n"), False, ["--names", names]),
        ("no name list", lambda: write(d, "sim/x.py", "print('ok')\n"), False, []),
        ("name list inside the repository", lambda: (write(d, "names.txt", "Quuxbot\n"), write(d, "sim/x.py", "1\n")), False,
         ["--names", os.path.join(d, "names.txt")]),
        ("binary file", lambda: write(d, "sim/blob.dat", bytes(range(256)) * 4, "wb"), False, ["--names", names]),
        ("file over the size limit", lambda: write(d, "sim/big.txt", big), False, ["--names", names]),
    ]
    for name, fn, want, extra in cases:
        g("checkout", "-q", "-f", "base")
        fn()
        g("add", "-A")
        g("commit", "-q", "-m", name)
        expect(name, ["bash", hy, "--repo", d, "--base", "base"] + extra, want, py=False, env=env)
        g("checkout", "-q", "-f", "base")
    shutil.rmtree(d, ignore_errors=True)


def pp_equiv_cases(w):
    pe = os.path.join(SIM, "tools", "pp_equiv.py")
    d = os.path.join(w, "pp_tree")
    shutil.rmtree(d, ignore_errors=True)
    tree(d)
    fpga = os.path.join(d, "src", "fpga")

    def h(*extra):
        rc, out = run([pe, fpga, os.path.join(w, "pp_out")] + list(extra))
        m = re.match(r"([0-9a-f]{64}) ", out)
        return m.group(1) if m else None
    print("pp_equiv.py on a small Quartus tree:")
    h0 = h()
    results.append(h0 is not None)
    print(f"  {'ok   ' if h0 else 'WRONG'} base hash {h0}")
    edit = lambda rel, old, new: write(fpga, rel, open(os.path.join(fpga, rel)).read().replace(old, new, 1))

    def same(name, fn, want_same, *extra):
        keep = {r: open(os.path.join(fpga, r)).read() for r in ("core/a.sv", "core/b.sv", "ap_core.qsf")}
        fn()
        h1 = h(*extra)
        ok = h1 is not None and (h1 == h0) == want_same
        results.append(ok)
        print(f"  {'ok   ' if ok else 'WRONG'} {name}: hash {'unchanged' if h1 == h0 else 'changed'}, expected "
              f"{'unchanged' if want_same else 'changed'}")
        for r, v in keep.items():
            write(fpga, r, v)
    same("comment edit", lambda: edit("core/a.sv", "// a comment", "// a different comment"), True)
    same("spacing and blank lines", lambda: edit("core/b.sv", "assign e = d;", "\n\n  assign   e\t=  d;   \n"), True)
    # a statement split over two lines changes the stream: line breaks are kept
    # (conservative: a false difference, never a false identity)
    same("a statement split over two lines", lambda: edit("core/b.sv", "assign e = d;", "assign e =\n d;"), False)
    same("edit inside an ifdef that is off", lambda: edit("core/a.sv", "logic dead;", "logic dead2;"), True)
    same("code edit", lambda: edit("core/b.sv", "assign e = d;", "assign e = ~d;"), False)
    same("edit inside an ifdef that is on", lambda: edit("core/a.sv", "logic live;", "logic live2;"), False)
    same("a qsf macro removed (-U)", lambda: None, False, "-U", "POCKET_SRAM")
    expect("--expect another hash", [pe, fpga, os.path.join(w, "pp_out"), "--expect", "0" * 64], False)
    write(fpga, "core/b.sv", SV_B.replace("assign e = d;", "logic daria_x; assign e = d;"))
    expect("--max-token 0 with a daria identifier", [pe, fpga, os.path.join(w, "pp_out"), "--max-token", "0"], False)
    expect("--max-token 0 with that file excluded", [pe, fpga, os.path.join(w, "pp_out"), "--max-token", "0",
                                                      "--exclude", "core/b\\.sv"], True)
    write(fpga, "core/b.sv", SV_B)
    shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------- synthetic R1/R2
def synth(w, name, n=200, calls_per=2, mutate=None, late=(), status="locked", frames=False, cross=()):
    """A tb_daria-style run directory. frames=True also writes frames.csv
    (each frame's start on the t_req_sys clock); the first call of each frame
    in cross is requested 1,000 clk_sys before its frame ends, so that its
    hold reaches into the next frame."""
    rnd = random.Random(1)
    d = os.path.join(w, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    L = 238944
    fp = [[str(f), str(L)] + [format(rnd.getrandbits(64), "016x") for _ in range(3)] for f in range(1, n)]
    calls, slack, k = [], [], 0
    for f in range(0, n):
        for j in range(calls_per):
            k += 1
            t_req = f * L + L - 1000 if (f in cross and j == 0) else f * L + 10000 + 100000 * j
            calls.append([k, f, 10 + 100 * j, t_req, 3000 + 7 * (k % 5), 2999, "00000000"])
            slack.append([k, 1, 500, -100 if f in late else 4000, "f000"])
    if frames:
        open(os.path.join(d, "frames.csv"), "w").write(
            "frame,t_sys,len_sys,lines,calls,instr,arm_cyc,stall_sys,dma_sys,max_call_instr\n" +
            "".join(f"{f},{f * L},{L},262.00,{calls_per},0,0,0,0,0\n" for f in range(1, n)))
    st = {"calls": len(calls), "late": sum(1 for s in slack if s[3] <= 0), "halts": 0, "halt_code": 0,
          "psram_viol": 0, "guard": status, "unlocks": 0}
    if mutate:
        mutate(fp, calls, slack, st)
    open(os.path.join(d, "fp.csv"), "w").write("frame,len_sys,riot,video,audio\n" + "".join(",".join(r) + "\n" for r in fp))
    open(os.path.join(d, "calls.csv"), "w").write("call,frame,line,t_req_sys,busy_sys,stall_sys,first_bl\n" +
                                                  "".join(",".join(map(str, c)) + "\n" for c in calls))
    open(os.path.join(d, "slack.csv"), "w").write("call,kind,sys_end_to_poll,slack_sys,poll_pc\n" +
                                                  "".join(",".join(map(str, s)) + "\n" for s in slack))
    open(os.path.join(d, "run.log"), "w").write(
        "detect2600: force_bs 23 revision 2\n"
        f"STATUS calls {st['calls']}, late {st['late']}, halts {st['halts']}, halt_code {st['halt_code']}, "
        f"psram_viol {st['psram_viol']}, guard {st['guard']}, unlocks {st['unlocks']}\n"
        f"ran {n} frames, {len(calls)} calls\n")
    return d


def gate_cases(w):
    fg = os.path.join(HERE, "frame_gate.py")
    print("frame_gate.py on synthetic runs:")
    ref = synth(w, "ref")

    def col(c):
        return {"len_sys": 1, "riot": 2, "video": 3, "audio": 4}[c]

    def setcol(fp, f, c, v=None):
        r = fp[f - 1]
        r[col(c)] = v or format(int(r[col(c)], 16) ^ 1, "016x") if c != "len_sys" else str(int(r[1]) + 1)

    def shift_call(calls, f, by=1):
        for c in calls:
            if c[1] == f:
                c[4] += by
                return

    def m_shift(lo, hi, c="riot"):
        def m(fp, calls, slack, st):
            shift_call(calls, lo)
            for f in range(lo, hi + 1):
                setcol(fp, f, c)
        return m
    G = lambda name, *extra, want: expect(name, [fg, ref, synth(w, name, mutate=extra[0] if extra else None), "--frames", "200"]
                                          + list(extra[1:]), want)
    expect("identical", [fg, ref, synth(w, "same"), "--frames", "200", "--scheme", "23"], True)
    G("release_shift_riot_3_frames", m_shift(50, 52), want=True)
    G("release_shift_audio_8_frames", m_shift(60, 67, "audio"), want=True)
    G("release_shift_too_long_9_frames", m_shift(70, 78), want=False)
    # the difference must start where a call whose release differs is held:
    # the frame after it does not count, unless the hold reaches into it
    G("riot_starts_one_frame_after_the_shifted_call", lambda fp, c, s, st: (shift_call(c, 80), setcol(fp, 81, "riot")),
      want=False)
    # the column must be equal again within the file
    G("riot_from_a_shifted_frame_to_the_end_of_the_file", m_shift(195, 199), want=False)
    xref = synth(w, "ref_cross", frames=True, cross=(60, 70))
    expect("riot_in_the_frame_a_crossing_hold_is_released_in",
           [fg, xref, synth(w, "cross_ok", frames=True, cross=(60, 70),
                            mutate=lambda fp, c, s, st: (shift_call(c, 60), setcol(fp, 61, "riot"), setcol(fp, 62, "riot"))),
            "--frames", "200"], True)
    expect("riot_two_frames_after_a_crossing_hold",
           [fg, xref, synth(w, "cross_late", frames=True, cross=(60, 70),
                            mutate=lambda fp, c, s, st: (shift_call(c, 70), setcol(fp, 72, "riot"))),
            "--frames", "200"], False)
    expect("riot_one_frame_after_a_hold_inside_its_frame (frames.csv)",
           [fg, xref, synth(w, "cross_inside", frames=True, cross=(60, 70),
                            mutate=lambda fp, c, s, st: (shift_call(c, 90), setcol(fp, 91, "riot"))),
            "--frames", "200"], False)
    G("riot_without_shifted_release", lambda fp, c, s, st: setcol(fp, 90, "riot"), want=False)
    G("one_pixel_hash", lambda fp, c, s, st: setcol(fp, 100, "video"), want=False)
    G("len_sys_one_clock", lambda fp, c, s, st: setcol(fp, 110, "len_sys"), want=False)
    G("video_on_a_shifted_release", lambda fp, c, s, st: (shift_call(c, 120), setcol(fp, 120, "video")), want=False)
    G("truncated", lambda fp, c, s, st: fp.pop(), want=False)
    G("one_frame_shift", lambda fp, c, s, st: fp.__setitem__(slice(None), [[str(i + 1)] + fp[i + 1][1:] for i in range(len(fp) - 1)] + [[str(len(fp))] + fp[0][1:]]), want=False)
    G("call_missing", lambda fp, c, s, st: (c.pop(), st.__setitem__("calls", st["calls"] - 1)), want=False)
    G("late_call_extra", lambda fp, c, s, st: (s[10].__setitem__(3, -5), st.__setitem__("late", 1)), want=False)
    G("status_halt", lambda fp, c, s, st: st.__setitem__("halts", 1), want=False)
    G("status_psram", lambda fp, c, s, st: st.__setitem__("psram_viol", 2), want=False)
    G("status_unlock", lambda fp, c, s, st: st.__setitem__("unlocks", 1), want=False)
    G("status_guard_unlocked", lambda fp, c, s, st: st.__setitem__("guard", "unlocked"), want=False)
    # P27: a reference whose load was not seen (no calls)
    void = synth(w, "ref_void", calls_per=0)
    expect("reference_without_calls", [fg, void, synth(w, "cand_void", calls_per=0), "--frames", "200"], False)
    # Spiders: overrun frames 150-165 excused when they are the late frames on both sides
    late = tuple(range(150, 166))
    sref = synth(w, "spiders_ref", late=late)

    def sp(extra_after=False):
        def m(fp, c, s, st):
            for f in range(150, 166):
                setcol(fp, f, "video")
                setcol(fp, f, "len_sys")
            if extra_after:
                setcol(fp, 170, "riot")
        return m
    expect("spiders_excused", [fg, sref, synth(w, "spiders_ok", mutate=sp(), late=late), "--frames", "200",
                               "--excuse", "150-165"], True)
    expect("spiders_differs_after", [fg, sref, synth(w, "spiders_bad", mutate=sp(True), late=late), "--frames", "200",
                                     "--excuse", "150-165"], False)
    expect("spiders_not_the_late_frames", [fg, ref, synth(w, "spiders_nolate", mutate=sp()), "--frames", "200",
                                           "--excuse", "150-165"], False)


def main():
    p = argparse.ArgumentParser(description="planted faults for the step-7 checkers")
    p.add_argument("--work", required=True)
    p.add_argument("--run-sim")
    p.add_argument("--extra")
    p.add_argument("--extra-ref")
    p.add_argument("--extra-dir")
    p.add_argument("--fp")
    p.add_argument("--cartram")
    p.add_argument("--artape", help="a passing artape log (cartram2600_test.py matrix --arfw)")
    p.add_argument("--artape-ref", help="the reference build's artape log")
    p.add_argument("--tools", action="store_true", help="the guards: pp_guards.py, hygiene.sh, pp_equiv.py")
    a = p.parse_args()
    w = os.path.abspath(a.work)
    os.makedirs(w, exist_ok=True)
    if a.run_sim:
        run_sim_cases(a.run_sim, w)
    if a.extra:
        extra_cases(a.extra, a.extra_ref or a.extra, a.extra_dir, w)
    if a.fp:
        fp_cases(a.fp, w)
    if a.cartram:
        cartram_cases(a.cartram, w)
    if a.artape:
        artape_cases(a.artape, a.artape_ref, w)
    if a.tools:
        guard_cases(w)
        hygiene_cases(w)
        pp_equiv_cases(w)
    gate_cases(w)
    print(f"SELFTEST {'pass' if all(results) else 'FAIL'} ({sum(results)} of {len(results)} cases as expected)")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
