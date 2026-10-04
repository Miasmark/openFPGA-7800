#!/usr/bin/env python3
"""Summarise tb_daria.sv runs (run_daria.sh) for the DARIA sizing question.

  summarize.py RUN_DIR                 one run: call types, budgets, mix, caches
  summarize.py --table RUNS_DIR...     one line per run, for the report
  options: --split F   frames before F are "attract", from F on "play"
                       (default: the run's play_at, 480)

Budget of a call: the 6507 is held for the whole call (top.sv arm_call_stall,
as on a Harmony, which feeds it NOPs), so the time it has left when it first
polls the RIOT timer afterwards (slack.csv) is time the ARM could still have
used. Budget = held time + slack. A DARIA at CPI c needs
f >= instructions x c / budget for every call; calls with no timer poll
before the next call have no budget and are listed apart.
SPDX-License-Identifier: MIT
"""
import csv
import gzip
import os
import sys
from collections import defaultdict

SYS_HZ = 14318181.0
ARM_HZ = 5 * SYS_HZ
SYS_PER_LINE = 912
SYS_PER_CPU = 12
CPIS = (1.0, 1.2, 1.4)
SCHEME = {(21, 0): "DPC+", (21, 1): "DPC+", (23, 0): "CDF0", (23, 1): "CDF1",
          (23, 2): "CDFJ", (23, 3): "CDFJ+"}
THUMB_GROUPS = [
    ("data processing (F1-F4 ALU, F12, F13)", ("F1 ", "F2 ", "F3 ", "F4 ALU", "F12", "F13")),
    ("shift by register (F4)", ("F4 shift",)),
    ("multiply (F4 MUL)", ("F4 MUL",)),
    ("hi-register ops (F5)", ("F5 hi",)),
    ("loads, single (F6-F11)", ("F6", "F7 LDR", "F8 LDRH", "F9 LDR", "F10 LDRH", "F11 LDR")),
    ("stores, single (F7-F11)", ("F7 STR", "F8 STRH", "F9 STR", "F10 STRH", "F11 STR")),
    ("PUSH/POP/LDMIA/STMIA (F14, F15)", ("F14", "F15")),
    ("conditional branch (F16)", ("F16",)),
    ("B (F18)", ("F18",)),
    ("BL (F19, two halves)", ("F19",)),
    ("BX (F5)", ("F5 BX",)),
    ("SWI/undefined", ("F17", "undefined")),
]


def pct(v, p):
    if not v:
        return 0
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1))))]


def load(run):
    rows = []
    with gzip.open(os.path.join(run, "calls.csv.gz"), "rt") as f:
        for r in csv.DictReader(f):
            for k in r:
                if k != "first_bl":
                    r[k] = int(r[k])
            r["instr"] = r["thumb"] + r["arm"]
            rows.append(r)
    slack = {}
    with open(os.path.join(run, "slack.csv")) as f:
        for r in csv.DictReader(f):
            slack[int(r["call"])] = (int(r["kind"]), int(r["sys_end_to_poll"]), int(r["slack_sys"]))
    for r in rows:
        k = slack.get(r["call"])
        r["slack"] = k[2] if k and k[0] == 1 else None
        r["to_poll"] = k[1] if k else None
        r["budget"] = r["stall_sys"] + r["slack"] if r["slack"] is not None else None
    frames = []
    with open(os.path.join(run, "frames.csv")) as f:
        for r in csv.DictReader(f):
            frames.append({k: float(v) if k == "lines" else int(v) for k, v in r.items()})
    summ = {"kind": [], "total": {}, "cache": {}, "ram": [], "rom": [], "mmio": [], "misc": {}}
    with open(os.path.join(run, "summary.txt")) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "kind":
                summ["kind"].append((int(p[2]), int(p[3]), " ".join(p[4:])))
            elif p[0] == "total":
                summ["total"][p[1]] = int(p[2])
            elif p[0] == "cache":
                summ["cache"][p[1]] = (int(p[3]), {q.split(":")[0]: int(q.split(":")[1]) for q in p[4:]})
            elif p[0] == "ram_kib":
                summ["ram"].append((int(p[1]), int(p[3]), int(p[5])))
            elif p[0] == "rom_rd_kib":
                summ["rom"].append((int(p[1]), int(p[2])))
            elif p[0] in ("mmio_rd", "mmio_wr"):
                summ["mmio"].append((p[0], p[1], int(p[2])))
            elif p[0] == "scheme":
                summ["misc"]["scheme"] = SCHEME.get((int(p[2]), int(p[4])), "?%s/%s" % (p[2], p[4]))
                summ["misc"]["rom_size"] = int(p[8])
            elif p[0] == "distinct_pc":
                summ["misc"]["dpc"], summ["misc"]["dl16"], summ["misc"]["dl32"] = int(p[1]), int(p[3]), int(p[5])
            elif p[0] == "frames":
                summ["misc"]["frames"] = int(p[1])
    return rows, frames, summ


