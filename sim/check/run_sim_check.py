#!/usr/bin/env python3
"""Verdict of a run_sim.sh log, as one exit code (DARIA step 7, plan 1.2 row 3).

  run_sim_check.py LOG [--build plain|daria|auto] [--audf 0,7,14,31]
                       [--ref REF_LOG]

run_sim.sh prints measurements and a few verdicts (BIOS_BOOT, BUPCHIP_E2E,
PLL_REGION, DARIA) and exits 0 whatever they say. This checks every case
against its expected lines and fails on:
  - a section that is missing, or says "skipped" (no BIOS image, no
    firmware): a skipped section is not a pass;
  - any FAIL verdict, a MISSING pattern, a simulator error;
  - a TONE ratio outside 0.990-1.010 where the case must play its tone. The
    BIOS cases that boot a 7800 image or an empty slot through the BIOS
    legitimately print ratio 0.000 (the BIOS is still running when the tone
    window closes); there only the BOOT lines count;
  - video geometry other than the documented frame (lines, pixels, PAL flag,
    frame length in clk_sys) for each case, and a last FRAME line other than
    the run's own (FRAME 17 at 300 ms; FRAME 75 for the PAL 2600 case's
    +long run): tb_system prints its FRAME lines only when the run ends, so
    an earlier number means a run that stopped or changed length;
  - a "SIMULATOR EXIT N" line: a bench that exited non-zero, e.g. on a
    $fatal, in a case whose output run_sim.sh pipes through grep (which
    drops the "%Fatal" line);
  - the load, PLL retune, audio filter and virtual axis lines other than
    expected;
  - "exit N" with N != 0 when the log records the script's exit status.
DARIA section: in the DARIA build (--build daria, or auto from run_sim.sh's
"POCKET_DARIA 1" line) "DARIA pass" is required. In the plain build the
section prints that it is inactive; that is reported, and is not a pass of
anything. A log from before step 7 (no "-- run_sim.sh:" line) has no DARIA
section at all; it is then checked as a plain build.
--ref REF_LOG also compares every measurement and verdict line with another
log (e.g. the same tree before a bench change): any difference fails.
Exit status: 0 pass, 1 fail, 2 usage.
SPDX-License-Identifier: MIT
"""
import argparse
import re
import sys

NTSC78 = r"238804 clk_sys \(59\.958 Hz\), active lines 224, active pixels/line 372, video PAL 0"
TONE = re.compile(r"^\s*TONE (?:AUDC0=4|from loaded cart) AUDF0=(\d+): measured ([0-9.]+) Hz, "
                  r"TIA reference ([0-9.]+) Hz, ratio ([0-9.]+)$")
VERDICT_LINE = re.compile(r"^\s*(TONE|FRAME|\+|LOAD|HSC|BOOT|IMAGE2|BIOS_BOOT|BUPCHIP|PCM|ours|song|reference|"
                          r"NTSC|PAL ->|PLL_REGION|AUDIO|AXIS|DARIA|smoke_|digital_)")
