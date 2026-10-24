#!/usr/bin/env python3
"""Planted faults: each checker must pass a good input and fail each fault
(DARIA step 7, docs/daria_step7/plan.md 3.6 unit gate 1, 7.1 and 7.2 for I4).

  selftest.py --work DIR [--run-sim LOG] [--extra LOG --extra-ref REF
              [--extra-dir DIR]] [--fp FILE] [--cartram LOG] [--reset LOG]
              [--artape LOG [--artape-ref REF]] [--tools]

DIR receives the planted copies. Every case prints "ok" when the checker
gave the expected verdict, "WRONG" otherwise; the last line is SELFTEST
pass or FAIL, and so is the exit status (0 or 1). The line before it names
the input-dependent groups below that did not run for want of their input
(step7_gates.sh's selftest gate is then PARTIAL).
  --run-sim LOG    a passing run_sim.sh log: wrong TONE ratio, BIOS_BOOT
                   FAIL, a skipped section, a missing PLL_REGION line, a
                   truncated log, a geometry change, BUPCHIP_E2E FAIL, a
                   case cut short (an earlier FRAME line with the right
                   geometry), a SIMULATOR EXIT line; the POKEY read section
                   (RANDOM all $FF as with the read fix undone, at $450 and
                   at $4000, 5 $FF, 23 distinct values, the bench's counts
                   not the values', IRQST's bit 0 clear when idle or set
                   once timer 1 fired, the program not done, the $4000 case
                   or the section gone; 4 $FF and 24 distinct still pass),
                   and the section alone as an ONLY=pokey log (passes with
                   --only pokey, fails planted, and the whole log fails with
                   --only pokey)
  --extra LOG      a passing extra_tests.sh log, with its reference log
                   (--extra-ref) and, for a log from before step 7, its
                   extra/ directory (--extra-dir): an ARCHECK mismatch, a
                   POKEY statistic changed, a multisprite row shift (on a
                   copy of the frames), a SaveKey byte lost, the multiload
                   out of order; with AR_TAPE=1 in the log, the tape
                   multiload's second load and the tape full load's ARCHECK
  --fp FILE        a tb_load/tb_system fp.csv: frame_gate --strict on a
                   truncated copy (a frame, or a line, missing), a one-frame
                   shift, one RIOT hash, one pixel (video) hash and a
                   one-clock len_sys change; the whole run one clk_sys later
                   (t_sys), the reset released one clk_sys later (rst_sys),
                   one more release (rst_n), the time columns missing; two
                   zero-byte and two header-only files
  --cartram LOG    a passing tb_cartram log (cartram2600_test.py's, E7 blend
                   off): a wrong byte, a lost write, a bucket past s19, a
                   changed read count, a fail code, a P2 $fatal, a write of
                   cart RAM by the 7800/BIOS port; and a Fix B log made from
                   it, which passes with the P2 assertion armed and fails
                   without it (also with --profile fixb), passes with a read
                   at s19 that is the first after a console reset and fails
                   with one that is not, or with the first at s18
  --reset LOG      a passing reset run's log (cartram2600_test.py reset,
                   rst_hif8_rd_rst_k0): a strobe not issued, a read issued
                   at s14, a P2 coincidence, a reset not done, a reset with
                   no strobe at E1
  --artape LOG     a passing artape log (the tape load with +cartram), with
                   --artape-ref the reference build's: an ARCHECK mismatch,
                   no tone 5 after the tape, another colour than the
                   reference's, a read count and a write count changed
  --tools          the guards on scratch git repositories in DIR:
                   pp_guards.py (a directive in an added comment, an
                   attribute in a comment, a .vhd and a .mif change, an extra
                   and a missing DARIA qsf line, an SDC code change, a
                   removed translate_off/on pair, --qsf release's cases (a
                   qsf line added or removed, a second SEED line, a code
                   change in an SDC file other than daria_constraints.sdc,
                   a FROM without the DARIA lines), a new daria_ or
                   bup_dbg_snap file with `define, `undef, `timescale or
                   left at `default_nettype none; and the changes it must
                   let through), hygiene.sh (a cartridge image, a PNG, a
                   firmware file, a path into the temporary directory in
                   each form a doc or script spells it: backticks, > and 2>,
                   brackets, a comma, a file:/// URL, a doubled leading
                   slash and the rest, a listed name, also inside
                   an identifier, no list, an empty list and one of comment
                   lines only, a list inside the repository, a binary and
                   an oversized file) and pp_equiv.py on a small
                   Quartus tree (a comment, a layout and a dead-ifdef edit
                   keep the hash; a code edit, a live ifdef edit and a
                   removed macro change it; --expect and --max-token fail;
                   an excluded daria_ file holding a directive that reaches
                   later files is refused); needs git and VERILATOR
  always           div_check.py on a copy of the tree's divider sites:
                   passes as it is, fails when one default names the other
                   divider (each site in turn) or pll_core.v's counter 3
                   moves without the benches; and
                   frame_gate on synthetic R1/R2 run directories. The V1
                   rule (the default): identical; audio differences counted,
                   not gated (sparse, long, after Spiders' overrun); a RIOT
                   difference (also one of the release_shift class), a
                   video difference (frame 1's excused only after a frame-0
                   call's hold differs, and only that frame and column), an
                   ARM instruction count difference on one call (thumb + arm;
                   a different split with an equal sum passes), a calls.csv
                   without the instruction columns, a run without bench
                   parity (the Pocket's inputs or none stated; --any-inputs),
                   an unexpected guard lock. The strict rule (--rule shift):
                   a release_shift that is excused; one that lasts too long;
                   one that starts the frame after the shifted call's; one
                   that reaches the last frame (never equal again); holds
                   that cross a frame end (frames.csv); a RIOT difference
                   with no shifted release; a video, a
                   len_sys and a cpu difference; a truncated file; a call
                   count and a late-call difference; the STATUS line's halts,
                   PSRAM violations, guard and unlocks; Spiders' excused
                   overrun frames, and the same frames when later ones differ;
                   --auto by the loader's scheme, among them P27's ARM image
                   whose REF run makes no call (strict: identical passes; a
                   RIOT byte, an audio frame, calls in CAND, a halt in its
                   STATUS line, a RIOT byte with a halt, another REF scheme
                   and no calls.csv fail), each --auto run with one verdict
                   line, which agrees with its exit status;
                   and wire.py's mutant verdict (plan 7.2, 7.3's wire gate) on
                   the records (WIRE_JSON) of wire.py run on a fake tb_wire:
                   CAUGHT when each scenario that catches the mutant fails on
                   its key; NOT CAUGHT when one fails only on other checks;
                   ERROR when a run exits 127, gives no WIRE summary, hits a
                   %Fatal (also with the key failing), times out
                   (WIRE_TIMEOUT), or reports no value for a judged key, when
                   a scenario left no record, when none of the mutant's
                   scenarios ran; and wire.py mutant with an unknown mutant,
                   an unknown scenario or none of its scenarios named: ERROR
                   before it copies or builds anything; and step7_gates.sh
                   itself on a scratch tree with stand-in run_frames.sh,
                   frame_gate.py and selftest.py (nothing simulated): a
                   misspelt --only or --skip name and an empty --only exit
                   2 before any gate runs, a run with no gate run exits 3;
                   the frames gate runs plan 1.2 row 7's 16 images by
                   default and is PARTIAL, naming the images not run, for a
                   list that leaves any out (FAIL when an image fails); the
                   selftest gate is PARTIAL and names each missing input;
                   and run_frames.sh with a stand-in binary: it refuses to
                   run (exit 2) when WORK/rtl, or one palette or ROM table
                   in it, is missing or a dangling link, fails a run whose
                   log says "$readmem file not found" for one of them, and
                   passes one whose only such line is rtl/mem0.hex's
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


def expect(name, cmd, want_pass, py=True, env=None, check=None):
    # a checker that crashes (a Python traceback) gives no verdict: WRONG,
    # whatever its exit status; check(out, rc), when given, names what else
    # is wrong with the output ("" when nothing is)
    rc, out = run(cmd, py, env)
    bad = check(out, rc) if check and rc in (0, 1) else ""
    ok = (rc == 0) == want_pass and rc in (0, 1) and not bad
    results.append(ok)
    last = out.strip().splitlines()[-1] if out.strip() else "(no output)"
    # the first finding, when the last line does not name it
    why = next((l.strip() for l in out.splitlines() if re.search(r"FAIL|REFUSED|MISMATCH", l) and l.strip() != last.strip()), "")
    print(f"  {'ok   ' if ok else 'WRONG'} {name}: expected {'pass' if want_pass else 'fail'}, got rc {rc} ({last})"
          + (f" [{why[:150]}]" if rc == 1 and why else "") + (f" {{{bad}}}" if bad else ""))
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
        # tb_vaxis5: a seed with mismatches, and the planted fault not caught
        "vaxis5_mismatch": sub1(r"^(VAXIS5 seed 3 .* mismatches )0$", r"\g<1>7"),
        "vaxis5_planted_missed": sub1(r"^(VAXIS5 planted fault .*: )caught, \d+ mismatches$", r"\g<1>caught, 0 mismatches"),
        # tb_region: a trial with the wrong retunes, a planted variant not caught, the section gone
        "region_retunes": sub1(r"^REGION daria A trials 1641 retunes 1:1641 ", "REGION daria A trials 1641 retunes 1:1608 3:33 "),
        "region_planted_missed": sub1(r"^(REGION verdict rtl1: planted, )caught$", r"\g<1>NOT caught"),
        # the sketch "caught" only by saving retunes: no back-to-back retune and daria_rgn exact
        "region_sketch_no_hazard": sub1(r"^(REGION sketch C trials 49 retunes [\d: ]+ rgn_bad )\d+ b2b \d+$", r"\g<1>0 b2b 0"),
        "region_missing": lambda t: re.sub(r"^-- the region asked of the PLL.*?(?=^-- )", "", t, count=1, flags=re.M | re.S),
        # the FA2 save slot: the reload lost, a saved byte read back wrong,
        # no save, and the section gone
        "fa2_reload_lost": sub1(r"^(FA2 work RAM after the reload: )0( of 255)", r"\g<1>255\g<2>"),
        "fa2_slot_differs": sub1(r"^(FA2 save slot read back \(APF read protocol\): )0( of 256)", r"\g<1>4\g<2>"),
        "fa2_no_save": sub1(r"^(FA2 program: .*flash loads 2, saves )1(, slot RAM writes )256$", r"\g<1>0\g<2>0"),
        "fa2_a78_overwrote": sub1(r"^(FA2 save slot after load, reset .*: )0( of 256)", r"\g<1>256\g<2>"),
        # the A78 taken for FA2: its save reached the slot (as before the
        # wrapper's fa2_on gate: 255 of 256 bytes), or it was not taken for
        # FA2 at all, so the run could not fail
        "fa2_a78fa2_overwrote": sub1(r"^(FA2 image: 2600 mapper 25, .*saves 1, slot RAM writes )0(\n(?:.*\n)*?"
                                     r"FA2 save slot after load, reset .*: )0( of 256)", r"\g<1>256\g<2>255\g<3>"),
        "fa2_a78fa2_not_fa2": sub1(r"^(FA2 image: 2600 mapper )25(, cart_is_7800 1, tia_mode 0; flash loads 0, )saves 1",
                                   r"\g<1>0\g<2>saves 0"),
        "fa2_missing": lambda t: re.sub(r"^-- FA2 flash save slot.*?(?=^-- )", "", t, count=1, flags=re.M | re.S),
    }
    for k, fn in cases.items():
        expect(k, [chk, plant(log, os.path.join(w, f"run_sim_{k}.log"), fn)], False)
    pokey_cases(log, w, chk)


def pokey_cases(log, w, chk):
    """The POKEY read section (2.2.2's read fix): planted on the first case's
    (POKEY at $450) lines of a passing log, or the $4000 case's."""
    rx = r"^(    POKEYRD RANDOM 40 reads, )\d+ of them \$FF, \d+ distinct:((?: [0-9a-f]{2}){40})$"

    def rnd(f, counts=None, at4000=False):
        # f(values) -> the values to plant; the bench's counts follow them
        # unless counts gives others
        def g(t):
            def r(m):
                v = f([int(x, 16) for x in m.group(2).split()])
                nff, nd = counts or (v.count(0xFF), len(set(v)))
                return f"{m.group(1)}{nff} of them $FF, {nd} distinct:" + "".join(f" {x:02x}" for x in v)
            i = t.index("\n  POKEY at $4000:\n") if at4000 else 0
            return t[:i] + re.sub(rx, r, t[i:], count=1, flags=re.M)
        return g

    def ffs(n):
        # n values $FF, the rest as they were but none $FF
        return lambda v: [0xFF] * n + [x if x != 0xFF else 0x00 for x in v[n:]]
    pass_cases = {
        "pokey_four_ff": rnd(ffs(4)),
        "pokey_24_distinct": rnd(lambda v: [0x10 + (i % 24) for i in range(40)]),
    }
    fail_cases = {
        "pokey_all_ff": rnd(lambda v: [0xFF] * 40),
        "pokey_4000_all_ff": rnd(lambda v: [0xFF] * 40, at4000=True),
        "pokey_five_ff": rnd(ffs(5)),
        "pokey_few_distinct": rnd(lambda v: [0x10 + (i % 23) for i in range(40)]),
        "pokey_counts_lie": rnd(lambda v: [0xFF] * 40, counts=(0, 40)),
        "pokey_irqst_idle_clear": sub1(r"^(    POKEYRD IRQST idle \$)[0-9a-f]{2}", r"\g<1>fe"),
        "pokey_irqst_not_fired": sub1(r"^(    POKEYRD IRQST idle \$[0-9a-f]{2}, timer 1 fired \$)[0-9a-f]{2}", r"\g<1>ff"),
        "pokey_not_done": sub1(r"^(    POKEYRD marker \$)a5", r"\g<1>00"),
        "pokey_4000_missing": lambda t: re.sub(r"^  POKEY at \$4000:\n(?:    .*\n)*", "", t, count=1, flags=re.M),
        "pokey_missing": lambda t: re.sub(r"^-- POKEY reads.*?(?=^-- )", "", t, count=1, flags=re.M | re.S),
    }
    for k, fn in pass_cases.items():
        expect(k, [chk, plant(log, os.path.join(w, f"run_sim_{k}.log"), fn)], True)
    for k, fn in fail_cases.items():
        expect(k, [chk, plant(log, os.path.join(w, f"run_sim_{k}.log"), fn)], False)
    # the section alone, as run_sim.sh ONLY=pokey writes it
    t = open(log, "rb").read().decode("utf-8", "replace")
    head = re.search(r"^-- run_sim\.sh: .*\n", t, flags=re.M)
    sec = re.search(r"^-- POKEY reads.*?(?=^-- )", t, flags=re.M | re.S)
    if not head or not sec:
        results.append(False)
        print("  WRONG ONLY=pokey log: the log has no '-- run_sim.sh:' line or no POKEY read section to make it from")
        return
    only = os.path.join(w, "run_sim_only_pokey.log")
    open(only, "w").write(head.group(0) + "-- run_sim.sh ONLY=pokey: tb_load and the POKEY read section alone, not a whole run\n"
                          + sec.group(0) + "exit 0\n")
    expect("ONLY=pokey log, --only pokey", [chk, only, "--only", "pokey"], True)
    expect("ONLY=pokey log without --only", [chk, only], False)
    expect("ONLY=pokey log, RANDOM all $FF", [chk, plant(only, os.path.join(w, "run_sim_only_pokey_ff.log"),
                                                         rnd(lambda v: [0xFF] * 40)), "--only", "pokey"], False)
    expect("the whole log with --only pokey", [chk, log, "--only", "pokey"], False)


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
    if "-- 2600 cartridge RAM" in open(log, errors="replace").read():
        # the cartridge-RAM section (its verdicts follow cartram2600_test.py's
        # "-- tb_cartram: ... md5" lines, which must not end the section)
        cases["cartram_matrix_verdict_missing"] = sub1(r"^CARTRAM_MATRIX pass\n", "")
        cases["cartram_s19_verdict_missing"] = sub1(r"^CARTRAM_S19 pass\n", "")
        if re.search(r"^PASS artape blend 0:", open(log, errors="replace").read(), re.M):
            cases["artape_missing"] = sub1(r"^PASS artape blend 0:.*\n", "")
            cases["artape_colours_differ_from_the_tape_full_load"] = sub1(r"^(PASS artape blend 0:.*; colours )\$[0-9a-f]{2}",
                                                                          r"\g<1>$54")
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
    # the first read after a console reset may land at s19 with Fix B (and only it)
    def post_line(t, hist):
        line = f"CARTRAM post-reset reads: {sum(hist.values())} (the first CPU read of cart RAM after each console reset release), histogram:" + \
            "".join(f" {k}:{v}" for k, v in sorted(hist.items())) + "\n"
        t2 = re.sub(r"^CARTRAM post-reset reads: .*\n", line, t, count=1, flags=re.M)
        return t2 if t2 != t else t + line
    def add19(t):
        t = re.sub(r"^(CARTRAM latency histogram \(clk_sdram from E0: count\):.*)$", r"\g<1> 19:1", t, count=1, flags=re.M)
        return re.sub(r"c_rdata at E0\+(-?\d+)\.\.(-?\d+) clk_sdram", r"c_rdata at E0+\g<1>..19 clk_sdram", t, count=1)
    pr = plant(fx, os.path.join(w, "cartram_fixb_post19.log"), lambda t: post_line(add19(t), {19: 1}))
    expect("a Fix B read at s19, the first after a console reset", [ct, "check", pr, "--image", "e7", "--blend", "0"], True)
    npr = plant(fx, os.path.join(w, "cartram_fixb_s19_not_post.log"), lambda t: post_line(add19(t), {}))
    expect("a Fix B read at s19 that is not the first after a reset", [ct, "check", npr, "--image", "e7", "--blend", "0"], False)
    pr2 = plant(fx, os.path.join(w, "cartram_fixb_post18.log"),
                lambda t: post_line(re.sub(r"^(CARTRAM latency histogram \(clk_sdram from E0: count\):.*)$", r"\g<1> 18:1", t,
                                           count=1, flags=re.M), {18: 1}))
    expect("a first read after a reset at s18 (only s19 is allowed)", [ct, "check", pr2, "--image", "e7", "--blend", "0"], False)
    def port_write(t):
        line = ("CARTRAM ports: the 2600 port's accesses issued: reads 0, writes 0; the 7800/BIOS port's: reads 0, writes 1 of "
                "cart RAM; 0 in the BIOS region (by request port)\n")
        t2 = re.sub(r"^CARTRAM ports: .*\n", line, t, count=1, flags=re.M)
        return t2 if t2 != t else t + line
    expect("a 7800/BIOS-port write of cart RAM in a 2600 run",
           [ct, "check", plant(log, os.path.join(w, "cartram_port_write.log"), port_write), "--image", "e7", "--blend", "0"], False)


def reset_cases(log, w):
    """A passing reset run's log (cartram2600_test.py reset, rst_hif8_rd_rst_k0)."""
    ct = os.path.join(SIM, "cartram2600_test.py")
    print("cartram2600_test.py check-reset:")
    run = ["--run", "rst_hif8_rd_rst_k0"]
    expect("the reset run as it is", [ct, "check-reset", log] + run, True)
    first = lambda pat, rpl: (lambda t: re.sub(pat, rpl, t, count=1, flags=re.M))
    cases = {
        "reset_not_issued": first(r"^(RST 0 K=\d+: strobe [^;]*; )issued at s\d+( data \w+)?;", r"\g<1>NOT issued;"),
        "reset_read_late": first(r"^(RST 0 K=\d+: strobe read [^;]*; issued at s)\d+;", r"\g<1>14;"),
        "reset_coincidence": first(r"^(RST 0 K=.*P2 coincidences )0$", r"\g<1>1"),
        "reset_incomplete": first(r"^RST summary: (\d+) of", lambda m: f"RST summary: {int(m.group(1)) - 1} of"),
        "reset_no_strobe": first(r"^(RST 0 K=\d+: strobe )[^;]*; [^;]*;", r"\g<1>none; -;"),
        # the strobe's kind must be the run mode's: a write in this read run
        "reset_strobe_kind_write_in_a_read_run": first(r"^(RST 0 K=\d+: strobe )read (\$\w+); issued at s(\d+);",
                                                         r"\g<1>write \g<2> data 00; issued at s\g<3> data 00;"),
        "reset_run_mode_wr_with_read_strobes": first(r"^(RST armed: .*?, mode )rd,", r"\g<1>wr,"),
        "reset_run_without_a_mode": first(r"^(RST armed: .*?, )mode rd,", r"\g<1>"),
    }
    for c, fn in cases.items():
        expect(c, [ct, "check-reset", plant(log, os.path.join(w, f"{c}.log"), fn)] + run, False)


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
        "artape_read_count": sub1(r"^CARTRAM reads: (\d+)", lambda m: "CARTRAM reads: " + str(int(m.group(1)) + 1)),
        "artape_write_count": sub1(r"^CARTRAM writes: (\d+) strobes at the mappers, (\d+) cart writes issued",
                                   lambda m: f"CARTRAM writes: {int(m.group(1)) + 1} strobes at the mappers, {int(m.group(2)) + 1} cart writes issued"),
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
	// synthesis translate_off
	initial $display("b: simulation only");
	// synthesis translate_on
endmodule
"""
# a new DARIA file (excluded from pp_equiv's stream) listed before a.sv
SV_DARIA = """`default_nettype none
module daria_x(input wire clk, output logic q);
	// `define IN_A_COMMENT is no directive
	always_ff @(posedge clk) q <= ~q;
endmodule
`default_nettype wire
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
        # removing a directive comment changes what Quartus builds as much as adding one
        ("a translate_off/on pair removed", "comments",
         lambda: edit("src/fpga/core/b.sv", "\t// synthesis translate_off\n", "") or
         edit("src/fpga/core/b.sv", "\t// synthesis translate_on\n", ""), False),
        # plan 2.8: a new daria_* file holds no directive that reaches later files
        ("a new daria_ file with default_nettype none, then wire, and a define in a comment", "comments",
         lambda: write(d, "src/fpga/core/daria_x.sv", SV_DARIA), True),
        ("a new daria_ file with `undef", "comments",
         lambda: write(d, "src/fpga/core/daria_x.sv", SV_DARIA.replace("module daria_x", "`undef POCKET_SRAM\nmodule daria_x")), False),
        ("a new daria_ file with `define", "comments",
         lambda: write(d, "src/fpga/core/daria_x.sv", SV_DARIA.replace("module daria_x", "`define X 1\nmodule daria_x")), False),
        ("a new bup_dbg_snap file with `timescale", "comments",
         lambda: write(d, "src/fpga/core/bupchip/bup_dbg_snap.sv", SV_DARIA.replace("daria_x", "bup_dbg_snap")
                       .replace("module bup", "`timescale 1ns/1ps\nmodule bup")), False),
        ("a new daria_ file left at default_nettype none", "comments",
         lambda: write(d, "src/fpga/core/daria_x.sv", SV_DARIA.replace("`default_nettype wire\n", "")), False),
    ]
    for name, q, fn, want in cases:
        g("checkout", "-q", "-f", "base")
        fn()
        g("add", "-A")
        g("commit", "-q", "-m", name)
        expect(name, [pg, "--repo", d, "--from", "base", "--to", "HEAD", "--qsf", q], want)
        g("checkout", "-q", "-f", "base")
    # --qsf release: from a commit that has the DARIA lines (and an MR line);
    # only the SEED line and comments of ap_core.qsf may change, and
    # daria_constraints.sdc, which only the DARIA build reads
    mr = 'set_instance_assignment -name MUX_RESTRUCTURE ON -to "core_top:ic|x:y"\n'
    rel_qsf = QSF + daria3 + mr
    write(d, "src/fpga/ap_core.qsf", rel_qsf)
    write(d, "src/fpga/core/daria_constraints.sdc", "# guard pair\nset_max_delay 6.0 -from a -to b\n")
    g("add", "-A")
    g("commit", "-q", "-m", "base_rel")
    g("tag", "base_rel")
    rel_cases = [
        ("release: SEED, a qsf comment and daria_constraints.sdc's bounds", lambda: (
            write(d, "src/fpga/ap_core.qsf", rel_qsf.replace("SEED 1", "SEED 2").replace("# test project", "# seed 2 chosen")),
            edit("src/fpga/core/daria_constraints.sdc", "6.0", "8.0")), True),
        ("release: an SDC comment only", lambda: edit("src/fpga/core/core_constraints.sdc", "# clocks", "# the clocks"), True),
        ("release: an extra qsf line", lambda: write(d, "src/fpga/ap_core.qsf", rel_qsf + mr.replace("x:y", "x:z")), False),
        ("release: the MR line removed", lambda: write(d, "src/fpga/ap_core.qsf", QSF + daria3), False),
        ("release: a DARIA qsf line removed", lambda: write(d, "src/fpga/ap_core.qsf", QSF + daria3.split("\n", 1)[1] + mr), False),
        ("release: a second SEED line", lambda: write(d, "src/fpga/ap_core.qsf", rel_qsf + "set_global_assignment -name SEED 3\n"), False),
        # a lost SEED line would ship Quartus' default seed, not P12's
        ("release: the SEED line removed", lambda: write(d, "src/fpga/ap_core.qsf", rel_qsf.replace("set_global_assignment -name SEED 1\n", "")),
         False),
        ("release: an SDC code change in core_constraints.sdc",
         lambda: edit("src/fpga/core/core_constraints.sdc", "69.841", "69.000"), False),
    ]
    for name, fn, want in rel_cases:
        g("checkout", "-q", "-f", "base_rel")
        fn()
        g("add", "-A")
        g("commit", "-q", "-m", name)
        expect(name, [pg, "--repo", d, "--from", "base_rel", "--to", "HEAD", "--qsf", "release"], want,
               check=(lambda out, rc: "" if "expected exactly one SEED line" in out else "the SEED count is not named")
               if "SEED line" in name and not want else None)
        g("checkout", "-q", "-f", "base_rel")
    # from base, which lacks the DARIA lines, the release rule must refuse; base..base
    # leaves the qsf unchanged, so only the missing DARIA lines can fail it
    expect("release: FROM without the DARIA lines", [pg, "--repo", d, "--from", "base", "--to", "base", "--qsf", "release"], False,
           check=lambda out, rc: "" if "lacks the DARIA line" in out else "the missing DARIA lines are not named")
    # step7_gates.sh's pp_guards gate picks the qsf mode itself: release when
    # PP_GUARD_FROM's qsf has POCKET_DARIA too, daria when only the tree's has it
    g("checkout", "-q", "-f", "base_rel")
    write(d, "src/fpga/ap_core.qsf", rel_qsf.replace("SEED 1", "SEED 2"))
    g("add", "-A")
    g("commit", "-q", "-m", "seed 2")
    for rel, src in (("sim/step7_gates.sh", os.path.join(SIM, "step7_gates.sh")), ("sim/tools/pp_guards.py", pg),
                     ("sim/tools/pp_equiv.py", os.path.join(SIM, "tools", "pp_equiv.py"))):
        os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
        shutil.copy2(src, os.path.join(d, rel))   # untracked: the guards read committed blobs only
    env = {k: v for k, v in os.environ.items() if k not in ("SIM_LOCK", "PP_GUARD_FROM")}
    for frm, mode, want in (("base_rel", "release", True), ("base", "daria", False)):
        out = os.path.join(w, "gates_pp_guards_" + frm)
        shutil.rmtree(out, ignore_errors=True)

        def check(o, rc, out=out, mode=mode):
            p = os.path.join(out, "pp_guards.log")
            t = open(p).read() if os.path.exists(p) else ""
            return "" if f"GUARD qsf {mode}:" in t else f"pp_guards.log does not show 'GUARD qsf {mode}'"
        expect(f"step7_gates.sh --only pp_guards, PP_GUARD_FROM {frm}: --qsf {mode}",
               ["bash", os.path.join(d, "sim", "step7_gates.sh"), "--out", out, "--only", "pp_guards"], want, py=False,
               env=dict(env, PP_GUARD_FROM=frm, VERILATOR="true"), check=check)


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
    empty_names = os.path.join(w, "hygiene_names_empty.txt")
    open(empty_names, "w").write("")
    comment_names = os.path.join(w, "hygiene_names_comments.txt")
    open(comment_names, "w").write("# only a comment\n  # an indented one\n\n")
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
        ("an empty name list", lambda: write(d, "sim/x.py", "print('ok')\n"), False, ["--names", empty_names]),
        ("a name list of comment lines only", lambda: write(d, "sim/x.py", "print('ok')\n"), False,
         ["--names", comment_names]),
        ("name list inside the repository", lambda: (write(d, "names.txt", "Quuxbot\n"), write(d, "sim/x.py", "1\n")), False,
         ["--names", os.path.join(d, "names.txt")]),
        ("binary file", lambda: write(d, "sim/blob.dat", bytes(range(256)) * 4, "wb"), False, ["--names", names]),
        ("file over the size limit", lambda: write(d, "sim/big.txt", big), False, ["--names", names]),
        # the forms in which a scratch path reaches a doc or a script
        ("path in markdown backticks", lambda: write(d, "docs/x.md", "see `" + tmp + "`\n"), False, ["--names", names]),
        ("path after a redirection >", lambda: write(d, "sim/x.sh", "cmd >" + tmp + "\n"), False, ["--names", names]),
        ("path after a redirection 2>", lambda: write(d, "sim/x.sh", "cmd 2>" + tmp + "\n"), False, ["--names", names]),
        ("path in brackets", lambda: write(d, "docs/x.md", "a link [" + tmp + "](x)\n"), False, ["--names", names]),
        ("path after a comma", lambda: write(d, "sim/x.py", "p = ['a'," + tmp + "]\n"), False, ["--names", names]),
        ("path as a default ${X:-...}", lambda: write(d, "sim/x.sh", "x=${Y:-" + tmp + "}\n"), False, ["--names", names]),
        ("path in a table cell", lambda: write(d, "docs/x.md", "| a |" + tmp + " |\n"), False, ["--names", names]),
        ("path glued to an option", lambda: write(d, "sim/x.sh", "gcc -I" + tmp + " x.c\n"), False, ["--names", names]),
        ("path as a file URL (file:///)", lambda: write(d, "docs/x.md", "open file://" + tmp + "\n"), False, ["--names", names]),
        ("path with a doubled leading slash", lambda: write(d, "sim/x.sh", "cat /" + tmp + "\n"), False, ["--names", names]),
        ("path as a file URL with a host", lambda: write(d, "docs/x.md", "open file://localhost" + tmp + "\n"), False,
         ["--names", names]),
        ("JSON-escaped path", lambda: write(d, "sim/x.json", '{"log": "' + tmp.replace("/", "\\/") + '"}\n'), False,
         ["--names", names]),
        ("JSON-escaped relative path", lambda: write(d, "sim/x.json", '{"log": "work' + tmp.replace("/", "\\/") + '"}\n'), True,
         ["--names", names]),
        ("a doubled slash inside a relative path", lambda: write(d, "sim/x.sh", "ls work/" + tmp + "\n"), True, ["--names", names]),
        # the directory itself, no path into it (I3's container command)
        ("the directory itself, no path into it", lambda: write(d, "sim/x.sh", "bash -c 'cd " + tmp.rsplit("/", 1)[0] + " && ls'\n"),
         True, ["--names", names]),
        ("relative paths ending in tmp", lambda: write(d, "sim/x.sh", "ls work" + tmp + " $WORK" + tmp + " ${WORK}" + tmp +
                                                       " ./" + tmp.lstrip("/") + " ~" + tmp + " " + tmp.replace("tmp", "tmpfoo") + "\n"),
         True, ["--names", names]),
        ("listed name inside a camelCase identifier", lambda: write(d, "docs/x.md", "QuuxbotHelper wrote it\n"), False, ["--names", names]),
        ("listed name inside a snake_case identifier", lambda: write(d, "sim/x.py", "quuxbot_x = 1\n"), False, ["--names", names]),
        ("listed name in a file name", lambda: write(d, "docs/Quuxbot-notes.md", "x\n"), False, ["--names", names]),
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
    # A new DARIA file, listed before a.sv and excluded from the stream: the
    # hash must not hide what it does to the files after it (plan 2.8).
    qip = open(os.path.join(fpga, "core/core.qip")).read()
    write(fpga, "core/core.qip", "set_global_assignment -name SYSTEMVERILOG_FILE [file join $::quartus(qip_path) daria_x.sv ]\n" + qip)
    write(fpga, "core/daria_x.sv", SV_DARIA)
    ex = [pe, fpga, os.path.join(w, "pp_out"), "--exclude", "daria_", "--expect", h0]
    expect("a daria_ file excluded (default_nettype none, then wire): the hash of the rest", ex, True)
    for what, src in (("`undef POCKET_SRAM", SV_DARIA.replace("module daria_x", "`undef POCKET_SRAM\nmodule daria_x")),
                      ("`define", SV_DARIA.replace("module daria_x", "`define POCKET_X 1\nmodule daria_x")),
                      ("`timescale", SV_DARIA.replace("module daria_x", "`timescale 1ns/1ps\nmodule daria_x")),
                      ("`include", SV_DARIA.replace("module daria_x", "`include \"b.sv\"\nmodule daria_x")),
                      ("`default_nettype tri", SV_DARIA.replace("`default_nettype wire", "`default_nettype tri")),
                      ("an `ifdef without `endif", SV_DARIA.replace("module daria_x", "`ifdef POCKET_SRAM\nmodule daria_x"))):
        write(fpga, "core/daria_x.sv", src)
        expect(f"an excluded daria_ file with {what}: refused", ex, False)
    write(fpga, "core/core.qip", qip)
    os.remove(os.path.join(fpga, "core/daria_x.sv"))
    shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------- synthetic R1/R2
