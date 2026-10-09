#!/usr/bin/env python3
"""Verdict of an extra_tests.sh log, as one exit code (DARIA step 7, plan 1.2 row 4).

  extra_tests_check.py LOG [--ref REF_LOG] [--extra-dir DIR] [--ar-tape]

extra_tests.sh prints what it measured and its expectations in prose; this
turns every section into rules:
  multisprite   the LOAD line, and the header's rule (every sprite matches
                gfx/herodown1.png row for row, nothing above or below it):
                the log's MULTISPRITE verdict (sim/check/multisprite_check.py,
                which extra_tests.sh runs), or, for a log from before step 7,
                that check run here on --extra-dir DIR/multisprite
  POKEY $450, POKEY $4000, DLI
                the LOAD lines; the DLI probe (60 NMIs, main-loop writes in
                the hundreds of thousands, 61 AUDF1 writes); and the audio
                statistics equal to the reference build's, line for line
                (--ref REF_LOG; without it these sections fail: there is no
                domain threshold, plan 10 item 9)
  SaveKey       pass tone and the cart's 8 bytes in the save RAM, twice; the
                fail tone; the round trip with exactly the 8 bytes the cart
                wrote differing (a log from before step 7 used a random save
                file, which can hold one of those bytes already: 6-8 there)
  Firmware      HSC_EN 0 without the file; both files 0 bytes differ, HSC_EN
                1, the save intact; hsc.a78's header skipped
  Supercharger  full load: magenta $54 / AUDF0 5 within 0.2 s and ARCHECK 0
                differ; multiload: red $44 / AUDF0 7, then green $c4 / AUDF0
                14 after about 1 s; two loads numbered 0: blue $84 / AUDF0 3,
                the reset, then yellow $1e / AUDF0 20; with AR_TAPE=1 (or
                --ar-tape, which requires it): the tape full load's ARCHECK 0
                differ and the tape multiload red then green
  cartridge RAM the CARTRAM_MATRIX and CARTRAM_S19 verdicts
                (cartram2600_test.py), in logs of the step-7 script, which
                runs them before the network clones
and fails on any "FAIL", "skipped" or simulator error, and on "exit N" with
N != 0 when the log records the exit status.
Exit status: 0 pass, 1 fail, 2 usage.
SPDX-License-Identifier: MIT
"""
import argparse
import os
import re
import subprocess
import sys

TONE = re.compile(r"^TONE from loaded cart AUDF0=(\d+): measured ([0-9.]+) Hz, TIA reference ([0-9.]+) Hz, ratio ([0-9.]+)$")


def sections(lines):
    out, cur = [], ("(start)", [])
    for l in lines:
        if l.startswith("-- "):
            out.append(cur)
            cur = (l, [])
        else:
            cur[1].append(l)
    out.append(cur)
    return out


def section(secs, prefix):
    for h, b in secs:
        if h.startswith(prefix):
            return [x.rstrip() for x in b]
    return None


def cases(body):
    """Split a section at its '  title:' lines."""
    out, cur = [], None
    for x in body or []:
        if re.match(r"^  \S.*:$", x):
            cur = (x.strip(), [])
            out.append(cur)
        elif cur:
            cur[1].append(x.strip())
    return out


def tone_ok(lines, audf):
    for x in lines:
        m = TONE.match(x.strip())
        if m and int(m.group(1)) == audf and 0.990 <= float(m.group(4)) <= 1.010:
            return True
    return False


def ar_events(lines):
    ev = []
    for x in lines:
        m = re.match(r"^AR (\d+) ms: (AUDF0 = (\d+)|COLUBK = \$([0-9a-f]{2}))$", x.strip())
        if m:
            ev.append((int(m.group(1)), "audf" if m.group(3) else "colubk", m.group(3) or m.group(4)))
    return ev


def stats(body):
    return [x.strip() for x in body or [] if re.match(r"^\s*t=", x)]