AXIS = [
    r"AXIS start at 128",
    r"AXIS 16 ms tap right: 129",
    r"AXIS right to the end\s+305\s+ms to reach 255",
    r"AXIS left across, normal\s+511\s+ms to reach 0",
    r"AXIS right across, fast \(Y\)\s+265\s+ms to reach 255",
    r"AXIS left 64, slow \(X\)\s+677\s+ms to reach 191",
    r"AXIS driving, 1 s right: 18 gray steps, 51 ms apart at full speed",
    r"AXIS driving, 1 s right fast \(Y\): 37 gray steps, 25 ms apart at full speed",
    r"AXIS stick 200 -> position 200 after 40 ms",
    r"AXIS stick 60 -> position 60 after 40 ms",
    r"AXIS D-pad press \(rest now 60\), then stick 250: 250",
    r"AXIS driving, stick pushed fully right 1 s: 31 gray steps, 32 ms apart",
]
# BIOS cases: title prefix -> (required patterns, does its TONE line have to pass)
BIOS_CASES = [
    ("2600 image, Skip BIOS off", [
        r"BOOT 1 at \d+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1",
        r"BOOT 1 vector: \$f000 from the cartridge slot, first opcode fetch at \$f000 from the cartridge slot",
        r"BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1"], True),
    ("the same, the BIOS loaded after the cartridge", [
        r"BOOT 1 at \d+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1",
        r"BOOT 1 vector: \$f000 from the cartridge slot, first opcode fetch at \$f000 from the cartridge slot",
        r"BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1"], True),
    ("7800 image, Skip BIOS off", [
        r"BOOT 1 at \d+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 1",
        r"BOOT 1 vector: \$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \$[0-9a-f]{4} from the BIOS ROM",
        r"BOOT 1 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0"], False),
    ("no cartridge, Skip BIOS off", [
        r"BOOT 1 at \d+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 0",
        r"BOOT 1 vector: \$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \$[0-9a-f]{4} from the BIOS ROM",
        r"BOOT 1 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0"], False),
    ("7800 image, then a 2600 image", [
        r"BOOT 1 at \d+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 1",
        r"BOOT 1 vector: \$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \$[0-9a-f]{4} from the BIOS ROM",
        r"BOOT 1 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0",
        r"IMAGE2 load_test\.a26 loaded at \d+ ms: 4096 bytes, tia_mode=0, mapper 0",
        r"BOOT 2 at \d+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1",
        r"BOOT 2 vector: \$f000 from the cartridge slot, first opcode fetch at \$f000 from the cartridge slot",
        r"BOOT 2 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1"], None),
    ("2600 image, then a 7800 image", [
        r"BOOT 1 at \d+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1",
        r"BOOT 1 vector: \$f000 from the cartridge slot, first opcode fetch at \$f000 from the cartridge slot",
        r"BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1",
        r"IMAGE2 load_test_c7\.a78 loaded at \d+ ms: 16512 bytes, tia_mode=0, mapper 0",
        r"BOOT 2 at \d+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 1",
        r"BOOT 2 vector: \$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \$[0-9a-f]{4} from the BIOS ROM",
        r"BOOT 2 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0"], None),
    ("2600 image, Skip BIOS on", [
        r"BOOT 1 at \d+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1",
        r"BOOT 1 vector: \$f000 from the cartridge slot, first opcode fetch at \$f000 from the cartridge slot",
        r"BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1"], True),
    ("7800 image, Skip BIOS on", [
        r"BOOT 1 at \d+ ms: use_bios 0, bypass_bios 1, tia_mode 0, cart_present 1",
        r"BOOT 1 vector: \$c000 from the cartridge slot, first opcode fetch at \$c000 from the cartridge slot",
        r"BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 0"], True),
]


class Log:
    def __init__(self, path):
        self.lines = open(path, "rb").read().decode("utf-8", "replace").splitlines()
        self.sections = []          # (header, [lines])
        cur = ("(start)", [])
        for l in self.lines:
            if l.startswith("-- "):
                self.sections.append(cur)
                cur = (l, [])
            else:
                cur[1].append(l)
        self.sections.append(cur)

    def section(self, prefix):
        for h, body in self.sections:
            if h.startswith(prefix):
                return h, body
        return None, None


def tone_ok(line, audf=None):
    m = TONE.match(line)
    if not m:
        return False
    if audf is not None and int(m.group(1)) != audf:
        return False
    return 0.990 <= float(m.group(4)) <= 1.010