def synth(w, name, n=200, calls_per=2, mutate=None, late=(), status="locked", frames=False, cross=(), scheme=23,
          inputs="tb_daria's"):
    """A tb_daria-style run directory. frames=True also writes frames.csv
    (each frame's start on the t_req_sys clock); the first call of each frame
    in cross is requested 1,000 clk_sys before its frame ends, so that its
    hold reaches into the next frame. The guard's status is locked, as at
    VCO/18 (frame_gate.py's default --expect-guard); run.log says the paddle
    inputs were tb_daria's (bench parity) unless inputs is None."""
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
            calls.append([k, f, 10 + 100 * j, t_req, 3000 + 7 * (k % 5), 2999, "00000000", 20000, 1000 + k % 7, 0])
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
    open(os.path.join(d, "calls.csv"), "w").write("call,frame,line,t_req_sys,busy_sys,stall_sys,first_bl,arm_cyc,thumb,arm\n" +
                                                  "".join(",".join(map(str, c)) + "\n" for c in calls))
    open(os.path.join(d, "slack.csv"), "w").write("call,kind,sys_end_to_poll,slack_sys,poll_pc\n" +
                                                  "".join(",".join(map(str, s)) + "\n" for s in slack))
    open(os.path.join(d, "run.log"), "w").write(
        f"detect2600: force_bs {scheme} revision 2\n"
        f"OPTIONS RAM0 bytes non-zero after load: 0 of 2048; 2600 mapper {scheme} (override 0)\n"
        f"STATUS calls {st['calls']}, late {st['late']}, halts {st['halts']}, halt_code {st['halt_code']}, "
        f"psram_viol {st['psram_viol']}, guard {st['guard']}, unlocks {st['unlocks']}\n"
        f"ran {n} frames, {len(calls)} calls\n"
        + (f"FRAMES inputs: {inputs} (synthetic)\n" if inputs else ""))
    return d


