#!/usr/bin/env python3
"""The frame gate (DARIA step 7, docs/daria_step7/plan.md P13 and 7.4).

  frame_gate.py REF CAND --frames N [--name NAME] [--excuse F0-F1]
                [--expect-guard locked|unlocked|none] [--no-status] [--scheme S]
                [--ref-prefix] [--shift-cap K]
  frame_gate.py --strict A B [--frames N]
  frame_gate.py --auto REF CAND --frames N [the gate's options]

REF and CAND are run directories (or their fp.csv files) as tb_daria writes
them (+fp=1): fp.csv (frame,len_sys,riot,video,audio[,cpu,...]), calls.csv
or calls.csv.gz (call,frame,line,t_req_sys,busy_sys,...), slack.csv
(call,kind,sys_end_to_poll,slack_sys,poll_pc), frames.csv
(frame,t_sys,len_sys,...: when each frame starts, on the clock calls.csv's
t_req_sys counts) and run.log. REF is upstream (R1, tb_daria plain), CAND
the integrated core (R2, tb_frames). N is the run's +frames: frames are
counted from the reset release, and a run of N frames records frames 1..N-1
("ran N frames").

PASS needs all of:
  - both fp.csv hold exactly frames 1..N-1, in order (a truncated, padded
    or shifted file fails);
  - len_sys and video equal on every frame;
  - riot and audio equal on every frame, or the difference classed
    release_shift: calls are matched by number and each call's release (the
    6507's hold, busy_sys) compared; a run of differing frames in one column
    is release_shift when it starts in a frame where a call whose release
    differs is held (the frame of its request and, when REF's frames.csv
    shows the hold, on either side's busy_sys, reaching past that frame's
    end, the frames up to the one its release falls in; without frames.csv,
    the request's frame only), lasts at most 8 frames (SHIFT_MAX), is
    followed by at least 8 equal frames in that column inside the file (the
    column settles: no other difference starts within 8 frames of its end,
    and it does not end within 8 frames of the file's end), and len_sys and
    video are equal there (they are everywhere, by the rule above); and the
    release_shift frames of one column, all runs together, number at most
    the cap (--shift-cap K; default the larger of 8 and 1% of the run's
    frames: 8 at 600 frames, 15 at 1,500). Every other difference fails.
    The settle and cap rules close what plan 7.4's "stays equal until the
    next shifted release" leaves open in R2, where nearly every frame holds
    a call whose release differs: without them any sparse RIOT or audio
    difference (most frames, or one frame in ten) would pass. A cpu column, when both files have it, must be equal
    on every frame; the absolute-time columns of tb_load's and tb_system's
    +fp (t_sys, rst_n, rst_sys) are not compared here: tb_frames counts from
    its own reset release and tb_daria from its own;
  - Spiders (--excuse 557-572, set by default when NAME contains "Spiders"):
    frames F0..F1 are excused when they are the overrun frames on both sides
    (the frames of the late calls) and every column matches from F1+1;
  - REF's load was seen (P27): calls.csv has calls, and with --scheme S its
    run.log names detect2600's force_bs S;
  - the call count and the late calls (slack.csv rows kind 1 with slack <= 0:
    the 6507 found the RIOT timer expired at its first poll) equal on both
    sides;
  - CAND's status line (unless --no-status), which tb_frames prints as
      STATUS calls C, late L, halts H, halt_code X, psram_viol V, guard G, unlocks U
    with halts 0, psram_viol 0, unlocks 0, guard locked (--expect-guard;
    "unlocked" at VCO/19, "none" skips it), and C and L equal to REF's.
--ref-prefix: REF is a longer run (R1 at 1,500 frames) and CAND ran N
frames: REF's fp.csv is cut to frames 1..N-1, and both sides' calls to those
requested in frames 0..N-2 (a call in the last frame may still be running
when CAND's run ends), with their slack.csv rows; CAND's STATUS calls and
late calls are then held to CAND's own files (plan 7.3: tb_frames at 600
frames against R1's first 600).
--auto (the step-7 frame gate's choice, sim/step7_gates.sh g_frames): the
mode follows the scheme the real loader found, CAND's run.log line "2600
mapper S" (tb_load's), which REF's run.log ("detect2600: force_bs S", P27)
must equal; an ARM scheme (21 DPC+, 23 CDF) takes the gate's rules with
--scheme S, any other --strict (a non-ARM image: every column equal on every
frame, and no call on either side).
--strict: the same columns in A and B, every one equal on every frame, the
same frames, and at least one frame (for two builds of one bench, e.g.
tb_load +fp between builds, 7.5 row 5; tb_load's and tb_system's t_sys,
rst_n and rst_sys columns then also hold the run to the same clocks and the
console's reset to the same release edges).
Prints a report and one verdict line; exit status 0 pass, 1 fail, 2 usage.
The files derive from game images: keep them and this output in sim/work.
SPDX-License-Identifier: MIT
"""
import argparse
import bisect
import csv
import gzip
import io
import os
import re
import sys