def check(log, build, audfs):
    L = Log(log)
    bad, notes = [], []

    def need(body, pat, what):
        if body is None or not any(re.fullmatch(pat, x.strip()) for x in body):
            bad.append(f"{what}: missing /{pat}/")

    # global rules
    for x in L.lines:
        if re.search(r":\s*skipped\b", x):
            bad.append("skipped section: " + x.strip())
        if re.search(r"\bFAIL\b", x):
            bad.append("FAIL: " + x.strip())
        if "MISSING:" in x:
            bad.append(x.strip())
        if re.search(r"^(\[\d+\] )?%(Error|Fatal)|Assertion failed", x.strip()):
            bad.append("simulator: " + x.strip()[:160])
        m = re.match(r"^exit (\d+)$", x.strip())
        if m and m.group(1) != "0":
            bad.append("run_sim.sh exit status " + m.group(1))
        if x.startswith("SIMULATOR EXIT"):
            bad.append("a bench exited non-zero: " + x.strip()[:160])
    new_format = any(x.startswith("-- run_sim.sh:") for x in L.lines)
    if build == "auto":
        build = "daria" if any(re.match(r"^-- run_sim\.sh: .*POCKET_DARIA 1,", x) for x in L.lines) else "plain"

    # 7800 tones: the lines before "-- border hidden:"
    body = []
    for h, b in L.sections:
        if h.startswith("-- border hidden"):
            break
        body += b
    for a in audfs:
        if not any(tone_ok(x, a) for x in body):
            bad.append(f"7800 tone AUDF0={a}: no TONE line with ratio 0.990-1.010")
    n78 = sum(1 for x in body if re.fullmatch(r"FRAME 17: " + NTSC78, x.strip()))
    if n78 != len(audfs):
        bad.append(f"7800 tone frames: {n78} of {len(audfs)} FRAME lines are FRAME 17, the NTSC 7800 frame")
    h, b = L.section("-- border hidden")
    need(b, r"FRAME 17: 238804 clk_sys \(59\.958 Hz\), active lines 224, active pixels/line 320, video PAL 0", "border hidden")
    h, b = L.section("-- 2600 mode")
    for a in (0, 14):
        if not b or not any(tone_ok(x, a) for x in b):
            bad.append(f"2600 tone AUDF0={a}: no TONE line with ratio 0.990-1.010")
    if not b or sum(1 for x in b if re.fullmatch(
            r"FRAME 17: 238944 clk_sys \(59\.923 Hz\), active lines 240, active pixels/line 160, video PAL 0", x.strip())) != 2:
        bad.append("2600 frames: expected two FRAME 17 lines, 240-line 160-pixel NTSC frames")
    h, b = L.section("-- PAL and overscan geometry")
    need(b, r"\+pal: 284204 clk_sys \(50\.380 Hz\), active lines 274, active pixels/line 372, video PAL 1", "+pal")
    need(b, r"\+overscan: 238804 clk_sys \(59\.958 Hz\), active lines 242, active pixels/line 372, video PAL 0", "+overscan")
    need(b, r"\+overscan \+pal: 284204 clk_sys \(50\.380 Hz\), active lines 274, active pixels/line 372, video PAL 1", "+overscan +pal")
    h, b = L.section("-- PAL 2600 frame")
    need(b, r"FRAME 75: 284544 clk_sys \(50\.320 Hz\), active lines 288, active pixels/line 160, video PAL 1", "PAL 2600 frame")
    h, b = L.section("-- load an A78")
    need(b, r"HSC_EN 0 \(setting 0, firmware loaded 0\)", "A78 load")
    need(b, r"LOAD 16512 bytes, header ATARI, cart_is_7800=1, cart_size=16384, tia_mode=0, payload mismatches=0", "A78 load")
    need(b, r"HSC word 5 = 11223344, bytes 20\.\.23 = 11 22 33 44 \(expect 11223344 / 11 22 33 44\)", "A78 load")
    if not b or not any(tone_ok(x, 7) for x in b):
        bad.append("A78 load: no tone AUDF0=7 with ratio 0.990-1.010")
    h, b = L.section("-- load a headerless 2600 image")
    need(b, r"LOAD 4096 bytes, header .*, cart_is_7800=0, cart_size=4096, tia_mode=1, payload mismatches=0", "2600 load")
    if not b or not any(tone_ok(x, 14) for x in b):
        bad.append("2600 load: no tone AUDF0=14 with ratio 0.990-1.010")

    # BIOS boot rule
    h, b = L.section("-- 7800 BIOS")
    if b is None:
        bad.append("BIOS boot rule: section missing")
    else:
        if "BIOS_BOOT pass" not in [x.strip() for x in b]:
            bad.append("BIOS boot rule: no 'BIOS_BOOT pass'")
        # split into cases at the "  title:" lines
        cases, cur = [], None
        for x in b:
            if re.match(r"^  \S.*:$", x):
                cur = (x.strip(), [])
                cases.append(cur)
            elif cur:
                cur[1].append(x.strip())
        for title, pats, tone in BIOS_CASES:
            hit = [c for c in cases if c[0].startswith(title)]
            if len(hit) != 1:
                bad.append(f"BIOS case '{title}': {len(hit)} found")
                continue
            for p in pats:
                if not any(re.fullmatch(p, x) for x in hit[0][1]):
                    bad.append(f"BIOS case '{title}': missing /{p}/")
            tl = [x for x in hit[0][1] if x.startswith("TONE")]
            if tone is True and not any(tone_ok(x) for x in tl):
                bad.append(f"BIOS case '{title}': its tone must play (ratio 0.990-1.010): {tl}")
            if tone is False and len(tl) != 1:
                bad.append(f"BIOS case '{title}': expected one TONE line (any ratio: the BIOS is running)")

    # BupChip end to end
    h, b = L.section("-- BupChip end to end")
    if b is None:
        bad.append("BupChip end to end: section missing")
    else:
        s = [x.strip() for x in b]
        if "BUPCHIP_E2E pass" not in s:
            bad.append("BupChip end to end: no 'BUPCHIP_E2E pass'")
        if sum(1 for x in s if x.startswith("PCM IDENTICAL")) != 2:
            bad.append("BupChip end to end: expected two 'PCM IDENTICAL' lines")
        if not any(re.match(r"BUPCHIP result: fw_loaded=1 asset_ready=1 cpu_run=1 halted=0 halt_code=0 .* under=0 over=0 "
                            r".*arsc_bad=0 psram_viol=0$", x) for x in s):
            bad.append("BupChip end to end: the result line with the firmware is not clean")

    # DARIA
    h, b = L.section("-- DARIA")
    if build == "daria":
        if h is None or "inactive" in h:
            bad.append("DARIA build: the DARIA section did not run")
        elif "DARIA pass" not in [x.strip() for x in b]:
            bad.append("DARIA build: no 'DARIA pass'")
        else:
            notes.append("DARIA section: pass")
    else:
        if h is None:
            if new_format:
                bad.append("DARIA section line missing from a step-7 run_sim.sh log")
            notes.append("DARIA section: absent (a log from before step 7); plain build, not counted")
        elif "inactive" in h:
            notes.append("DARIA section: inactive (no POCKET_DARIA); not counted as a pass")
        else:
            bad.append("plain build, but the DARIA section ran: " + h)

    # PLL retune
    h, b = L.section("-- PAL/NTSC PLL retune")
    need(b, r"NTSC -> PAL: fraction 737741760, reset held 3\.5 us before the start and 3\.5 us after relock", "PLL retune")
    need(b, r"PAL -> NTSC: fraction 1100363522, reset held 3\.5 us before the start and 3\.5 us after relock", "PLL retune")
    need(b, r"PLL_REGION pass \(0 errors\)", "PLL retune")
    # audio filter
    h, b = L.section("-- audio filter")
    m = None
    for x in b or []:
        m = re.fullmatch(r"AUDIO tone: min (-?\d+) max (-?\d+) mean (-?\d+) \(expect.*\)", x.strip()) or m
    if not m:
        bad.append("audio filter: no tone line")
    else:
        mn, mx, mean = (int(v) for v in m.groups())
        if abs(mn + 16383) > 200 or abs(mx - 16383) > 200 or abs(mean) > 64:
            bad.append(f"audio filter: tone min {mn} max {mx} mean {mean}, expect about -16383 / +16383 / 0")
    m = None
    for x in b or []:
        m = re.fullmatch(r"AUDIO silence after 2 s: (-?\d+) \(expect near 0\)", x.strip()) or m
    if not m or abs(int(m.group(1))) > 16:
        bad.append("audio filter: silence not near 0")
    # virtual axis
    h, b = L.section("-- virtual paddle")
    for p in AXIS:
        need(b, p, "virtual axis")
    return bad, notes, build