DIV_SITES = [   # (file, the default's text at VCO/19, the same at VCO/18)
    ("sim/tb_load.sv", "int arm_div = 19,", "int arm_div = 18,"),
    ("sim/tb_system.sv", "int arm_div = 19,", "int arm_div = 18,"),
    ("sim/bupchip/daria/wire/wire.py", 'os.environ.get("ARM_DIV", "19")', 'os.environ.get("ARM_DIV", "18")'),
    ("sim/run_sim.sh", "guard=unlocked; [ \"${ARM_DIV:-19}\" = 18 ] && guard=locked",
     "guard=locked; [ \"${ARM_DIV:-18}\" = 19 ] && guard=unlocked"),
    ("sim/check/frame_gate.py", '"--expect-guard", default="unlocked"', '"--expect-guard", default="locked"'),
    ("sim/step7_gates.sh", "${FRAMES_GUARD:-unlocked}", "${FRAMES_GUARD:-locked}"),
    ("sim/step7_gates.sh", "\tDARIA=1 ARM19=1 PSRAM_CS=", "\tDARIA=1 ARM38=1 PSRAM_CS="),
    ("sim/bupchip/quartus_probe/step7/step7_report.tcl", "fixb 1 div 19}", "fixb 1 div 18}"),
]
# sites that follow the tree's divider: the planted fault is a fixed number,
# the other divider ({o})
DIV_FOLLOW = [
    ("sim/bupchip/quartus_probe/step7/run_step7.sh", '[ -n "$DIV" ] || DIV="$TREE_DIV"', '[ -n "$DIV" ] || DIV={o}'),
    ("sim/bupchip/daria/run_daria.sh", 'D_DIV="${D_DIV:-$TREE_DIV}"', 'D_DIV="${D_DIV:-{o}}"'),
]


