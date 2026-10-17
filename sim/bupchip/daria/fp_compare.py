#!/usr/bin/env python3
"""Compare the frame fingerprints of two runs (fp.csv, tb_daria.sv +fp=1).

  fp_compare.py A/fp.csv B/fp.csv [--name NAME] [--list N]
  fp_compare.py --table NAME=A:B [NAME=A:B ...]

A and B may also be run directories (their fp.csv is read). Frames are
matched by number; only the frames both files have are compared.

For each column (len_sys, riot, video, audio) the first form prints the
number of frames that differ, the first and last of them, and the longest
run of identical frames after the first difference (a column that differs
for a while and then agrees again has a long run). For len_sys it also
lists the frames whose lengths differ by more than 1 clk_sys, with both
lengths (--list sets how many, default 20). The last line is the verdict:
identical, or the first differing frame and the columns that differ there.

--table prints one markdown row per pair: frames compared, then for each
column "-" when it never differs, else "N from F, run R" (N frames differ,
the first is F, R is the longest identical run after F), then the verdict.

The hashes derive from the game: keep fp.csv files and this output in
sim/work.
SPDX-License-Identifier: MIT
"""
import csv
import os
import sys

COLS = ["len_sys", "riot", "video", "audio"]


def load(path):
    if os.path.isdir(path):
        path = os.path.join(path, "fp.csv")
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    if rows and set(["frame"] + COLS) - set(rows[0]):
        sys.exit("%s: not an fp.csv (columns %s)" % (path, ",".join(rows[0])))
    return {int(r["frame"]): r for r in rows}


def run_name(path):
    """The run directory's name, for a run directory or a file in it."""
    path = os.path.abspath(path)
    return os.path.basename(path if os.path.isdir(path) else os.path.dirname(path))


def compare(a, b):
    """Per column: differing frames, longest identical run after the first."""
    frames = sorted(set(a) & set(b))
    res = {"frames": frames, "only_a": len(set(a) - set(b)), "only_b": len(set(b) - set(a))}
    for c in COLS:
        diff = [f for f in frames if a[f][c] != b[f][c]]
        run = best = 0
        if diff:
            for f in frames:
                if f <= diff[0]:
                    continue
                run = 0 if a[f][c] != b[f][c] else run + 1
                best = max(best, run)
        res[c] = {"diff": diff, "run": best}
    big = []
    for f in res["len_sys"]["diff"]:
        la, lb = int(a[f]["len_sys"]), int(b[f]["len_sys"])
        if abs(la - lb) > 1:
            big.append((f, la, lb))
    res["big"] = big
    return res


def verdict(res):
    if not res["frames"]:
        return "no frames in common"
    firsts = [res[c]["diff"][0] for c in COLS if res[c]["diff"]]
    if not firsts:
        v = "identical over %d frames" % len(res["frames"])
    else:
        f = min(firsts)
        v = "differs from frame %d in %s" % (f, ", ".join(c for c in COLS if f in res[c]["diff"]))
    if res["only_a"] or res["only_b"]:
        v += " (frames only in A: %d, only in B: %d)" % (res["only_a"], res["only_b"])
    return v


def report(res, name, a_path, b_path, nlist):
    fr = res["frames"]
    print("%s: A %s, B %s" % (name, a_path, b_path))
    if fr:
        print("frames compared %d (%d to %d)" % (len(fr), fr[0], fr[-1]))
    for c in COLS:
        d = res[c]["diff"]
        if not d:
            print("  %-8s identical" % c)
            continue
        line = "  %-8s %d differ, first %d, last %d, longest identical run after the first %d" % (
            c, len(d), d[0], d[-1], res[c]["run"])
        if c == "len_sys":
            line += "; %d by more than 1 clk_sys" % len(res["big"])
        print(line)
        if c == "len_sys":
            for f, la, lb in res["big"][:nlist]:
                print("    frame %d: %d / %d (%+d)" % (f, la, lb, lb - la))
            if len(res["big"]) > nlist:
                print("    ... %d more" % (len(res["big"]) - nlist))
    print("verdict: " + verdict(res))


def cell(res, c):
    d = res[c]["diff"]
    if not d:
        return "-"
    s = "%d from %d, run %d" % (len(d), d[0], res[c]["run"])
    if c == "len_sys" and res["big"]:
        s += " (%d by >1)" % len(res["big"])
    return s


def table(pairs):
    hdr = ["Run", "Frames"] + COLS + ["Verdict"]
    out = ["| " + " | ".join(hdr) + " |", "|" + "|".join("---" for _ in hdr) + "|"]
    for p in pairs:
        if "=" not in p or ":" not in p.split("=", 1)[1]:
            sys.exit("--table takes NAME=A:B, not %s" % p)
        name, ab = p.split("=", 1)
        a_path, b_path = ab.split(":", 1)
        res = compare(load(a_path), load(b_path))
        out.append("| " + " | ".join([name, str(len(res["frames"]))] + [cell(res, c) for c in COLS]
                                     + [verdict(res)]) + " |")
    print("\n".join(out))


def main():
    args = sys.argv[1:]
    if args and args[0] == "--table":
        if len(args) < 2:
            sys.exit(__doc__)
        table(args[1:])
        return
    opts = {"--name": None, "--list": "20"}
    paths = []
    i = 0
    while i < len(args):
        if args[i] in opts and i + 1 < len(args):
            opts[args[i]] = args[i + 1]
            i += 2
        elif args[i].startswith("-"):
            sys.exit(__doc__)
        else:
            paths.append(args[i])
            i += 1
    if len(paths) != 2:
        sys.exit(__doc__)
    name = opts["--name"] or "%s vs %s" % tuple(run_name(p) for p in paths)
    res = compare(load(paths[0]), load(paths[1]))
    report(res, name, paths[0], paths[1], int(opts["--list"]))


if __name__ == "__main__":
    main()