def verdict_lines(path):
    out = []
    for x in open(path, "rb").read().decode("utf-8", "replace").splitlines():
        if VERDICT_LINE.match(x):
            out.append(x.strip())
    return out


def main():
    p = argparse.ArgumentParser(description="run_sim.sh log checker")
    p.add_argument("log")
    p.add_argument("--build", choices=("plain", "daria", "auto"), default="auto")
    p.add_argument("--audf", default="0,7,14,31")
    p.add_argument("--ref")
    a = p.parse_args()
    bad, notes, build = check(a.log, a.build, [int(x) for x in a.audf.split(",")])
    if a.ref:
        mine, ref = verdict_lines(a.log), verdict_lines(a.ref)
        if mine != ref:
            import difflib
            d = [l for l in difflib.unified_diff(ref, mine, "ref", "log", lineterm="", n=0)
                 if not l.startswith(("---", "+++", "@@"))]
            bad.append(f"differs from the reference in {len(d)} line(s)")
            for l in d[:20]:
                bad.append("  " + l)
        else:
            notes.append(f"all {len(mine)} measurement and verdict lines equal the reference's")
    print(f"run_sim_check {a.log} ({build} build)")
    for n in notes:
        print("  note: " + n)
    for b in bad:
        print("  FAIL: " + b)
    print("RUN_SIM " + ("pass" if not bad else f"FAIL ({len(bad)} finding(s))"))
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