def div_cases(w):
    """div_check.py on a scratch copy of the files it reads (the tree's, at
    VCO/18 or VCO/19): it passes; each site moved to the other divider fails
    it; and pll_core.v's counter 3 at the other divider (step7_prep.py's own
    C3 table) with the benches left at the tree's fails it."""
    dc = os.path.join(HERE, "div_check.py")
    repo = os.path.dirname(SIM)
    d = os.path.join(w, "divtree")
    print("div_check.py on a copy of the tree's divider sites:")
    files = sorted({s[0] for s in DIV_SITES + DIV_FOLLOW} | {"src/fpga/core/pll/pll_core.v",
                                                  "sim/bupchip/quartus_probe/step7/step7_prep.py"})

    def fresh():
        shutil.rmtree(d, ignore_errors=True)
        for f in files:
            os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
            shutil.copyfile(os.path.join(repo, f), os.path.join(d, f))
    fresh()
    tree = subprocess.run([sys.executable, os.path.join(d, "sim/bupchip/quartus_probe/step7/step7_prep.py"),
                           os.path.join(d, "src/fpga"), "--tree-div"], capture_output=True, text=True).stdout.strip()
    if tree not in ("18", "19"):
        print(f"  WRONG the tree's divider is {tree or 'unreadable'}, not 18 or 19: the planted cases need one of them")
        results.append(False)
        return
    div = int(tree)
    other = 37 - div
    expect(f"div_check on the tree's copy (VCO/{div})", [dc, "--repo", d], True)
    sites = [(f, a19 if div == 19 else a18, a18 if div == 19 else a19) for f, a19, a18 in DIV_SITES]
    sites += [(f, good, bad.replace("{o}", str(other))) for f, good, bad in DIV_FOLLOW]
    for f, here, there in sites:
        fresh()
        p = os.path.join(d, f)
        t = open(p).read()
        if t.count(here) != 1:
            print(f"  WRONG the site's text in {f} is not there once: {here!r}")
            results.append(False)
            continue
        open(p, "w").write(t.replace(here, there))
        expect(f"div_check with {f} at VCO/{other}", [dc, "--repo", d], False)
    # pll_core.v moved to the other C3 (step7_prep.py's table of ip-generate's
    # values, read from its source: the script runs at import), the benches
    # left at the tree's
    fresh()
    import ast
    src = open(os.path.join(d, "sim/bupchip/quartus_probe/step7/step7_prep.py")).read()
    tab = {}
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and getattr(node.targets[0], "id", "") in ("C3_VALUES", "C3_COL"):
            tab[node.targets[0].id] = ast.literal_eval(node.value)
    p = os.path.join(d, "src/fpga/core/pll/pll_core.v")
    n, out = 0, []
    for line in open(p).read().split("\n"):
        m = re.match(r"^\s*\.(\w+)\((.*)\),?\s*$", line)
        if m and m.group(1) in tab.get("C3_VALUES", {}) and m.group(2) == tab["C3_VALUES"][m.group(1)][tab["C3_COL"][div]] \
                and m.group(2) != tab["C3_VALUES"][m.group(1)][tab["C3_COL"][other]]:
            line = line.replace(m.group(2), tab["C3_VALUES"][m.group(1)][tab["C3_COL"][other]], 1)
            n += 1
        out.append(line)
    open(p, "w").write("\n".join(out))
    got = subprocess.run([sys.executable, os.path.join(d, "sim/bupchip/quartus_probe/step7/step7_prep.py"),
                          os.path.join(d, "src/fpga"), "--tree-div"], capture_output=True, text=True).stdout.strip()
    if got != str(other):
        print(f"  WRONG pll_core.v's copy did not move to C3 = {other} ({n} lines edited; --tree-div {got or 'failed'})")
        results.append(False)
    else:
        expect(f"div_check with pll_core.v at C3 = {other} ({n} lines), the benches at {div}", [dc, "--repo", d], False)
    shutil.rmtree(d, ignore_errors=True)