def check(a):
    lines = open(a.log, "rb").read().decode("utf-8", "replace").splitlines()
    secs = sections(lines)
    new = any(x.startswith("-- extra_tests.sh:") for x in lines)
    bad, notes = [], []
    ref = sections(open(a.ref, "rb").read().decode("utf-8", "replace").splitlines()) if a.ref else None

    for x in lines:
        if re.search(r"skipped", x): bad.append("skipped: " + x.strip())
        if re.search(r"\bFAIL\b", x): bad.append("FAIL: " + x.strip())
        if re.search(r"^(\[\d+\] )?%(Error|Fatal)|Assertion failed", x.strip()): bad.append("simulator: " + x.strip()[:160])
        m = re.match(r"^exit (\d+)$", x.strip())
        if m and m.group(1) != "0": bad.append("extra_tests.sh exit status " + m.group(1))

    def need(body, pat, what):
        if body is None or not any(re.fullmatch(pat, x.strip()) for x in body):
            bad.append(f"{what}: missing /{pat}/")

    # multisprite
    b = section(secs, "-- multisprite")
    if b is None:
        bad.append("multisprite: section missing")
    else:
        need(b, r"LOAD 32896 bytes, header ATARI, cart_is_7800=1, cart_size=32768, tia_mode=0, payload mismatches=0", "multisprite")
        if any(x.strip() == "MULTISPRITE pass" for x in b):
            notes.append("multisprite: the header's rule holds (MULTISPRITE pass)")
        elif new:
            bad.append("multisprite: no 'MULTISPRITE pass'")
        elif a.extra_dir:
            r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "multisprite_check.py"),
                                os.path.join(a.extra_dir, "multisprite")], capture_output=True, text=True)
            if r.returncode == 0:
                notes.append("multisprite: the header's rule holds (checked here on --extra-dir)")
            else:
                bad.append("multisprite: " + (r.stdout.strip().splitlines() or ["check failed"])[-1])
                bad += ["  " + l for l in r.stdout.splitlines() if "FAIL:" in l]
        else:
            bad.append("multisprite: the rule was not checked (a log from before step 7: give --extra-dir)")

    # POKEY and DLI
    for name, prefix, loadpat in (
            ("POKEY $450", "-- POKEY at $450", r"LOAD 32896 bytes, header ATARI, cart_is_7800=1, cart_size=32768, tia_mode=0, payload mismatches=0"),
            ("POKEY $4000", "-- POKEY at $4000", r"LOAD 32896 bytes, header ATARI, cart_is_7800=1, cart_size=32768, tia_mode=0, payload mismatches=0"),
            ("DLI", "-- DLI + WSYNC", r"LOAD 16512 bytes, header ATARI, cart_is_7800=1, cart_size=16384, tia_mode=0, payload mismatches=0")):
        b = section(secs, prefix)
        if b is None:
            bad.append(f"{name}: section missing")
            continue
        need(b, loadpat, name)
        st = stats(b)
        if not st:
            bad.append(f"{name}: no audio statistics")
        elif not any(int(re.search(r"levels=(\d+)", s).group(1)) > 1 for s in st):
            bad.append(f"{name}: silent (one level throughout)")
        if name == "DLI":
            m = None
            for x in b:
                m = re.fullmatch(r"PROBE NMIs (\d+), main-loop writes to \$41 (\d+), POKEY AUDF1 writes (\d+)", x.strip()) or m
            if not m or int(m.group(1)) != 60 or int(m.group(2)) < 100000 or int(m.group(3)) != 61:
                bad.append(f"DLI: probe {m.groups() if m else None}, expect 60 NMIs, >= 100000 main-loop writes, 61 AUDF1 writes")
        if ref is None:
            bad.append(f"{name}: statistics not compared (no --ref: they must equal the reference build's)")
        else:
            rb = section(ref, prefix)
            if rb is None or stats(rb) != st:
                bad.append(f"{name}: statistics differ from the reference's")
                for x, y in zip(stats(rb or []), st):
                    if x != y:
                        bad.append(f"  ref {x} | log {y}")
            if name == "DLI" and rb is not None:
                pr = [x.strip() for x in rb if x.strip().startswith("PROBE")]
                pl = [x.strip() for x in b if x.strip().startswith("PROBE")]
                if pr != pl:
                    bad.append(f"DLI: probe line differs from the reference's: {pr} | {pl}")

    # SaveKey
    cs = cases(section(secs, "-- SaveKey"))
    want = {
        "Auto, header declares a SaveKey": "sk",
        "Auto, header declares HSC and SaveKey": "sk",
        "Auto, header declares none": "fail",
        "32 KiB save round trip": "rt",
    }
    for title, kind in want.items():
        hit = [c for c in cs if c[0].startswith(title)]
        if len(hit) != 1:
            bad.append(f"SaveKey '{title}': {len(hit)} found")
            continue
        body = hit[0][1]
        if kind == "sk":
            if not tone_ok(body, 7): bad.append(f"SaveKey '{title}': no pass tone (AUDF0=7)")
            need(body, r"SAVEKEY EEPROM \$1234\.\.\$123B in the save RAM: a5 5a 01 02 80 7f ff 00 \(matches what the cart wrote\)", f"SaveKey '{title}'")
        elif kind == "fail":
            if not tone_ok(body, 31): bad.append(f"SaveKey '{title}': no fail tone (AUDF0=31)")
        else:
            m = None
            for x in body:
                m = re.fullmatch(r"SAVEKEY save after load, reset and running: (\d+) of 32768 bytes differ from the save file", x) or m
            if not m:
                bad.append("SaveKey round trip: no result line")
            else:
                n = int(m.group(1))
                if new and n != 8:
                    bad.append(f"SaveKey round trip: {n} bytes differ, expected exactly the cart's 8")
                elif not new and not 6 <= n <= 8:
                    bad.append(f"SaveKey round trip: {n} bytes differ, expected 8 (6-8 with a random save file)")
                elif n != 8:
                    notes.append(f"SaveKey round trip: {n} of the cart's 8 bytes differ; the old script's random save file held {8 - n} of them already")

    # Firmware slots
    cs = cases(section(secs, "-- Firmware slots"))
    for title, pats, tone in (
            ("No firmware file, HSC On", [r"HSC_EN 0 \(setting 1, firmware loaded 0\)"], True),
            ("Both files loaded", [r"FIRMWARE HSC: 4096 byte file, 0 ROM bytes differ from it, hscfw_loaded=1",
                                   r"FIRMWARE Supercharger: 2048 byte file, 0 ROM bytes differ from it, hscfw_loaded=1",
                                   r"HSC_EN 1 \(setting 1, firmware loaded 1\)",
                                   r"SAVE after load, reset and 300 ms of running: 0 of 2048 bytes differ from the save file"], True),
            ("HSC firmware as hsc.a78", [r"FIRMWARE HSC: 4224 byte file, 0 ROM bytes differ from it, hscfw_loaded=1",
                                         r"HSC_EN 1 \(setting 1, firmware loaded 1\)"], False)):
        hit = [c for c in cs if c[0].startswith(title)]
        if len(hit) != 1:
            bad.append(f"Firmware '{title}': {len(hit)} found")
            continue
        for p in pats:
            need(hit[0][1], p, f"Firmware '{title}'")
        if tone and not tone_ok(hit[0][1], 7):
            bad.append(f"Firmware '{title}': no tone AUDF0=7")

    # Supercharger
    body = section(secs, "-- Supercharger without the BIOS")
    cs = cases(body)
    hit = {t: [c for c in cs if c[0].startswith(t)] for t in ("Full 24-page load", "Multiload", "Two loads numbered 0", "With the BIOS, from tape")}
    if len(hit["Full 24-page load"]) != 1:
        bad.append("Supercharger full load: case missing")
    else:
        b = hit["Full 24-page load"][0][1]
        ev = ar_events(b)
        if not any(e[1] == "audf" and e[2] == "5" and e[0] <= 200 for e in ev) or \
           not any(e[1] == "colubk" and e[2] == "54" and e[0] <= 200 for e in ev):
            bad.append(f"Supercharger full load: no magenta $54 / AUDF0 5 within 0.2 s ({ev})")
        need(b, r"ARCHECK 24 pages, 0 of 6144 RAM bytes differ from the image", "Supercharger full load")
    if len(hit["Multiload"]) != 1:
        bad.append("Supercharger multiload: case missing")
    else:
        ev = ar_events(hit["Multiload"][0][1])
        au = [e for e in ev if e[1] == "audf" and e[2] != "0"]
        co = [e for e in ev if e[1] == "colubk" and e[2] != "00"]
        if [e[2] for e in au[:2]] != ["7", "14"] or [e[2] for e in co[:2]] != ["44", "c4"] or au[1][0] < 900:
            bad.append(f"Supercharger multiload: {ev}, expect red $44 / AUDF0 7, then green $c4 / AUDF0 14 after about 1 s")
    if len(hit["Two loads numbered 0"]) != 1:
        bad.append("Supercharger two loads: case missing")
    else:
        b = hit["Two loads numbered 0"][0][1]
        ev = ar_events(b)
        rs = [int(m.group(1)) for x in b for m in [re.fullmatch(r"RESET at (\d+) ms", x)] if m]
        au = [e for e in ev if e[1] == "audf" and e[2] != "0"]
        if not rs or [e[2] for e in au[:2]] != ["3", "20"] or au[1][0] < rs[0] or \
           [e[2] for e in ev if e[1] == "colubk" and e[2] != "00"][:2] != ["84", "1e"]:
            bad.append(f"Supercharger two loads: {ev}, resets {rs}; expect blue $84 / AUDF0 3, the reset, yellow $1e / AUDF0 20")
    tape = hit["With the BIOS, from tape"]
    if tape:
        b = tape[0][1]
        need(b, r"ARCHECK 24 pages, 0 of 6144 RAM bytes differ from the image", "Supercharger tape full load")
        ev = ar_events(b)
        idx = max((i for i, x in enumerate(b) if x.startswith("ARCHECK")), default=None)
        after = ar_events(b[idx + 1:]) if idx is not None else []
        au = [e[2] for e in after if e[1] == "audf" and e[2] != "0"]
        co = [e[2] for e in after if e[1] == "colubk" and e[2] != "00"]
        if "7" not in au or "14" not in au or au.index("7") > au.index("14") or "44" not in co or "c4" not in co:
            bad.append(f"Supercharger tape multiload: {after}, expect red $44 / AUDF0 7, then green $c4 / AUDF0 14")
        else:
            notes.append("Supercharger tape path (AR_TAPE=1): full load and multiload pass")
    elif a.ar_tape:
        bad.append("Supercharger tape path: AR_TAPE=1 section missing")

    # cartridge RAM (step 7)
    b = section(secs, "-- 2600 cartridge RAM")
    if b is None:
        if new:
            bad.append("cartridge RAM: section missing")
        else:
            notes.append("cartridge RAM: absent (a log from before step 7)")
    else:
        for v in ("CARTRAM_MATRIX pass", "CARTRAM_S19 pass"):
            if not any(x.strip() == v for x in b):
                bad.append(f"cartridge RAM: no '{v}'")
        if not [x for x in bad if x.startswith("cartridge RAM")]:
            notes.append("cartridge RAM: CARTRAM_MATRIX pass, CARTRAM_S19 pass")
    return bad, notes


def main():
    p = argparse.ArgumentParser(description="extra_tests.sh log checker")
    p.add_argument("log")
    p.add_argument("--ref")
    p.add_argument("--extra-dir")
    p.add_argument("--ar-tape", action="store_true")
    a = p.parse_args()
    bad, notes = check(a)
    print(f"extra_tests_check {a.log}")
    for n in notes:
        print("  note: " + n)
    for b in bad:
        print("  FAIL: " + b)
    print("EXTRA_TESTS " + ("pass" if not bad else f"FAIL ({len(bad)} finding(s))"))
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
