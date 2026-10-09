#!/usr/bin/env python3
"""Planted faults: each checker must pass a good input and fail each fault
(DARIA step 7, docs/daria_step7/plan.md 3.6 unit gate 1, 7.1 and 7.2 for I4).

  selftest.py --work DIR [--run-sim LOG] [--extra LOG --extra-ref REF
              [--extra-dir DIR]] [--fp FILE] [--cartram LOG]

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
                   out of order
  --fp FILE        a tb_load/tb_system fp.csv: frame_gate --strict on a
                   truncated copy, a one-frame shift, one RIOT hash, one
                   pixel (video) hash and a one-clock len_sys change
  --cartram LOG    a passing tb_cartram log (cartram2600_test.py's, E7 blend
                   off): a wrong byte, a lost write, a bucket past s19, a
                   changed read count
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


def run(cmd):
    r = subprocess.run([sys.executable] + cmd, capture_output=True, text=True)
    return r.returncode, r.stdout


def expect(name, cmd, want_pass):
    rc, out = run(cmd)
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
    cases = {
        "truncated": rows[:-1],
        "truncated_line": [list(x) for x in rows[:-1]] + [rows[-1][:3]],
        "one_frame_shift": [[str(i + 1)] + rows[i + 1][1:] for i in range(n - 1)] + [[str(n)] + rows[0][1:]],
        "riot_hash": changed("riot", k),
        "pixel_hash": changed("video", k),
        "len_sys_one_clock": changed("len_sys", k),
    }
    for c, r in cases.items():
        p = os.path.join(w, f"fp_{c}.csv")
        write_fp(p, head, r)
        expect(c, [fg, "--strict", fp, p], False)


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
    }
    for c, fn in cases.items():
        expect(c, [ct, "check", plant(log, os.path.join(w, f"cartram_{c}.log"), fn), "--image", "e7", "--blend", "0"], False)


# ---------------------------------------------------------------- synthetic R1/R2
def synth(w, name, n=200, calls_per=2, mutate=None, late=(), status="locked"):
    rnd = random.Random(1)
    d = os.path.join(w, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    fp = [[str(f), "238944"] + [format(rnd.getrandbits(64), "016x") for _ in range(3)] for f in range(1, n)]
    calls, slack, k = [], [], 0
    for f in range(0, n):
        for j in range(calls_per):
            k += 1
            calls.append([k, f, 10 + 100 * j, 1000 * k, 3000 + 7 * (k % 5), 2999, "00000000"])
            slack.append([k, 1, 500, -100 if f in late else 4000, "f000"])
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
    gate_cases(w)
    print(f"SELFTEST {'pass' if all(results) else 'FAIL'} ({sum(results)} of {len(results)} cases as expected)")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