# a fake tb_wire (wire.py run's binary): its output depends on the scenario,
# its run directory. The summary's counts are made up; the keys are tb_wire's
WIRE_FAKE = r"""#!/bin/bash
S="WIRE summary build=daria releases=2 f6=2 f6_win=1 f6_rst=1 f6_win_dt=1 f6_rst_low=0 f6_busy=0 f6_noib=0"
S="$S f6_live=0 f6_ram_diff=0 wr_crb=100 wr_stb=10 wr_busy=0 wr_stop=0 wr_drop=0 wr_after_load2=0 hold_rise=2"
S="$S prof_clk=1000 calls=5 calls_arm=5 rets=5 rets_fe=5 ret_max_us=2 open_old=0 abandoned=0 orphans=0 smp_req=0"
S="$S smp_ack=0 halts=0 unlocks=0 locked=0 psram_viol=0 psram_cs=50.000000 misses=0 rt_rst_low=0 rt_f6=1"
S="$S rt_f6_early=0 rs_f6=1 rs_f6_rst_low=0 f6_pend=0 rgn_bad=0 calls_rs=5 calls_rt=5 marker=5 errors=0"
S="$S marker_rs=2 retunes=1 b2b=0 pal_chg=1 is_pal=1"
case "${PWD##*/}" in
seq_menu_dpc) echo "${S/rgn_bad=0/rgn_bad=7}" ;;
seq_auto_dpc) echo "cannot start" >&2; exit 127 ;;
seq_load_cdf) exit 0 ;;
seq_slot_dpc) echo "${S/rgn_bad=0/rgn_bad=7}"; echo "%Fatal: tb_wire.sv:1: an assertion" ;;
seq_rfirst_dpc) exec sleep 60 ;;
seq_back_dpc) echo "$S" ;;
pal_dpc) echo "${S/ rgn_bad=0/}" ;;
*) exit 3 ;;
esac
"""


def wire_cases(w):
    """wire.py run on a fake tb_wire (WIRE_FAKE) writes a record per
    scenario; wire.py verdict judges a mutant from them, as wire.py mutant
    does after its run: palsel's key is rgn_bad, nofrzpend's scenario is
    seq_back_dpc (wire.py's CATCH)."""
    wp = os.path.join(SIM, "bupchip/daria/wire/wire.py")
    d = os.path.join(w, "wire")
    shutil.rmtree(d, ignore_errors=True)
    vtb = os.path.join(d, "daria", "obj_wire", "vtb")
    os.makedirs(os.path.dirname(vtb))
    open(vtb, "w").write(WIRE_FAKE)
    os.chmod(vtb, 0o755)
    js = os.path.join(d, "results.json")
    env = dict(os.environ, WORK=d, WIRE_JSON=js, WIRE_TIMEOUT="2", BUPFW=os.path.join(d, "no_firmware"),
               GAMES="", BIOS="")
    for k in ("DIRECTED", "RTL_TREE"):
        env.pop(k, None)
    print("wire.py's mutant verdict on a fake tb_wire:")
    names = ["seq_menu_dpc", "seq_auto_dpc", "seq_load_cdf", "seq_slot_dpc", "seq_rfirst_dpc", "seq_back_dpc", "pal_dpc"]
    r = subprocess.run([sys.executable, wp, "run"] + names, env=env, capture_output=True, text=True)
    got = set()
    if os.path.isfile(js):
        import json
        got = {json.loads(l)["name"] for l in open(js) if l.strip()}
    ok = r.returncode == 1 and "Traceback" not in r.stderr and got == set(names)
    results.append(ok)
    print(f"  {'ok   ' if ok else 'WRONG'} wire.py run on the fake tb_wire: expected exit 1 and a record for each of "
          f"{len(names)} scenarios, got exit {r.returncode} and {len(got)}")
    if not ok:
        print("\n".join("        " + l for l in (r.stdout + r.stderr).splitlines()[-12:]))
        return

    def case(label, args, want):
        word = {0: "CAUGHT", 1: "NOT CAUGHT", 2: "ERROR"}[want]
        r = subprocess.run([sys.executable, wp] + args, env=env, capture_output=True, text=True)
        last = (r.stdout.strip().splitlines() or ["(no output)"])[-1]
        ok = r.returncode == want and "Traceback" not in r.stderr and re.match(r"MUTANT \w+: %s\b" % word, last)
        if args[0] == "mutant" and os.path.exists(os.path.join(d, "mut_" + args[1])):
            ok, last = False, last + " [it made " + os.path.join(d, "mut_" + args[1]) + "]"
        results.append(bool(ok))
        print(f"  {'ok   ' if ok else 'WRONG'} {label}: expected {word}, got rc {r.returncode} ({last[:200]})")
        if not ok:
            print("\n".join("        " + l for l in (r.stdout + r.stderr).splitlines()[-8:]))
    v = lambda mut, *n: ["verdict", mut, js] + list(n)
    case("palsel, seq_menu_dpc failing on rgn_bad", v("palsel", "seq_menu_dpc"), 0)
    case("palsel, seq_back_dpc failing only on other checks", v("palsel", "seq_back_dpc"), 1)
    case("palsel, one of its two scenarios failing on rgn_bad", v("palsel", "seq_menu_dpc", "seq_back_dpc"), 1)
    case("palsel, a run that exits 127", v("palsel", "seq_menu_dpc", "seq_auto_dpc"), 2)
    case("palsel, a run with no WIRE summary", v("palsel", "seq_menu_dpc", "seq_load_cdf"), 2)
    case("palsel, a %Fatal in a run failing on rgn_bad", v("palsel", "seq_menu_dpc", "seq_slot_dpc"), 2)
    case("palsel, a run killed at WIRE_TIMEOUT", v("palsel", "seq_menu_dpc", "seq_rfirst_dpc"), 2)
    case("palsel, a summary without rgn_bad", v("palsel", "seq_menu_dpc", "pal_dpc"), 2)
    case("palsel, a scenario with no record", v("palsel", "seq_menu_dpc", "seq_tia_dpc"), 2)
    case("nofrzpend, none of its scenarios run", v("nofrzpend", "seq_menu_dpc"), 2)
    case("wire.py mutant, an unknown scenario", ["mutant", "palsel", "no_such_scenario"], 2)
    case("wire.py mutant, an unknown mutant", ["mutant", "no_such_mutant"], 2)
    case("wire.py mutant, none of its scenarios named", ["mutant", "nofrzpend", "seq_menu_dpc"], 2)
    shutil.rmtree(d, ignore_errors=True)


# stand-ins for the scripts step7_gates.sh's frames and selftest gates call (gates_sh_cases): nothing is simulated
GATES_FAKE_FRAMES = r"""#!/bin/bash
# stand-in run_frames.sh: the run directory tb_frames would write
mkdir -p "$WORK/runs/$NAME" && echo "stand-in run_frames.sh $*" > "$WORK/runs/$NAME/run.log"
"""
GATES_FAKE_GATE = r"""#!/usr/bin/env python3
# stand-in frame_gate.py: FAIL for the image named in FAKE_FAIL, pass for any other
import os, sys
n = sys.argv[sys.argv.index("--name") + 1]
bad = n == os.environ.get("FAKE_FAIL")
print("FRAME_GATE %s %s" % ("FAIL" if bad else "pass", n))
sys.exit(1 if bad else 0)
"""
GATES_FAKE_SELFTEST = r"""#!/usr/bin/env python3
# stand-in selftest.py: its arguments, and a pass
import sys
print("stand-in selftest.py " + " ".join(sys.argv[1:]))
print("SELFTEST pass (1 of 1 cases as expected)")
"""


# stand-in tb_frames binary for run_frames_cases: a passing bench, which also
# prints Verilator's missing-table warning for FAKE_READMEM (a path under rtl/)
FRAMES_FAKE_VTB = r"""#!/bin/bash
[ -n "$FAKE_READMEM" ] && echo "%Warning: rtl/$FAKE_READMEM:0: \$readmem file not found"
echo "FRAMES 3 frames after 0 s; 0.050 s emulated"
echo "FRAMES result: PASS"
"""
FRAMES_RTL = ("palettes/NWARM.hex", "palettes/NCOOL.hex", "palettes/NHOT.hex", "palettes/PWARM.hex",
              "palettes/PCOOL.hex", "palettes/PHOT.hex", "Minnie/minnie_wave.hex", "ooo.hex", "ar_stub.hex",
              "vox_irom.hex", "vox_drom.hex")