def us(sys_cycles):
    return sys_cycles / SYS_HZ * 1e6


def need_mhz(instr, budget_sys, cpi):
    return instr * cpi / (budget_sys / SYS_HZ) / 1e6


def phase_of(line):
    # Scanline of the CALLFN write, counted from the VSYNC write.
    if line < 40:
        return "VB"
    if line >= 220:
        return "OS"
    return "kernel"


def report(run, split):
    rows, frames, summ = load(run)
    name = os.path.basename(run.rstrip("/"))
    out = []
    w = out.append
    nfr = len(frames)
    w("%s: %s, ROM %d KiB, %d frames, %d calls" % (name, summ["misc"].get("scheme"),
      summ["misc"].get("rom_size", 0) // 1024, nfr, len(rows)))
    over = [f for f in frames if abs(f["lines"] - 262) > 0.01]
    w("frames not 262 lines: %d%s" % (len(over), (" (frames %s...)" % ", ".join(
        "%d:%.1f" % (f["frame"], f["lines"]) for f in over[:8])) if over else ""))
    for ph, sel in (("attract (frames < %d)" % split, lambda r: r["frame"] < split),
                    ("play (frames >= %d)" % split, lambda r: r["frame"] >= split),
                    ("all", lambda r: True)):
        rs = [r for r in rows if sel(r)]
        if not rs:
            continue
        w("")
        w("== %s: %d calls" % (ph, len(rs)))
        groups = defaultdict(list)
        for r in rs:
            groups[(phase_of(r["line"]), r["first_bl"])].append(r)
        w("%-14s %6s %8s %8s %8s %9s %8s %9s %9s %9s %7s" % ("type (bl@)", "calls", "instr", "p50", "max",
          "ref us mx", "lines mx", "budget mn", "slack mn", "MHz@1.4", "noslk"))
        for (ph2, bl), g in sorted(groups.items(), key=lambda kv: -max(r["instr"] for r in kv[1])):
            ins = [r["instr"] for r in g]
            st = [r["stall_sys"] for r in g]
            bud = [r for r in g if r["budget"] is not None]
            mhz = max((need_mhz(r["instr"], r["budget"], 1.4) for r in bud if r["budget"] > 0), default=0)
            w("%-14s %6d %8d %8d %8d %9.1f %8.2f %9s %9s %9s %7d" % (
                "%s %s" % (ph2, bl[-5:]), len(g), sum(ins) // len(g), pct(ins, 50), max(ins),
                us(max(st)), max(st) / SYS_PER_LINE,
                "%.0f" % us(min(r["budget"] for r in bud)) if bud else "-",
                "%.0f" % us(min(r["slack"] for r in bud)) if bud else "-",
                "%.2f" % mhz if bud else "-", len(g) - len(bud)))
        ins = [r["instr"] for r in rs]
        cyc = [r["arm_cyc"] for r in rs]
        w("per call: instr p50 %d p90 %d p99 %d max %d; reference clk_arm max %d (%.0f us at 71.59 MHz),"
          " CPI %.2f; ARM7TDMI zero-wait estimate CPI %.2f" % (
              pct(ins, 50), pct(ins, 90), pct(ins, 99), max(ins), max(cyc), max(cyc) / ARM_HZ * 1e6,
              sum(cyc) / max(1, sum(ins)), sum(r["est_arm7"] for r in rs) / max(1, sum(ins))))
        fr = defaultdict(int)
        for r in rs:
            fr[r["frame"]] += r["instr"]
        fv = list(fr.values())
        w("per frame: instr p50 %d p99 %d max %d (frame %d); calls/frame %.2f" % (
            pct(fv, 50), pct(fv, 99), max(fv), max(fr, key=fr.get), len(rs) / max(1, len(fr))))
        bud = [r for r in rs if r["budget"] is not None and r["budget"] > 0]
        if bud:
            for c in CPIS:
                worst = max(bud, key=lambda r: need_mhz(r["instr"], r["budget"], c))
                w("DARIA at CPI %.1f needs %.2f MHz (worst call %d: %d instr in %.0f us budget, frame %d line %d)" % (
                    c, need_mhz(worst["instr"], worst["budget"], c), worst["call"], worst["instr"],
                    us(worst["budget"]), worst["frame"], worst["line"]))
            neg = [r for r in bud if r["slack"] < 0]
            if neg:
                w("overruns on the reference: %d calls, worst %.0f us late (call %d)" % (
                    len(neg), -us(min(r["slack"] for r in neg)), min(neg, key=lambda r: r["slack"])["call"]))
            ml = max(rs, key=lambda r: r["dist_l16"])
            w("per-call code footprint max: %d PCs, %d x 16 B lines (%d B), %d x 32 B lines" % (
                max(r["dist_pc"] for r in rs), ml["dist_l16"], ml["dist_l16"] * 16, max(r["dist_l32"] for r in rs)))
            for s in ("I", "D", "U"):
                for cfg in ("2k_16", "4k_16", "8k_16", "4k_32"):
                    k = "miss_%s_%s" % (s, cfg)
                    if k in rs[0]:
                        mm = max(rs, key=lambda r: r[k])
                        w("  cache %s %-5s: misses/call max %d (call %d, %d acc), mean %.1f" % (
                            s, cfg, mm[k], mm["call"], mm["acc_" + s], sum(r[k] for r in rs) / len(rs)))
    # whole run: mix and traffic
    t = summ["total"]
    ins = t["thumb"] + t["arm"]
    w("")
    w("== instruction mix (whole run): %d instructions, Thumb %.2f%%, ARM %.2f%%" % (
        ins, 100.0 * t["thumb"] / max(1, ins), 100.0 * t["arm"] / max(1, ins)))
    for gname, keys in THUMB_GROUPS:
        n = sum(c for c, _, k in summ["kind"] if k.startswith(keys))
        tk = sum(tk for _, tk, k in summ["kind"] if k.startswith(keys))
        if n:
            w("  %-40s %6.2f%%  (changed flow %5.1f%%)" % (gname, 100.0 * n / ins, 100.0 * tk / n))
    for c, tk, k in summ["kind"]:
        if k.startswith("ARM"):
            w("  %-40s %6.2f%%" % (k, 100.0 * c / ins))
    w("  detail: " + "; ".join("%s %.2f%%" % (k, 100.0 * c / ins) for c, _, k in summ["kind"]))
    w("taken branches / changes of flow: %.1f%% of instructions" % (100.0 * t["taken"] / max(1, ins)))
    w("")
    w("== memory traffic per instruction: fetch requests %.3f (ROM %.3f, RAM %.3f); "
      "data reads ROM %.3f (byte %.3f, half %.3f, word %.3f), RAM %.3f; writes RAM %.3f; MMIO r %.4f w %.4f" % (
          t["fetch_req"] / ins, t["fetch_rom"] / ins, t["fetch_ram"] / ins, t["rd_rom"] / ins,
          t["rd_rom_b"] / ins, t["rd_rom_h"] / ins, t["rd_rom_w"] / ins, t["rd_ram"] / ins,
          t["wr_ram"] / ins, t["rd_mmio"] / ins, t["wr_mmio"] / ins))
    tot_acc = t["fetch_req"] + t["rd_rom"] + t["rd_ram"] + t["wr_ram"] + t["rd_mmio"] + t["wr_mmio"]
    w("fraction of all bus accesses that are cartridge ROM (fetch + data): %.1f%%" % (
        100.0 * (t["fetch_rom"] + t["rd_rom"]) / max(1, tot_acc)))
    w("RAM KiB (rd/wr): " + " ".join("%d:%d/%d" % r for r in summ["ram"]))
    w("ROM data reads by KiB: " + " ".join("%d:%d" % r for r in summ["rom"]))
    if summ["mmio"]:
        w("MMIO: " + " ".join("%s %s x%d" % m for m in summ["mmio"]))
    m = summ["misc"]
    w("code footprint, whole run: %d distinct PCs, %d x 16 B lines (%.1f KiB), %d x 32 B lines (%.1f KiB)" % (
        m["dpc"], m["dl16"], m["dl16"] * 16 / 1024.0, m["dl32"], m["dl32"] * 32 / 1024.0))
    for s, (acc, misses) in summ["cache"].items():
        w("cache %s (%d accesses), hit rate: " % (s, acc) + " ".join(
            "%s %.2f%%" % (k, 100.0 * (1 - v / max(1, acc))) for k, v in misses.items()))
    return "\n".join(out)


def table(runs, split):
    hdr = ("demo", "scheme", "calls/fr", "max instr/call", "p99", "max instr/frame", "max ref us",
           "min budget us", "min slack us", "MHz@1.0", "MHz@1.4", "frames!=262", "Thumb%",
           "footprint KiB", "I 4k/16 hit%", "U 8k/16 hit%")
    lines = ["| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
    for run in runs:
        try:
            rows, frames, summ = load(run)
        except FileNotFoundError:
            continue
        name = os.path.basename(run.rstrip("/")).replace("_demo_final_CG_NTSC", "").replace(
            "_demo_final__CG_NTSC", "").replace("_demo_v2_CG_NTSC", "")
        for ph, sel in (("play", lambda r: r["frame"] >= split), ("all", lambda r: True)):
            rs = [r for r in rows if sel(r)]
            if not rs:
                continue
            ins = [r["instr"] for r in rs]
            fr = defaultdict(int)
            for r in rs:
                fr[r["frame"]] += r["instr"]
            bud = [r for r in rs if r["budget"] is not None and r["budget"] > 0]
            t = summ["total"]
            ic = summ["cache"]["I"]
            uc = summ["cache"]["U"]
            lines.append("| " + " | ".join(str(x) for x in (
                "%s (%s)" % (name, ph), summ["misc"]["scheme"], "%.2f" % (len(rs) / max(1, len(fr))),
                max(ins), pct(ins, 99), max(fr.values()), "%.0f" % us(max(r["stall_sys"] for r in rs)),
                "%.0f" % us(min(r["budget"] for r in bud)) if bud else "-",
                "%.0f" % us(min(r["slack"] for r in bud)) if bud else "-",
                "%.2f" % max(need_mhz(r["instr"], r["budget"], 1.0) for r in bud) if bud else "-",
                "%.2f" % max(need_mhz(r["instr"], r["budget"], 1.4) for r in bud) if bud else "-",
                sum(1 for f in frames if abs(f["lines"] - 262) > 0.01 and (ph == "all" or f["frame"] >= split)),
                "%.1f" % (100.0 * t["thumb"] / max(1, t["thumb"] + t["arm"])),
                "%.1f" % (summ["misc"]["dl16"] * 16 / 1024.0),
                "%.2f" % (100.0 * (1 - ic[1]["4k/16"] / max(1, ic[0]))),
                "%.2f" % (100.0 * (1 - uc[1]["8k/16"] / max(1, uc[0]))))) + " |")
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    split = 480
    if "--split" in args:
        i = args.index("--split")
        split = int(args[i + 1])
        del args[i:i + 2]
    if args and args[0] == "--table":
        print(table(args[1:], split))
    else:
        for a in args:
            print(report(a, split))


if __name__ == "__main__":
    main()