COLS = ["len_sys", "riot", "video", "audio"]
SHIFT_MAX = 8                       # the longest release_shift run, and the equal frames that must follow it
ARM_SCHEMES = {21: "DPC+", 23: "CDF"}   # detect2600's BANKDPCP and BANKCDF


def shift_cap(frames):
    """The default cap on release_shift frames per column: 1% of the run's frames, at least SHIFT_MAX."""
    return max(SHIFT_MAX, frames // 100)


def path_in(d, name):
    if os.path.isdir(d):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
        if os.path.exists(p + ".gz"):
            return p + ".gz"
        return None
    return d if name == "fp.csv" else None


def read_csv(p):
    if p is None:
        return None
    raw = gzip.open(p, "rb").read() if p.endswith(".gz") else open(p, "rb").read()
    return list(csv.DictReader(io.StringIO(raw.decode("utf-8", "replace"))))


def load_fp(d):
    p = path_in(d, "fp.csv")
    if p is None:
        sys.exit(f"frame_gate.py: no fp.csv in {d}")
    rows = read_csv(p)
    if rows and set(["frame"] + COLS) - set(rows[0]):
        sys.exit(f"{p}: not an fp.csv (columns {','.join(rows[0])})")
    return rows


def check_frames(rows, n, who, bad):
    """Exactly frames 1..n-1 in order; returns {frame: row}."""
    frames = []
    for r in rows:
        try:
            frames.append(int(r["frame"]))
        except (ValueError, TypeError):
            bad.append(f"{who}: unreadable frame number {r.get('frame')!r}")
            return {}
    want = list(range(1, n)) if n else list(range(1, len(frames) + 1))
    if frames != want:
        if len(frames) != len(want):
            bad.append(f"{who}: {len(frames)} frames, the run's count is {len(want)} (frames 1..{len(want)})")
        else:
            i = next(i for i, (a, b) in enumerate(zip(frames, want)) if a != b)
            bad.append(f"{who}: frame numbers out of order at line {i + 2} ({frames[i]}, expected {want[i]})")
    for r in rows:
        if any(r.get(c) in (None, "") for c in COLS):
            bad.append(f"{who}: frame {r['frame']} has an empty column (truncated line)")
            break
    return {int(r["frame"]): r for r in rows if r.get("frame", "").isdigit()}


def runs_of(frames):
    """Consecutive runs [(first, last)] of a sorted frame list."""
    out = []
    for f in frames:
        if out and f == out[-1][1] + 1:
            out[-1][1] = f
        else:
            out.append([f, f])
    return [tuple(x) for x in out]


def late_frames(d, calls, only_these=False):
    """Late calls (slack.csv kind 1, slack <= 0) and their frames; with
    only_these, only the calls in `calls`."""
    rows = read_csv(path_in(d, "slack.csv")) if os.path.isdir(d) else None
    if rows is None:
        return None, None
    frame_of = {int(c["call"]): int(c["frame"]) for c in calls or []}
    late = [int(r["call"]) for r in rows if r.get("kind") == "1" and int(r["slack_sys"]) <= 0
            and (not only_these or int(r["call"]) in frame_of)]
    return late, sorted({frame_of.get(c, -1) for c in late})


def status_of(d):
    p = os.path.join(d, "run.log") if os.path.isdir(d) else None
    if not p or not os.path.exists(p):
        return None
    m = None
    for l in open(p, errors="replace"):
        m = re.match(r"^STATUS calls (\d+), late (\d+), halts (\d+), halt_code (\d+), psram_viol (\d+), "
                     r"guard (\w+), unlocks (\d+)\s*$", l) or m
    return m.groups() if m else None


def header_of(p):
    raw = gzip.open(p, "rb").read() if p.endswith(".gz") else open(p, "rb").read()
    first = raw.decode("utf-8", "replace").split("\n", 1)[0].strip()
    return first.split(",") if first else []


def strict(a, b, n):
    bad = []
    ra, rb = load_fp(a), load_fp(b)
    ha, hb = header_of(path_in(a, "fp.csv")), header_of(path_in(b, "fp.csv"))
    if ha != hb:
        bad.append(f"the columns differ: A {','.join(ha) or '(none)'}, B {','.join(hb) or '(none)'}")
    for who, rows in (("A", ra), ("B", rb)):
        if not rows:
            bad.append(f"{who}: no frame at all (an empty or header-only file)")
    fa, fb = check_frames(ra, n, "A", bad), check_frames(rb, n, "B", bad)
    if not n and len(fa) != len(fb):
        bad.append(f"frame counts differ: A {len(fa)}, B {len(fb)}")
    cols = [c for c in ha if c != "frame" and c in hb] or COLS
    for who, rows in (("A", ra), ("B", rb)):
        for r in rows:
            if any(r.get(c) in (None, "") for c in cols):
                bad.append(f"{who}: frame {r.get('frame')} has an empty column (truncated line)")
                break
    first = {}
    for f in sorted(set(fa) & set(fb)):
        for c in cols:
            if fa[f][c] != fb[f][c]:
                first.setdefault(c, f)
    for c, f in first.items():
        n_diff = sum(1 for g in set(fa) & set(fb) if fa[g][c] != fb[g][c])
        bad.append(f"column {c}: {n_diff} frames differ, the first is {f}")
    print(f"frame_gate --strict: {len(fa)} / {len(fb)} frames, columns {','.join(cols)}")
    for x in bad:
        print("  FAIL: " + x)
    print("FRAME_GATE " + ("pass (identical)" if not bad else "FAIL"))
    return 0 if not bad else 1


def gate(a):
    bad, notes = [], []
    rr, rc = load_fp(a.ref), load_fp(a.cand)
    if a.ref_prefix:
        rr = [r for r in rr if r.get("frame", "").isdigit() and int(r["frame"]) < a.frames]
    fr = check_frames(rr, a.frames, "REF fp.csv", bad)
    fc = check_frames(rc, a.frames, "CAND fp.csv", bad)
    calls_r = read_csv(path_in(a.ref, "calls.csv")) if os.path.isdir(a.ref) else None
    calls_c = read_csv(path_in(a.cand, "calls.csv")) if os.path.isdir(a.cand) else None
    cand_calls_all = len(calls_c or [])
    cand_late_all = (late_frames(a.cand, calls_c)[0] or []) if calls_c is not None else []
    if a.ref_prefix:
        keep = lambda rows: None if rows is None else [c for c in rows if c.get("frame", "").lstrip("-").isdigit()
                                                       and int(c["frame"]) <= a.frames - 2]
        calls_r, calls_c = keep(calls_r), keep(calls_c)
        notes.append(f"--ref-prefix: REF cut to frames 1..{a.frames - 1}, calls to those requested in frames 0..{a.frames - 2}")
    # P27: the reference's load was seen
    if not calls_r:
        bad.append("REF: no calls in calls.csv (P27: the load was not seen, the run is void)")
    if a.scheme is not None and os.path.isdir(a.ref):
        log = open(os.path.join(a.ref, "run.log"), errors="replace").read() if os.path.exists(os.path.join(a.ref, "run.log")) else ""
        m = re.search(r"detect2600: force_bs (\d+)", log)
        if not m or int(m.group(1)) != a.scheme:
            bad.append(f"REF: detect2600 force_bs {m.group(1) if m else 'none'}, expected {a.scheme} (P27)")
    # releases per call
    hold_r = {int(c["call"]): (int(c["frame"]), int(c["busy_sys"])) for c in calls_r or []}
    hold_c = {int(c["call"]): (int(c["frame"]), int(c["busy_sys"])) for c in calls_c or []}
    if calls_c is None:
        bad.append("CAND: no calls.csv")
    # The frames in which a call whose release differs is held: its request's
    # frame and, when REF's frames.csv gives the frames' start times (on
    # calls.csv's t_req_sys clock), every later frame up to the one in which
    # it is released, on either side's hold. Without frames.csv, the
    # request's frame only.
    t_req = {int(c["call"]): int(c["t_req_sys"]) for c in calls_r or [] if c.get("t_req_sys", "").lstrip("-").isdigit()}
    fstart = sorted((int(r["t_sys"]), int(r["frame"])) for r in
                    (read_csv(path_in(a.ref, "frames.csv")) if os.path.isdir(a.ref) else None) or []
                    if r.get("t_sys", "").isdigit() and r.get("frame", "").isdigit())
    starts = [s for s, _ in fstart]

    def frame_at(t):
        i = bisect.bisect_right(starts, t) - 1
        return fstart[i][1] if i >= 0 else None
    shifted_frames, rel_diff = set(), {}
    for k in sorted(set(hold_r) & set(hold_c)):
        d = hold_c[k][1] - hold_r[k][1]
        rel_diff[d] = rel_diff.get(d, 0) + 1
        if d:
            f0 = hold_r[k][0]
            last = f0
            if fstart and k in t_req:
                for busy in (hold_r[k][1], hold_c[k][1]):
                    rel_f = frame_at(t_req[k] + busy)
                    if rel_f is not None and rel_f > last:
                        last = rel_f
            shifted_frames |= set(range(f0, last + 1))
    # Spiders' overrun frames
    excuse = None
    if a.excuse:
        f0, f1 = (int(x) for x in a.excuse.split("-"))
        late_r, lf_r = late_frames(a.ref, calls_r, a.ref_prefix)
        late_c, lf_c = late_frames(a.cand, calls_c, a.ref_prefix)
        want = list(range(f0, f1 + 1))
        if lf_r == want and lf_c == want:
            excuse = (f0, f1)
            notes.append(f"frames {f0}-{f1} are the overrun frames on both sides: excused if every column matches from {f1 + 1}")
        else:
            notes.append(f"frames {f0}-{f1} not excused: late-call frames REF {lf_r}, CAND {lf_c}")
    common = sorted(set(fr) & set(fc))
    counts = {}
    shift_count = {"riot": 0, "audio": 0}
    shift_frames = {"riot": 0, "audio": 0}
    cap = a.shift_cap if a.shift_cap is not None else shift_cap(a.frames)
    for c in COLS + (["cpu"] if rr and rc and "cpu" in rr[0] and "cpu" in rc[0] else []):
        diff = [f for f in common if fr[f][c] != fc[f][c]]
        if excuse:
            inside = [f for f in diff if excuse[0] <= f <= excuse[1]]
            after = [f for f in diff if f > excuse[1]]
            if after:
                bad.append(f"{c}: differs after the excused frames, from frame {after[0]} ({len(after)} frames)")
                if not [f for f in diff if f < excuse[0]]:
                    notes.append("frames before the overrun match: owner question 3 (plan 6.2) applies")
            diff = [f for f in diff if f < excuse[0]]
            counts[c + "_excused"] = len(inside)
        counts[c] = len(diff)
        if not diff:
            continue
        if c in ("len_sys", "video", "cpu"):
            bad.append(f"{c}: {len(diff)} frames differ, the first is {diff[0]}")
            continue
        end = common[-1] if common else None
        runs = runs_of(diff)
        col_bad = []
        for i, (f0, f1) in enumerate(runs):
            # the equal frames after the run: up to the next differing frame, or the file's end
            nxt = runs[i + 1][0] if i + 1 < len(runs) else end + 1
            settle = nxt - f1 - 1
            if f0 in shifted_frames and f1 - f0 + 1 <= SHIFT_MAX and settle >= SHIFT_MAX:
                shift_count[c] += 1
                shift_frames[c] += f1 - f0 + 1
            else:
                why = ("no call whose release differs is held there" if f0 not in shifted_frames else
                       f"lasts {f1 - f0 + 1} frames (> {SHIFT_MAX})" if f1 - f0 + 1 > SHIFT_MAX else
                       "it reaches the last frame of the file: the column is never equal again" if f1 == end else
                       f"the column is equal for only {settle} frames after it before the file ends (< {SHIFT_MAX})"
                       if i + 1 == len(runs) else
                       f"the column is equal for only {settle} frames after it (< {SHIFT_MAX}): the next difference "
                       f"starts at frame {nxt}")
                col_bad.append(f"{c}: frames {f0}-{f1} differ, not release_shift ({why})")
        bad += col_bad[:8]
        if len(col_bad) > 8:
            bad.append(f"{c}: {len(col_bad) - 8} more runs of differing frames not release_shift "
                       f"({len(col_bad)} in all, {len(diff)} frames)")
        if shift_frames[c] > cap:
            bad.append(f"{c}: {shift_frames[c]} release_shift frames in {shift_count[c]} runs, over the cap of {cap} "
                       f"(--shift-cap)")
    # calls and late calls
    nr, nc = len(calls_r or []), len(calls_c or [])
    late_r, _ = late_frames(a.ref, calls_r, a.ref_prefix)
    late_c, _ = late_frames(a.cand, calls_c, a.ref_prefix)
    if nr != nc:
        bad.append(f"calls: REF {nr}, CAND {nc}")
    if late_r is not None and late_c is not None and len(late_r) != len(late_c):
        bad.append(f"late calls: REF {len(late_r)}, CAND {len(late_c)}")
    if not a.no_status:
        st = status_of(a.cand)
        if st is None:
            bad.append("CAND: no STATUS line in run.log")
        else:
            calls, late, halts, hcode, viol, guard, unl = st
            if int(halts) or int(hcode): bad.append(f"STATUS halts {halts}, halt_code {hcode}")
            if int(viol): bad.append(f"STATUS psram_viol {viol}")
            if int(unl): bad.append(f"STATUS unlocks {unl}")
            if a.expect_guard != "none" and guard != a.expect_guard:
                bad.append(f"STATUS guard {guard}, expected {a.expect_guard}")
            if a.ref_prefix:
                # CAND's run is the whole of its own files: STATUS against them
                if int(calls) != cand_calls_all: bad.append(f"STATUS calls {calls}, CAND's calls.csv has {cand_calls_all}")
                if int(late) != len(cand_late_all): bad.append(f"STATUS late {late}, CAND's slack.csv has {len(cand_late_all)}")
            else:
                if int(calls) != nr: bad.append(f"STATUS calls {calls}, REF has {nr}")
                if late_r is not None and int(late) != len(late_r): bad.append(f"STATUS late {late}, REF has {len(late_r)}")
    name = a.name or os.path.basename(os.path.normpath(a.cand))
    print(f"frame_gate {name}: {len(fr)} / {len(fc)} frames; calls {nr} / {nc}; late "
          f"{len(late_r) if late_r is not None else '-'} / {len(late_c) if late_c is not None else '-'}")
    print("  differing frames: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    print(f"  release_shift runs (frames): riot {shift_count['riot']} ({shift_frames['riot']}), "
          f"audio {shift_count['audio']} ({shift_frames['audio']}); cap {cap} frames per column")
    print("  release differences (CAND - REF busy_sys: calls): " +
          (", ".join(f"{d:+d}: {n}" for d, n in sorted(rel_diff.items())) or "-"))
    for x in notes:
        print("  note: " + x)
    for x in bad:
        print("  FAIL: " + x)
    print(f"FRAME_GATE {'pass' if not bad else 'FAIL'} {name}")
    return 0 if not bad else 1


def log_scheme(d, pat):
    p = os.path.join(d, "run.log") if os.path.isdir(d) else None
    if not p or not os.path.exists(p):
        return None
    m = re.search(pat, open(p, errors="replace").read(), re.M)
    return int(m.group(1)) if m else None


def auto(a):
    """--auto: the mode from the scheme the real loader found (CAND's), which REF's must equal (P27)."""
    sc = log_scheme(a.cand, r"^OPTIONS .*?\b2600 mapper (\d+)")
    sr = log_scheme(a.ref, r"detect2600: force_bs (\d+)")
    print(f"frame_gate --auto: CAND's loader found scheme {sc if sc is not None else 'none'}, "
          f"REF's detect2600 {sr if sr is not None else 'none'}")
    bad = []
    if sc is None:
        bad.append("CAND: no '2600 mapper' line in run.log (tb_load's OPTIONS line)")
    if sr is None:
        bad.append("REF: no 'detect2600: force_bs' line in run.log")
    if sc is not None and sr is not None and sc != sr:
        bad.append(f"REF's detect2600 chose scheme {sr}, the real loader {sc} (P27: REF's load was not seen)")
    if bad:
        for x in bad:
            print("  FAIL: " + x)
        print(f"FRAME_GATE FAIL {a.name or os.path.basename(os.path.normpath(a.cand))}")
        return 1
    if sc in ARM_SCHEMES:
        print(f"  an ARM scheme ({ARM_SCHEMES[sc]}): the gate's rules, --scheme {sc}")
        a.scheme = sc
        return gate(a)
    print("  not an ARM scheme: --strict, and no call on either side")
    calls_bad = []
    for who, d in (("REF", a.ref), ("CAND", a.cand)):
        n = len(read_csv(path_in(d, "calls.csv")) or []) if os.path.isdir(d) else 0
        if n:
            calls_bad.append(f"{who}: {n} calls in calls.csv, from an image whose scheme makes none")
    rc = strict(a.ref, a.cand, a.frames)
    for x in calls_bad:
        print("  FAIL: " + x)
    if calls_bad:
        print("FRAME_GATE FAIL (calls in a run of a non-ARM image)")
        return 1
    return rc


def main():
    p = argparse.ArgumentParser(description="the frame gate (plan P13, 7.4)")
    p.add_argument("ref")
    p.add_argument("cand")
    p.add_argument("--frames", type=int, help="the run's +frames (fp.csv then holds frames 1..N-1)")
    p.add_argument("--strict", action="store_true")
    p.add_argument("--auto", action="store_true",
                   help="--strict or the gate's rules by the scheme CAND's loader found (REF's must equal it)")
    p.add_argument("--shift-cap", type=int,
                   help="release_shift frames allowed per column (default the larger of 8 and 1%% of the run's frames)")
    p.add_argument("--name")
    p.add_argument("--excuse", help="F0-F1: frames excused as overrun frames (default 557-572 for Spiders)")
    p.add_argument("--expect-guard", default="locked", choices=("locked", "unlocked", "none"))
    p.add_argument("--no-status", action="store_true")
    p.add_argument("--scheme", type=int)
    p.add_argument("--ref-prefix", action="store_true",
                   help="REF is a longer run: compare its first N-1 frames and the calls requested before frame N-1")
    a = p.parse_args()
    if a.strict and a.auto:
        p.error("--strict and --auto exclude each other")
    if a.strict:
        sys.exit(strict(a.ref, a.cand, a.frames))
    if not a.frames:
        p.error("--frames N is required (the run's +frames)")
    name = a.name or os.path.basename(os.path.normpath(a.cand))
    if a.excuse is None and "spiders" in name.lower():
        a.excuse = "557-572"
    sys.exit(auto(a) if a.auto else gate(a))


if __name__ == "__main__":
    main()