def run_frames_cases(w):
    """run_frames.sh, copied into a scratch tree, with NOBUILD=1 and a
    stand-in binary (FRAMES_FAKE_VTB) whose mode is recorded: it passes with
    WORK/rtl's tables all there; it refuses to run (exit 2, naming the file)
    with no WORK/rtl, a dangling rtl link, or one table missing, as when a
    WORK shares another's obj_frames without its rtl/ (2.2.4's black
    pictures); it fails (exit 1) a run whose log has Verilator's
    "$readmem file not found" for one of those tables, although the bench
    says PASS; and it passes one whose only such warning is rtl/mem0.hex's,
    which every BUILD_TOP=tb_frames WORK prints."""
    import hashlib
    print("run_frames.sh on a scratch tree with a stand-in tb_frames binary:")
    d = os.path.join(w, "run_frames_sh")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "sim"))
    rf = os.path.join(d, "sim", "run_frames.sh")
    shutil.copy2(os.path.join(SIM, "run_frames.sh"), rf)
    img = os.path.join(d, "img.bin")
    open(img, "wb").write(b"\0")
    k = [0]

    def work(rtl):
        k[0] += 1
        wk = os.path.join(d, "work%d" % k[0])
        os.makedirs(os.path.join(wk, "obj_frames"))
        vtb = os.path.join(wk, "obj_frames", "vtb")
        open(vtb, "w").write(FRAMES_FAKE_VTB)
        os.chmod(vtb, 0o755)
        md5 = hashlib.md5(open(vtb, "rb").read()).hexdigest()
        open(os.path.join(wk, "obj_frames.mode"), "w").write(f"FRAMES_DEBUG=0 md5 {md5}\n")
        if rtl == "dangling":
            os.symlink(os.path.join(d, "no_such_rtl"), os.path.join(wk, "rtl"))
        elif rtl is not None:
            for f in rtl:
                p = os.path.join(wk, "rtl", f)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                open(p, "w").write("00\n")
        return wk

    def case(label, rtl, want_rc, want, env=None, want_log=None):
        env1 = {k: v for k, v in os.environ.items() if k not in ("FAKE_READMEM", "NAME", "FRAMES", "INPUTS",
                                                                  "ARM_DIV", "FRAMES_DEBUG", "RTL_TREE")}
        wk = work(rtl)
        env1.update(NOBUILD="1", VERILATOR="true", WORK=wk, **(env or {}))
        r =subprocess.run(["bash", rf, img], env=env1, capture_output=True, text=True)
        got = r.stdout + r.stderr
        if want_log:
            # the warning stays in run.log, not in the lines run_frames.sh prints
            try:
                got += open(os.path.join(wk, "runs", "img", "run.log"), errors="replace").read()
            except OSError:
                pass
        ok = r.returncode == want_rc and want in got and (want_log is None or want_log in got)
        results.append(ok)
        last = (got.strip().splitlines() or ["(no output)"])[-1]
        print(f"  {'ok   ' if ok else 'WRONG'} {label}: expected exit {want_rc}, got {r.returncode} ({last[:150]})")
        if not ok:
            print(f"        missing: {want!r}")
            print("\n".join("        " + l for l in got.splitlines()[-10:]))

    case("every table in WORK/rtl: the bench's PASS stands", FRAMES_RTL, 0, "FRAMES result: PASS")
    case("no WORK/rtl: refused before the run", None, 2, "rtl/palettes/NWARM.hex is missing")
    case("WORK/rtl a dangling link: refused", "dangling", 2, "rtl/palettes/NWARM.hex is missing")
    case("WORK/rtl without vox_drom.hex: refused", FRAMES_RTL[:-1], 2, "rtl/vox_drom.hex is missing")
    case("a table not found by the bench, which says PASS: FAIL", FRAMES_RTL, 1, "could not load a table",
         env={"FAKE_READMEM": "palettes/NWARM.hex"})
    case("only rtl/mem0.hex not found, the bench says PASS: PASS", FRAMES_RTL, 0, "FRAMES result: PASS",
         env={"FAKE_READMEM": "mem0.hex"}, want_log="rtl/mem0.hex:0: $readmem file not found")
    shutil.rmtree(d, ignore_errors=True)


def gates_sh_cases(w):
    """step7_gates.sh itself, copied into a scratch tree of its layout with
    stand-ins (GATES_FAKE_*) for run_frames.sh, frame_gate.py and
    selftest.py: --only or --skip with a name that is not a gate, and an
    empty --only, exit 2 before any gate runs; a run in which no gate ran
    exits 3; the frames gate runs plan 1.2 row 7's 16 images (its FRAMES16)
    by default, is PARTIAL (exit 3) and names the images not run for a
    FRAMES_LIST that leaves any out, and fails when an image fails; the
    selftest gate is PARTIAL and names each log-based input that is missing
    (--reset only with Fix B in the tree), and passes with all six."""
    src = os.path.join(SIM, "step7_gates.sh")
    text = open(src).read()
    m16 = re.search(r'(?ms)^FRAMES16="(.*?)"', text)
    mg = re.search(r"(?m)^GATES=\((.*?)\)", text)
    print("step7_gates.sh on a scratch tree with stand-in gate scripts:")
    if not m16 or not mg:
        print("  WRONG step7_gates.sh has no FRAMES16 or GATES line")
        results.append(False)
        return
    f16, gates = m16.group(1).split(), mg.group(1).split()
    d = os.path.join(w, "gates_sh")
    shutil.rmtree(d, ignore_errors=True)
    for rel, body, mode in (("sim/run_frames.sh", GATES_FAKE_FRAMES, 0o755),
                            ("sim/check/frame_gate.py", GATES_FAKE_GATE, 0o755),
                            ("sim/check/selftest.py", GATES_FAKE_SELFTEST, 0o755),
                            ("sim/tb_frames.sv", "// stand-in\n", 0o644),
                            ("src/fpga/ap_core.qsf", "# stand-in\n", 0o644),
                            ("src/fpga/core/sram_ctrl.sv", "// stand-in: t_new (Fix B in the tree)\n", 0o644)):
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(body)
        os.chmod(p, mode)
    gs = os.path.join(d, "sim", "step7_gates.sh")
    shutil.copy2(src, gs)
    games, r1 = os.path.join(d, "games"), os.path.join(d, "r1")
    juno = "Juno-First_demo_final_CGP_NTSC"
    os.makedirs(games)
    for n in f16 + [juno]:
        open(os.path.join(games, n + ".bin"), "wb").write(b"\0")
        os.makedirs(os.path.join(r1, n))
        open(os.path.join(r1, n, "fp.csv"), "w").write("frame,len_sys\n1,100\n")
    env0 = {k: v for k, v in os.environ.items() if k not in (
        "SIM_LOCK", "FRAMES_LIST", "FRAMES_GUARD", "FRAMES_RULE", "EXTRA_REF", "FAKE_FAIL")}
    env0.update(VERILATOR="true", GAMES=games, R1_DIR=r1)
    k = [0]

    def ran(out):
        p = os.path.join(out, "frames.log")
        return re.findall(r"(?m)^== (?!gate )(\S+)$", open(p).read()) if os.path.exists(p) else []

    def case(label, args, want_rc, want=(), env=None, pre=None, check=None):
        k[0] += 1
        out = os.path.join(d, "out%d" % k[0])
        os.makedirs(out)
        if pre:
            pre(out)
        r = subprocess.run(["bash", gs, "--out", out] + args, env=dict(env0, **(env or {})),
                           capture_output=True, text=True)
        logs = "".join(open(os.path.join(out, f), errors="replace").read()
                       for f in ("frames.log", "selftest.log") if os.path.exists(os.path.join(out, f)))
        got = r.stdout + r.stderr + logs
        miss = [x for x in want if x not in got]
        why = check(out, got) if check else ""
        ok = r.returncode == want_rc and not miss and not why
        results.append(ok)
        last = (r.stdout.strip().splitlines() or r.stderr.strip().splitlines() or ["(no output)"])[-1]
        print(f"  {'ok   ' if ok else 'WRONG'} {label}: expected exit {want_rc}, got {r.returncode} ({last[:150]})")
        if not ok:
            print(f"        missing: {miss}; {why}")
            print("\n".join("        " + l for l in got.splitlines()[-10:]))

    nosum = lambda out, got: "summary.txt written: a gate ran" if os.path.exists(os.path.join(out, "summary.txt")) else ""
    case("--only with two misspelt names (wrie, selftset)", ["--only", "wrie,selftset"], 2,
         ["unknown gate 'wrie'"], check=nosum)
    case("--skip with a name that is not a gate", ["--skip", "frames,no_such_gate"], 2,
         ["unknown gate 'no_such_gate'"], check=nosum)
    case("--only with no name", ["--only", ""], 2, ["--only names no gate"], check=nosum)
    case(f"--skip all {len(gates)} gates: no gate ran", ["--skip", ",".join(gates)], 3, ["no gate ran"])
    case("--only frames, FRAMES_LIST not set: plan 1.2 row 7's 16 images", ["--only", "frames"], 0,
         ["frames       PASS", "STEP7_GATES pass (1 gates)"],
         check=lambda out, got: "" if sorted(ran(out)) == sorted(f16) and len(f16) == 16
         else f"ran {ran(out)}, not the 16 of FRAMES16 ({len(f16)})")
    case("--only frames, FRAMES_LIST one of the 16 and the calibration image", ["--only", "frames"], 3,
         ["PARTIAL: 15 of plan 1.2 row 7's 16 images not run", f16[-1]],
         env={"FRAMES_LIST": f"{f16[0]} {juno}"})
    case("--only frames, FRAMES_LIST the calibration image alone (the old default)", ["--only", "frames"], 3,
         ["PARTIAL: 16 of plan 1.2 row 7's 16 images not run", "STEP7_GATES incomplete"], env={"FRAMES_LIST": juno})
    case("--only frames, the 16 with one failing", ["--only", "frames"], 1, ["frames       FAIL", "STEP7_GATES FAIL"],
         env={"FAKE_FAIL": f16[3]})
    case("--only frames, FRAMES_LIST one image, which fails: FAIL, not PARTIAL", ["--only", "frames"], 1,
         ["frames       FAIL"], env={"FRAMES_LIST": f16[0], "FAKE_FAIL": f16[0]})
    inputs = {"--run-sim": "run_sim.out", "--fp": "rs/fp/load_a26.csv", "--cartram": "cartram_work/cartram/logs/e7_b0.log",
              "--reset": "cartram_work/cartram/logs/rst_hif8_rd_rst_k0.log", "--artape": "rs/cartram/logs/artape_b0.log",
              "--extra": "extra_tests.out"}

    def put(names):
        def f(out):
            for o in names:
                p = os.path.join(out, inputs[o])
                os.makedirs(os.path.dirname(p), exist_ok=True)
                open(p, "w").write("stand-in\n")
        return f
    eref = os.path.join(d, "extra_ref.log")
    open(eref, "w").write("stand-in\n")
    case("--only selftest on an empty OUT: PARTIAL, the six inputs named", ["--only", "selftest"], 3,
         ["PARTIAL: every planted fault that ran was caught"] + [f"missing: {o} (" for o in inputs])
    case("--only selftest with all six inputs and EXTRA_REF", ["--only", "selftest"], 0,
         ["selftest     PASS"] + [f" {o} " for o in inputs], env={"EXTRA_REF": eref}, pre=put(inputs))
    case("--only selftest without the artape log", ["--only", "selftest"], 3,
         ["missing: --artape ("], env={"EXTRA_REF": eref}, pre=put([o for o in inputs if o != "--artape"]),
         check=lambda out, got: "" if got.count("  missing: ") == 1 else "more than --artape named")
    case("--only selftest with every log but no EXTRA_REF", ["--only", "selftest"], 3,
         ["missing: --extra ("], pre=put(inputs),
         check=lambda out, got: "" if got.count("  missing: ") == 1 else "more than --extra named")
    shutil.rmtree(d, ignore_errors=True)


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
    # G: the default rule (V1); S: the strict rule (--rule shift)
    G = lambda name, *extra, want: expect(name, [fg, ref, synth(w, name, mutate=extra[0] if extra else None), "--frames", "200"]
                                          + list(extra[1:]), want)
    S = lambda name, *extra, want: expect("shift: " + name, [fg, ref, synth(w, "s_" + name, mutate=extra[0] if extra else None),
                                                             "--frames", "200", "--rule", "shift"] + list(extra[1:]), want)
    expect("identical", [fg, ref, synth(w, "same"), "--frames", "200", "--scheme", "23"], True)
    expect("shift: identical", [fg, ref, synth(w, "same_s"), "--frames", "200", "--scheme", "23", "--rule", "shift"], True)

    # ---- the V1 rule (the default): len_sys, video, riot and each call's ARM
    # instruction count gated; audio counted, not gated
    def instr(k, dt, da=0):
        def m(fp, calls, slack, st):
            for c in calls:
                if c[0] == k:
                    c[8] += dt
                    c[9] += da
        return m

    def boot(by):          # every call requested in frame 0 held `by` clocks longer
        def m(calls):
            for c in calls:
                if c[1] == 0:
                    c[4] += by
        return m
    G("v1_audio_on_every_other_frame_counted", lambda fp, c, s, st: [setcol(fp, f, "audio") for f in range(2, 200, 2)],
      want=True)
    G("v1_audio_run_of_40_frames_counted", lambda fp, c, s, st: [setcol(fp, f, "audio") for f in range(60, 100)], want=True)
    G("v1_one_riot_byte", lambda fp, c, s, st: setcol(fp, 90, "riot"), want=False)
    G("v1_riot_release_shift_3_frames", m_shift(50, 52), want=False)
    G("v1_one_pixel_hash", lambda fp, c, s, st: setcol(fp, 100, "video"), want=False)
    G("v1_len_sys_one_clock", lambda fp, c, s, st: setcol(fp, 110, "len_sys"), want=False)
    G("v1_instructions_one_call", instr(77, 1), want=False)
    G("v1_instructions_last_call_of_frame_0", instr(2, -1), want=False)
    G("v1_instructions_split_differs_sum_equal", lambda fp, c, s, st: [instr(k, -1, 1)(fp, c, s, st) for k in range(1, 401)],
      want=True)
    G("v1_frame_1_video_after_a_frame_0_hold_differs", lambda fp, c, s, st: (boot(579)(c), setcol(fp, 1, "video")),
      want=True)
    G("v1_frame_1_video_with_equal_frame_0_holds", lambda fp, c, s, st: setcol(fp, 1, "video"), want=False)
    G("v1_frame_2_video_after_a_frame_0_hold_differs", lambda fp, c, s, st: (boot(579)(c), setcol(fp, 2, "video")),
      want=False)
    G("v1_frame_1_riot_after_a_frame_0_hold_differs", lambda fp, c, s, st: (boot(579)(c), setcol(fp, 1, "riot")),
      want=False)
    G("v1_frames_1_and_2_video_after_a_frame_0_hold_differs",
      lambda fp, c, s, st: (boot(579)(c), setcol(fp, 1, "video"), setcol(fp, 2, "video")), want=False)
    expect("v1_pocket_inputs (no bench parity)",
           [fg, ref, synth(w, "v1_pocket", inputs="the Pocket's"), "--frames", "200"], False)
    expect("v1_no_inputs_line", [fg, ref, synth(w, "v1_noinp", inputs=None), "--frames", "200"], False)
    expect("v1_pocket_inputs_with_--any-inputs",
           [fg, ref, synth(w, "v1_pocket_any", inputs="the Pocket's"), "--frames", "200", "--any-inputs"], True)
    noi = synth(w, "v1_noinstr")
    cp = os.path.join(noi, "calls.csv")
    lines = open(cp).read().splitlines()
    open(cp, "w").write("".join(",".join(l.split(",")[:7]) + "\n" for l in lines))
    expect("v1_calls_without_thumb_and_arm", [fg, ref, noi, "--frames", "200"], False)
    expect("v1_status_guard_unlocked_expected", [fg, synth(w, "ref_ul", status="unlocked"), synth(w, "v1_ul", status="unlocked"),
                                                 "--frames", "200", "--expect-guard", "unlocked"], True)

    # ---- the strict rule (--rule shift): riot and audio equal or release_shift
    S("release_shift_riot_3_frames", m_shift(50, 52), want=True)
    S("release_shift_audio_8_frames", m_shift(60, 67, "audio"), want=True)
    S("release_shift_too_long_9_frames", m_shift(70, 78), want=False)
    S("audio_run_of_40_frames", lambda fp, c, s, st: [setcol(fp, f, "audio") for f in range(60, 100)], want=False)
    # the difference must start where a call whose release differs is held:
    # the frame after it does not count, unless the hold reaches into it
    S("riot_starts_one_frame_after_the_shifted_call", lambda fp, c, s, st: (shift_call(c, 80), setcol(fp, 81, "riot")),
      want=False)
    # the column must be equal again within the file
    S("riot_from_a_shifted_frame_to_the_end_of_the_file", m_shift(195, 199), want=False)
    xref = synth(w, "ref_cross", frames=True, cross=(60, 70))
    expect("shift: riot_in_the_frame_a_crossing_hold_is_released_in",
           [fg, xref, synth(w, "cross_ok", frames=True, cross=(60, 70),
                            mutate=lambda fp, c, s, st: (shift_call(c, 60), setcol(fp, 61, "riot"), setcol(fp, 62, "riot"))),
            "--frames", "200", "--rule", "shift"], True)
    expect("shift: riot_two_frames_after_a_crossing_hold",
           [fg, xref, synth(w, "cross_late", frames=True, cross=(60, 70),
                            mutate=lambda fp, c, s, st: (shift_call(c, 70), setcol(fp, 72, "riot"))),
            "--frames", "200", "--rule", "shift"], False)
    expect("shift: riot_one_frame_after_a_hold_inside_its_frame (frames.csv)",
           [fg, xref, synth(w, "cross_inside", frames=True, cross=(60, 70),
                            mutate=lambda fp, c, s, st: (shift_call(c, 90), setcol(fp, 91, "riot"))),
            "--frames", "200", "--rule", "shift"], False)
    # R2's regime: every call's release differs (each frame holds a shifted
    # release), so only the settle rule and the cap bound what passes
    def every_call(by):
        def m(calls):
            for c in calls:
                c[4] += by
        return m

    def sparse(c, every, by, keep):
        def m(fp, calls, slack, st):
            every_call(by)(calls)
            for f in range(1, len(fp) + 1):
                if (f % every == 0) != keep:
                    setcol(fp, f, c)
        return m
    S("sparse_audio_on_7_of_8_frames_every_release_shifted", sparse("audio", 8, 3, keep=True), want=False)
    S("sparse_riot_on_every_10th_frame_every_release_shifted", sparse("riot", 10, 1, keep=False), want=False)
    S("every_release_shifted_columns_equal", lambda fp, c, s, st: every_call(5)(c), want=True)
    G("v1_every_release_shifted_columns_equal", lambda fp, c, s, st: every_call(5)(c), want=True)
    G("v1_sparse_audio_on_7_of_8_frames_every_release_shifted", sparse("audio", 8, 3, keep=True), want=True)
    G("v1_sparse_riot_on_every_10th_frame_every_release_shifted", sparse("riot", 10, 1, keep=False), want=False)

    def runs_at(spans, c="riot"):
        def m(fp, calls, slack, st):
            for lo, hi in spans:
                shift_call(calls, lo)
                for f in range(lo, hi + 1):
                    setcol(fp, f, c)
        return m
    S("release_shift_two_runs_2_frames_apart", runs_at([(50, 50), (53, 53)]), want=False)
    S("release_shift_two_runs_8_frames_apart", runs_at([(50, 51), (60, 61)]), want=True)
    S("release_shift_settles_only_5_frames_before_the_end", runs_at([(190, 193)]), want=False)
    S("release_shift_three_runs_over_the_cap_9_frames", runs_at([(30, 32), (60, 62), (90, 92)]), want=False)
    S("release_shift_three_runs_cap_raised_to_9", runs_at([(30, 32), (60, 62), (90, 92)]), "--shift-cap", "9", want=True)
    S("riot_without_shifted_release", lambda fp, c, s, st: setcol(fp, 90, "riot"), want=False)
    S("one_pixel_hash", lambda fp, c, s, st: setcol(fp, 100, "video"), want=False)
    S("frame_1_video_after_a_frame_0_hold_differs (no excuse)", lambda fp, c, s, st: (boot(579)(c), setcol(fp, 1, "video")),
      want=False)
    S("instructions_one_call (not checked)", instr(77, 1), want=True)

    # ---- both rules
    for R in (G, S):
        R("video_on_a_shifted_release", lambda fp, c, s, st: (shift_call(c, 120), setcol(fp, 120, "video")), want=False)
        R("truncated", lambda fp, c, s, st: fp.pop(), want=False)
        R("one_frame_shift", lambda fp, c, s, st: fp.__setitem__(slice(None), [[str(i + 1)] + fp[i + 1][1:] for i in range(len(fp) - 1)] + [[str(len(fp))] + fp[0][1:]]), want=False)
        R("call_missing", lambda fp, c, s, st: (c.pop(), st.__setitem__("calls", st["calls"] - 1)), want=False)
        R("late_call_extra", lambda fp, c, s, st: (s[10].__setitem__(3, -5), st.__setitem__("late", 1)), want=False)
        R("status_halt", lambda fp, c, s, st: st.__setitem__("halts", 1), want=False)
        R("status_psram", lambda fp, c, s, st: st.__setitem__("psram_viol", 2), want=False)
        R("status_unlock", lambda fp, c, s, st: st.__setitem__("unlocks", 1), want=False)
        R("status_guard_unlocked", lambda fp, c, s, st: st.__setitem__("guard", "unlocked"), want=False)
    # P27: a reference whose load was not seen (no calls)
    void = synth(w, "ref_void", calls_per=0)
    expect("reference_without_calls", [fg, void, synth(w, "cand_void", calls_per=0), "--frames", "200"], False)
    # --auto (step7_gates.sh g_frames): the mode from the scheme CAND's loader found. Each
    # run prints one verdict line, which agrees with the exit status (a strict
    # comparison that passes is not reported as a pass when the calls or the
    # status line then fail)
    def one_verdict(out, rc):
        v = [l for l in out.splitlines() if l.startswith("FRAME_GATE ")]
        if len(v) != 1:
            return f"{len(v)} verdict lines: " + " | ".join(v)
        return "" if v[0].startswith("FRAME_GATE pass") == (rc == 0) else "the verdict line disagrees with the exit status"
    A = lambda name, r, cand, want, *x: expect(name, [fg, "--auto", r, cand, "--frames", "200"] + list(x), want,
                                               check=one_verdict)
    A("auto_arm_identical", ref, synth(w, "auto_same"), True)
    A("auto_arm_one_riot_byte", ref, synth(w, "auto_riot", mutate=lambda fp, c, s, st: setcol(fp, 90, "riot")), False)
    A("auto_arm_audio_counted (V1)", ref, synth(w, "auto_audio", mutate=lambda fp, c, s, st: setcol(fp, 90, "audio")), True)
    A("auto_arm_audio_with_--rule_shift", ref, synth(w, "auto_audio_s", mutate=lambda fp, c, s, st: setcol(fp, 90, "audio")),
      False, "--rule", "shift")
    A("auto_arm_instructions_one_call", ref, synth(w, "auto_instr", mutate=instr(301, 7)), False)
    # P27: an ARM image whose R1 run makes no call is compared strictly, its load shown by detect2600's scheme
    vref = synth(w, "auto_ref_void", calls_per=0)
    A("auto_arm_reference_without_calls (P27: strict, identical)", vref, synth(w, "auto_cand_void", calls_per=0), True)
    A("auto_arm_no_calls, one riot byte (strict)", vref,
      synth(w, "auto_void_riot", calls_per=0, mutate=lambda fp, c, s, st: setcol(fp, 90, "riot")), False)
    A("auto_arm_no_calls, one audio frame (strict: audio gated too)", vref,
      synth(w, "auto_void_audio", calls_per=0, mutate=lambda fp, c, s, st: setcol(fp, 90, "audio")), False)
    A("auto_arm_no_calls in REF, calls in CAND", vref, synth(w, "auto_void_calls", calls_per=1), False)
    A("auto_arm_no_calls, CAND's STATUS halts 1", vref,
      synth(w, "auto_void_halt", calls_per=0, mutate=lambda fp, c, s, st: st.update(halts=1)), False)
    A("auto_arm_no_calls, one riot byte and CAND's STATUS halts 1", vref,
      synth(w, "auto_void_riot_halt", calls_per=0, mutate=lambda fp, c, s, st: (setcol(fp, 90, "riot"), st.update(halts=1))),
      False)
    A("auto_arm_no_calls, REF's detect2600 another ARM scheme", synth(w, "auto_ref_void21", calls_per=0, scheme=21),
      synth(w, "auto_cand_void23", calls_per=0), False)
    nocalls = synth(w, "auto_ref_nofile", calls_per=0)
    os.remove(os.path.join(nocalls, "calls.csv"))
    A("auto_arm_reference_with_no_calls.csv (void)", nocalls, synth(w, "auto_cand_nofile", calls_per=0), False)
    A("auto_scheme_differs_from_the_loader's", ref, synth(w, "auto_dpcp", scheme=21), False)
    A("auto_with_the_mapper_line (control)", ref, synth(w, "auto_nomap"), True)
    nomap = os.path.join(w, "auto_nomap", "run.log")
    open(nomap, "w").write("".join(l for l in open(nomap) if not l.startswith("OPTIONS")))
    A("auto_no_mapper_line", ref, os.path.dirname(nomap), False)
    nref = synth(w, "auto_f4_ref", calls_per=0, scheme=6)
    A("auto_non_arm_identical (strict)", nref, synth(w, "auto_f4_same", calls_per=0, scheme=6), True)
    A("auto_non_arm_one_riot_byte (strict)", nref,
      synth(w, "auto_f4_riot", calls_per=0, scheme=6, mutate=lambda fp, c, s, st: setcol(fp, 90, "riot")), False)
    A("auto_non_arm_with_calls", nref, synth(w, "auto_f4_calls", calls_per=1, scheme=6), False)
    # Spiders: overrun frames 150-165 excused when they are the late frames on both sides
    # (--overrun late, the rule up to 2.2.1; the --overrun ontime cases follow these)
    late = tuple(range(150, 166))
    sref = synth(w, "spiders_ref", late=late)

    def sp(extra_after=False, riot_run=None, audio_after=False):
        def m(fp, c, s, st):
            for f in range(150, 166):
                setcol(fp, f, "video")
                setcol(fp, f, "len_sys")
                if riot_run:
                    setcol(fp, f, "riot")
            if extra_after:
                setcol(fp, 170, "riot")
            if audio_after:
                for f in range(166, 175):
                    setcol(fp, f, "audio")
            if riot_run:
                shift_call(c, riot_run[0])
                for f in range(riot_run[0], riot_run[1] + 1):
                    setcol(fp, f, "riot")
        return m
    for rule in ([], ["--rule", "shift"]):
        tag = "" if not rule else "shift: "
        expect(tag + "spiders_excused", [fg, sref, synth(w, "spiders_ok", mutate=sp(), late=late), "--frames", "200",
                                         "--excuse", "150-165", "--overrun", "late"] + rule, True)
        expect(tag + "spiders_differs_after", [fg, sref, synth(w, "spiders_bad", mutate=sp(True), late=late), "--frames",
                                               "200", "--excuse", "150-165", "--overrun", "late"] + rule, False)
        expect(tag + "spiders_not_the_late_frames", [fg, ref, synth(w, "spiders_nolate", mutate=sp()), "--frames", "200",
                                                     "--excuse", "150-165", "--overrun", "late"] + rule, False)
    expect("v1_spiders_audio_differs_after (counted)",
           [fg, sref, synth(w, "spiders_aud", mutate=sp(audio_after=True), late=late), "--frames", "200",
            "--excuse", "150-165", "--overrun", "late"], True)
    expect("shift: spiders_audio_differs_after",
           [fg, sref, synth(w, "spiders_aud_s", mutate=sp(audio_after=True), late=late), "--frames", "200",
            "--excuse", "150-165", "--overrun", "late", "--rule", "shift"], False)
    # a release_shift run must settle on truly equal frames: the excused
    # overrun frames (riot differing there too) do not count
    expect("shift: spiders_release_shift_3_frames_before_the_overrun",
           [fg, sref, synth(w, "spiders_rs_near", mutate=sp(riot_run=(145, 147)), late=late), "--frames", "200",
            "--excuse", "150-165", "--overrun", "late", "--rule", "shift"], False)
    expect("shift: spiders_release_shift_well_before_the_overrun",
           [fg, sref, synth(w, "spiders_rs_far", mutate=sp(riot_run=(120, 122)), late=late), "--frames", "200",
            "--excuse", "150-165", "--overrun", "late", "--rule", "shift"], True)
    # --overrun ontime (the default; step-10 plan decision 4): REF overruns in
    # 150-165, CAND is on time there (no late call, every frame as long as frame 149)
    def spo(long_frame=False, riot_after=False):
        def m(fp, c, s, st):
            for f in range(150, 166):
                setcol(fp, f, "video")
            if long_frame:
                setcol(fp, 157, "len_sys")
            if riot_after:
                setcol(fp, 170, "riot")
        return m
    for rule in ([], ["--rule", "shift"]):
        tag = "" if not rule else "shift: "
        expect(tag + "spiders_ontime", [fg, sref, synth(w, "spiders_on", mutate=spo()), "--frames", "200",
                                        "--excuse", "150-165", "--overrun", "ontime"] + rule, True)
        expect(tag + "spiders_ontime_by_default (no --overrun)", [fg, sref, synth(w, "spiders_on_d", mutate=spo()),
                                                                  "--frames", "200", "--excuse", "150-165"] + rule, True)
        expect(tag + "spiders_ontime_but_late", [fg, sref, synth(w, "spiders_on_late", mutate=sp(), late=late),
                                                 "--frames", "200", "--excuse", "150-165", "--overrun", "ontime"] + rule, False)
        expect(tag + "spiders_ontime_one_long_frame", [fg, sref, synth(w, "spiders_on_long", mutate=spo(long_frame=True)),
                                                       "--frames", "200", "--excuse", "150-165"] + rule, False)
        expect(tag + "spiders_ontime_differs_after", [fg, sref, synth(w, "spiders_on_after", mutate=spo(riot_after=True)),
                                                      "--frames", "200", "--excuse", "150-165"] + rule, False)
        expect(tag + "spiders_ontime_ref_not_late", [fg, ref, synth(w, "spiders_on_noref", mutate=spo()),
                                                     "--frames", "200", "--excuse", "150-165"] + rule, False)
        # CAND without slack.csv: its late calls cannot be checked, so the frames are not
        # excused (with --no-status the STATUS line does not stand in for it)
        noslack = synth(w, "spiders_on_noslack", mutate=spo())
        os.remove(os.path.join(noslack, "slack.csv"))
        expect(tag + "spiders_ontime_cand_without_slack", [fg, sref, noslack, "--frames", "200", "--excuse", "150-165",
                                                           "--no-status"] + rule, False,
               check=lambda out, rc: "" if "CAND has no slack.csv" in out else "the missing slack.csv is not named")
    expect("v1_spiders_riot_release_shift_well_before_the_overrun",
           [fg, sref, synth(w, "spiders_rs_far_v1", mutate=sp(riot_run=(120, 122)), late=late), "--frames", "200",
            "--excuse", "150-165", "--overrun", "late"], False)


def main():
    p = argparse.ArgumentParser(description="planted faults for the step-7 checkers")
    p.add_argument("--work", required=True)
    p.add_argument("--run-sim")
    p.add_argument("--extra")
    p.add_argument("--extra-ref")
    p.add_argument("--extra-dir")
    p.add_argument("--fp")
    p.add_argument("--cartram")
    p.add_argument("--reset", help="a passing reset run's log (cartram2600_test.py reset: rst_hif8_rd_rst_k0)")
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
    if a.reset:
        reset_cases(a.reset, w)
    if a.artape:
        artape_cases(a.artape, a.artape_ref, w)
    if a.tools:
        guard_cases(w)
        hygiene_cases(w)
        pp_equiv_cases(w)
    div_cases(w)
    gate_cases(w)
    wire_cases(w)
    gates_sh_cases(w)
    run_frames_cases(w)
    skipped = [o for o, v in (("--run-sim", a.run_sim), ("--extra", a.extra), ("--fp", a.fp), ("--cartram", a.cartram),
                              ("--reset", a.reset), ("--artape", a.artape), ("--tools", a.tools)) if not v]
    print("groups not run (no input given): " + (", ".join(skipped) if skipped else "none"))
    print(f"SELFTEST {'pass' if all(results) else 'FAIL'} ({sum(results)} of {len(results)} cases as expected)")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
