#!/usr/bin/env python3
"""Tables for the DARIA dynamic report, from tb_daria.sv runs (run_daria.sh).

  dynamic_tables.py [--scan scan.json] [--margin F] [--only SECTION,...] RUN_DIR...

Sections: schemes, overview, types, clock, overruns, late, cache, mix, rom, ram, harmony, polls,
determinism
(--ref DIR: compare each run with the run of the same name under DIR).

Safe budget of a call: the time the 6507 was held plus the slack it had left
at its first timer poll, measured to the clock INTIM first reads 0. Every demo
in the test set waits with LDx INTIM / BNE, which leaves its loop then; a
first poll later than that moves everything after it, and one after the wrap
misses the zero altogether. Runs with zero.csv give that slack directly. For
older runs it is summarize.py's slack to the wrap less one TIM64T interval
(768 clk_sys, 53.6 us), which is exact for every call whose timer wraps
before it is reloaded; calls whose timer is reloaded first have no budget
there.

Clock a call needs: f = C / (budget x (1 - margin) - M x t_miss), with C the
call's cycles (instructions x CPI, or the bench's s1_cyc / s3_cyc estimates)
and M its misses in one of the bench's cache models. t_miss is a time, not a
number of DARIA clocks: an SDRAM or PSRAM access does not get shorter when
DARIA's clock rises.

--scan adds what daria_scan.py found statically: the TIM64T loads, the code
span (to split ROM data reads into code-span literals and tables, and data
outside it) and PLLCFG (60 or 70 MHz, for the Harmony estimate).

Everything printed derives from the game: keep the output in sim/work.
SPDX-License-Identifier: MIT
"""
import csv
import gzip
import json
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summarize as S  # noqa: E402

SYS_HZ = S.SYS_HZ
ARM_HZ = S.ARM_HZ
TIM64T_SYS = 64 * S.SYS_PER_CPU          # one TIM64T interval in clk_sys
CPU_HZ = SYS_HZ / S.SYS_PER_CPU          # 6507 clock
S1_MHZ, S3_MHZ = 28.636, 21.477
# Miss times [E]: 10-15 DARIA S1 clocks for a 16 B SDRAM line, 20 for 32 B,
# and a PSRAM-like 1.4 us (the BupChip's 5 S1 clocks per halfword, whole line).
T16, T16_LO, T32, T_PS = 15 / 28.636e6, 10 / 28.636e6, 20 / 28.636e6, 1.4e-6
CACHES = [  # (label, list of miss columns, t_miss)
    ("block RAM copy", [], 0.0),
    ("U 4K/16", ["miss_U_4k_16"], T16),
    ("U 8K/16", ["miss_U_8k_16"], T16),
    ("U 16K/16", ["miss_U_16k_16"], T16),
    ("U 16K/32", ["miss_U_16k_32"], T32),
    ("I 4K/16 + D 2K/16", ["miss_I_4k_16", "miss_D_2k_16"], T16),
    ("I 8K/16 + D 4K/16", ["miss_I_8k_16", "miss_D_4k_16"], T16),
    ("I 16K/16 + D 8K/16", ["miss_I_16k_16", "miss_D_8k_16"], T16),
    # Code span in block RAM, every ROM data read through a D-cache (literal
    # pools included, so the miss count is an upper bound).
    ("code in BRAM + D 4K/16", ["miss_D_4k_16"], T16),
    ("code in BRAM + D 8K/32", ["miss_D_8k_32"], T32),
    ("U 8K/16, PSRAM 1.4 us", ["miss_U_8k_16"], T_PS),
]
SHORT = {"Elevator-Agent": "Elevator Agent", "Super-Cobra-Arcade": "Super Cobra",
         "RobotWar-2684": "RobotWar 2684", "Wizard-of-Wor-Arcade": "Wizard of Wor",
         "Zoo-Keeper": "Zoo Keeper", "Lady-Bug-Arcade": "Lady Bug"}
SCHEME_ORDER = {"DPC+": 0, "CDF0": 1, "CDF1": 1, "CDFJ": 2, "CDFJ+": 3}


def short(name):
    for suf in ("_demo_final_CG_NTSC", "_demo_final__CG_NTSC", "_demo_v2_CG_NTSC"):
        name = name.replace(suf, "")
    if name in SHORT:
        return SHORT[name]
    return name.replace("-Arcade", "").replace("-", " ")


def us(x):
    return x / SYS_HZ * 1e6


def pct(v, p):
    return S.pct(v, p)


class Run:
    def __init__(self, path, scan):
        self.path = path.rstrip("/")
        self.name = os.path.basename(self.path)
        self.short = short(self.name)
        self.rows, self.frames, self.summ = S.load(self.path)
        self.scheme = self.summ["misc"].get("scheme", "?")
        self.static = scan.get(self.name + ".bin", {})
        self.slack_rows = {}
        with open(os.path.join(self.path, "slack.csv")) as f:
            for r in csv.DictReader(f):
                self.slack_rows[int(r["call"])] = r
        # zero.csv (newer benches): slack to the clock INTIM first reads 0. It
        # also covers calls whose timer is reloaded before it wraps.
        self.zero = None
        zp = os.path.join(self.path, "zero.csv")
        if os.path.exists(zp):
            with open(zp) as f:
                self.zero = {int(r["call"]): int(r["slack_zero_sys"]) for r in csv.DictReader(f)}
        for r in self.rows:
            r["type"] = "%s %s" % (S.phase_of(r["line"]), r["first_bl"][-4:].upper())
            if self.zero is not None:
                z = self.zero.get(r["call"])
                r["slack_zero"] = z
                r["safe"] = r["stall_sys"] + z if z is not None else None
                if r["budget"] is None and r["safe"] is not None:
                    r["budget"] = r["safe"] + TIM64T_SYS
            else:
                r["safe"] = r["budget"] - TIM64T_SYS if r["budget"] is not None else None
                r["slack_zero"] = r["slack"] - TIM64T_SYS if r["slack"] is not None else None
            sr = self.slack_rows.get(r["call"])
            r["poll_pc"] = sr.get("poll_pc") if sr else None
        self.unaligned = None
        self.unaligned_ex = []
        with open(os.path.join(self.path, "summary.txt")) as f:
            for line in f:
                p = line.split()
                if p and p[0] == "unaligned":
                    self.unaligned = (int(p[2]), int(p[4]))
                elif p and p[0] == "unaligned_ex":
                    self.unaligned_ex.append(" ".join(p[1:]))
        self.has_s = "s1_cyc" in self.rows[0]

    @property
    def budgeted(self):
        return [r for r in self.rows if r["safe"] is not None and r["safe"] > 0]

    def harmony_mhz(self):
        pll = self.static.get("pll")
        return {"0x26": 70.0, "0x25": 60.0}.get(pll)


def load_scan(path):
    out = {}
    if not path:
        return out
    for e in json.load(open(path)):
        pll = [x[2] for x in e.get("driver_periph", []) if x[1] == "PLLCFG"]
        out[e["file"]] = {
            "timers": [(t[2], t[3]) for t in e.get("riot_timer_loads", [])],
            "code": tuple(int(x, 16) for x in e.get("code_extent", ["0", "0"])),
            "pll": pll[0] if pll else None,
            "image_end": (int(e["crt0"]["data_rom"], 16) + e["crt0"].get("data_bytes", 0))
            if e.get("crt0") and e["crt0"].get("data_rom") else None,
            "ram_size": e.get("info", {}).get("ram_size"),
        }
    return out


def need(cycles, safe_sys, margin, misses=0, t_miss=0.0):
    t = safe_sys / SYS_HZ * (1 - margin) - misses * t_miss
    return float("inf") if t <= 0 else cycles / t / 1e6


def worst(rs, fn):
    best = None
    for r in rs:
        v = fn(r)
        if best is None or v > best[0]:
            best = (v, r)
    return best


def table(hdr, rows):
    out = ["| " + " | ".join(hdr) + " |", "|" + "|".join("---" for _ in hdr) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(out)


# ------------------------------------------------------------------ sections
def sec_overview(runs, margin):
    hdr = ["Demo", "Scheme", "Image KB", "Calls/frame", "Instr/call p50", "p99", "max",
           "Max instr/frame", "Thumb %", "ARM-state instr", "Ref CPI", "ARM7 0-wait CPI",
           "S1 CPI [E]", "S3 CPI [E]", "Frames != 262 lines", "Polls after wrap", "Polls in INTIM=0"]
    rows = []
    for R in runs:
        rs = R.rows
        ins = [r["instr"] for r in rs]
        fr = defaultdict(int)
        for r in rs:
            fr[r["frame"]] += r["instr"]
        t = R.summ["total"]
        n = t["thumb"] + t["arm"]
        late = sum(1 for r in rs if r["slack"] is not None and r["slack"] < 0)
        zero = sum(1 for r in rs if r["slack_zero"] is not None and r["slack_zero"] < 0 and
                   not (r["slack"] is not None and r["slack"] < 0))
        rows.append([
            R.short, R.scheme, R.summ["misc"]["rom_size"] // 1024,
            "%.2f" % (len(rs) / max(1, len(fr))), pct(ins, 50), pct(ins, 99), max(ins), max(fr.values()),
            "%.2f" % (100.0 * t["thumb"] / n), t["arm"], "%.2f" % (t["arm_cyc"] / n),
            "%.2f" % (t["est_arm7"] / n),
            "%.3f" % (t["s1_cyc"] / n) if "s1_cyc" in t else "-",
            "%.3f" % (t["s3_cyc"] / n) if "s3_cyc" in t else "-",
            sum(1 for f in R.frames if abs(f["lines"] - 262) > 0.01), late, zero])
    return table(hdr, rows)


def sec_types(runs, margin):
    hdr = ["Demo", "Call type", "Calls", "Instr p50", "Instr max", "Held us max (ref)",
           "Budget us min-max", "Safe budget us min", "Ref slack to wrap us min", "Ref uses % of safe", "Static window us"]
    rows = []
    for R in runs:
        g = defaultdict(list)
        for r in R.rows:
            g[r["type"]].append(r)
        wins = sorted(c / CPU_HZ * 1e6 for _, c in R.static.get("timers", []))
        for ty, rs in sorted(g.items(), key=lambda kv: -max(r["instr"] for r in kv[1])):
            if len(rs) < 3:
                continue
            ins = [r["instr"] for r in rs]
            b = [r for r in rs if r["safe"] is not None and r["budget"] is not None]
            win = "-"
            if b:
                # The TIM64T load that fits: the shortest static window holding the budget.
                fit = [w for w in wins if w >= us(max(r["budget"] for r in b)) - 1]
                win = "%.0f" % min(fit) if fit else "-"
            rows.append([
                R.short, ty, len(rs), pct(ins, 50), max(ins), "%.0f" % us(max(r["stall_sys"] for r in rs)),
                "%.0f-%.0f" % (us(min(r["budget"] for r in b)), us(max(r["budget"] for r in b))) if b else "-",
                "%.0f" % us(min(r["safe"] for r in b)) if b else "-",
                "%.0f" % us(min(r["slack_zero"] + TIM64T_SYS for r in b)) if b else "-",
                "%.0f" % max(100.0 * r["stall_sys"] / r["safe"] for r in b) if b else "-", win])
    return table(hdr, rows)


def clock_rows(R, margin):
    """Worst-call clock in MHz under several CPU and memory models."""
    bud = R.budgeted
    res = {}
    for c in S.CPIS:
        res["cpi%.1f" % c] = worst(bud, lambda r, c=c: need(r["instr"] * c, r["safe"], margin))
        res["cpi%.1f_exact" % c] = worst(bud, lambda r, c=c: need(r["instr"] * c, r["safe"], 0))
    if R.has_s:
        res["s1"] = worst(bud, lambda r: need(r["s1_cyc"], r["safe"], margin))
        res["s3"] = worst(bud, lambda r: need(r["s3_cyc"], r["safe"], margin))
        res["s3_flow"] = worst(bud, lambda r: need(r["s3_cyc"] + r["taken"], r["safe"], margin))
        for lab, cols, tm in CACHES:
            res["s1 " + lab] = worst(bud, lambda r, cols=cols, tm=tm: need(
                r["s1_cyc"], r["safe"], margin, sum(r[k] for k in cols), tm))
            res["s3 " + lab] = worst(bud, lambda r, cols=cols, tm=tm: need(
                r["s3_cyc"], r["safe"], margin, sum(r[k] for k in cols), tm))
    return res


def sec_clock(runs, margin):
    hdr = ["Demo", "Worst call (type, instr, safe budget us)", "CPI 1.0 exact", "CPI 1.0", "CPI 1.2",
           "CPI 1.4", "S1 est.", "S3 est.", "S3 +1/flow change", "S1 fits 28.636?", "S3 fits 21.477?"]
    rows = []
    for R in runs:
        res = clock_rows(R, margin)
        v, r = res["cpi1.0"]
        f = lambda k: "%.1f" % res[k][0] if k in res else "-"
        rows.append([
            R.short, "%s, %d, %.0f" % (r["type"], r["instr"], us(r["safe"])),
            f("cpi1.0_exact"), f("cpi1.0"), f("cpi1.2"), f("cpi1.4"), f("s1"), f("s3"), f("s3_flow"),
            ("yes (%.0f%%)" % (100 * res["s1"][0] / S1_MHZ) if res["s1"][0] <= S1_MHZ else
             "no (%.0f%%)" % (100 * res["s1"][0] / S1_MHZ)) if "s1" in res else "-",
            ("yes (%.0f%%)" % (100 * res["s3"][0] / S3_MHZ) if res["s3"][0] <= S3_MHZ else
             "no (%.0f%%)" % (100 * res["s3"][0] / S3_MHZ)) if "s3" in res else "-"])
    out = [table(hdr, rows), ""]
    hdr = ["Demo"] + [lab for lab, _, _ in CACHES]
    for core in ("s1", "s3"):
        rows = []
        for R in runs:
            res = clock_rows(R, margin)
            rows.append([R.short] + ["%.1f" % res["%s %s" % (core, lab)][0] if ("%s %s" % (core, lab)) in res
                                     else "-" for lab, _, _ in CACHES])
        out.append("%s, MHz needed with each memory model:" % core.upper())
        out.append("")
        out.append(table(hdr, rows))
        out.append("")
    return "\n".join(out)


def sec_cache(runs, margin):
    hdr = ["Demo", "Distinct PCs", "Code KiB (16 B lines)", "Per-call max KiB", "Static code span KiB"]
    rows = []
    for R in runs:
        m = R.summ["misc"]
        code = R.static.get("code")
        rows.append([R.short, m["dpc"], "%.1f" % (m["dl16"] * 16 / 1024.0),
                     "%.1f" % (max(r["dist_l16"] for r in R.rows) * 16 / 1024.0),
                     "%.1f" % ((code[1] - code[0]) / 1024.0) if code else "-"])
    out = [table(hdr, rows), ""]
    cfgs = ["1k/16", "2k/16", "4k/16", "8k/16", "16k/16", "4k/32", "8k/32", "16k/32"]
    for s in ("I", "D", "U"):
        hdr = ["Demo (%s)" % s] + [c.upper().replace("K/", "K/") for c in cfgs] + ["worst call misses 8K/16"]
        rows = []
        for R in runs:
            acc, mm = R.summ["cache"][s]
            col = "miss_%s_8k_16" % s
            rows.append([R.short] + ["%.2f" % (100.0 * (1 - mm[c] / max(1, acc))) for c in cfgs] +
                        [max(r[col] for r in R.rows)])
        out.append("Hit rate %%, stream %s:" % s)
        out.append("")
        out.append(table(hdr, rows))
        out.append("")
    # Worst-call stall share for a few configurations (S3 cycles at 21.477 MHz).
    hdr = ["Demo"] + ["%s: misses / stall us / %% of safe budget" % lab for lab, _, _ in CACHES[1:6]]
    rows = []
    for R in runs:
        line = [R.short]
        for lab, cols, tm in CACHES[1:6]:
            r = max(R.budgeted, key=lambda r: sum(r[k] for k in cols) * tm / (r["safe"] / SYS_HZ))
            mi = sum(r[k] for k in cols)
            line.append("%d / %.0f / %.1f%%" % (mi, mi * tm * 1e6, 100.0 * mi * tm / (r["safe"] / SYS_HZ)))
        rows.append(line)
    out.append("Worst call's miss stall (the call that loses the largest share of its budget):")
    out.append("")
    out.append(table(hdr, rows))
    return "\n".join(out)


def sec_mix(runs, margin):
    groups = [g for g, _ in S.THUMB_GROUPS]
    hdr = ["Demo"] + [g.split(" (")[0] for g in groups] + ["changes of flow"]
    rows = []
    agg = defaultdict(Counter)
    for R in runs:
        t = R.summ["total"]
        n = t["thumb"] + t["arm"]
        line = [R.short]
        for gname, keys in S.THUMB_GROUPS:
            c = sum(c for c, _, k in R.summ["kind"] if k.startswith(keys))
            agg[R.scheme][gname] += c
            line.append("%.2f" % (100.0 * c / n))
        agg[R.scheme]["_n"] += n
        agg[R.scheme]["_taken"] += t["taken"]
        line.append("%.1f" % (100.0 * t["taken"] / n))
        rows.append(line)
    for sch in sorted(agg, key=lambda s: SCHEME_ORDER.get(s, 9)):
        a = agg[sch]
        rows.append(["**%s**" % sch] + ["%.2f" % (100.0 * a[g] / a["_n"]) for g in groups] +
                    ["%.1f" % (100.0 * a["_taken"] / a["_n"])])
    out = [table(hdr, rows), ""]
    arm = []
    for R in runs:
        for c, tk, k in R.summ["kind"]:
            if k.startswith("ARM"):
                arm.append("%s: %s x%d" % (R.short, k, c))
    out.append("ARM-state instructions: " + ("; ".join(arm) if arm else "none"))
    det = []
    for R in runs:
        n = R.summ["total"]["thumb"] + R.summ["total"]["arm"]
        det.append("%s: " % R.short + ", ".join("%s %.2f" % (k.split(" (")[0], 100.0 * c / n)
                                                  for c, _, k in R.summ["kind"] if c))
    out.append("")
    out.append("Per format, % of instructions:")
    out.append("")
    out.extend("- " + d for d in det)
    return "\n".join(out)


def dtrace_stats(R):
    p = os.path.join(R.path, "dtrace.txt.gz")
    if not os.path.exists(p):
        return None
    code = R.static.get("code", (0, 0))
    reg = Counter()
    by_size = Counter()
    seq = Counter()          # outside the code span, against the last 4 distinct 32 B lines
    call_lines = []          # per call: distinct 32 B data lines outside the code span
    all_lines = set()
    hist_lines = []
    reuse = []
    cur = set()
    recent = []
    ncalls = 0
    # small D-only cache variants on the reads outside the code span
    variants = [(1024, 32, True), (2048, 32, False), (4096, 32, False), (8192, 32, False), (8192, 64, False),
                (4096, 32, True), (8192, 32, True)]
    tags = [dict() for _ in variants]
    vmiss = [0] * len(variants)
    nout = 0

    def close_call():
        nonlocal cur
        if ncalls:
            call_lines.append(len(cur))
            all_lines.update(cur)
            if len(hist_lines) >= 2 and cur:
                reuse.append(len(cur & hist_lines[-2]) / len(cur))
            hist_lines.append(cur)
            if len(hist_lines) > 2:
                hist_lines.pop(0)
        cur = set()

    with gzip.open(p, "rt") as f:
        for line in f:
            if line.startswith("c "):
                close_call()
                ncalls += 1
                recent = []
                continue
            w = int(line, 16)
            a = w & 0xFFFFFF
            sz = 1 << (w >> 24)
            by_size[sz] += 1
            if code[0] <= a < code[1]:
                reg["code span"] += 1
                continue
            reg["below code" if a < code[0] else "above code"] += 1
            nout += 1
            ln = a >> 5
            cur.add(ln)
            if ln in recent:
                seq["recent"] += 1
                recent.remove(ln)
            elif ln - 1 in recent:
                seq["next"] += 1
            else:
                seq["new"] += 1
            recent.insert(0, ln)
            del recent[4:]
            for i, (size, lsz, pf) in enumerate(variants):
                l2 = a // lsz
                idx = l2 % (size // lsz)
                t = tags[i]
                if t.get(idx) != l2:
                    vmiss[i] += 1
                    t[idx] = l2
                    if pf:   # fetch the next line too
                        t[(l2 + 1) % (size // lsz)] = l2 + 1
    close_call()
    tot = sum(reg.values())
    return {
        "tot": tot, "reg": reg, "by_size": by_size, "seq": seq, "nout": nout,
        "call_kib_max": max(call_lines) * 32 / 1024.0 if call_lines else 0,
        "call_kib_p50": pct([x for x in call_lines if x], 50) * 32 / 1024.0 if any(call_lines) else 0,
        "calls_with_data": sum(1 for x in call_lines if x) / max(1, len(call_lines)),
        "all_kib": len(all_lines) * 32 / 1024.0,
        "reuse": sum(reuse) / len(reuse) if reuse else 0,
        "variants": [(v, m) for v, m in zip(variants, vmiss)],
    }


def sec_rom(runs, margin):
    hdr = ["Demo", "ROM data reads / instr", "byte / half / word %", "KiB read (count, lowest-highest)",
           "Code span %", "Below code %",
           "Above code %", "Outside code vs last 4 lines: same / next / new %",
           "Calls reading data outside code %", "Their data KiB p50 / max", "Data KiB whole run",
           "Lines reused from 2 calls back %", "D hit 4K/16 / 16K/32 %"]
    rows = []
    var_rows = []
    for R in runs:
        t = R.summ["total"]
        n = t["thumb"] + t["arm"]
        acc, mm = R.summ["cache"]["D"]
        d = dtrace_stats(R)
        b, h, w = t["rd_rom_b"], t["rd_rom_h"], t["rd_rom_w"]
        tot = max(1, b + h + w)
        kib = sorted(k for k, c in R.summ["rom"] if c)
        kr = "%d, %d-%d" % (len(kib), kib[0], kib[-1]) if kib else "-"
        if d is None:
            rows.append([R.short, "%.3f" % (t["rd_rom"] / n), "%.0f / %.0f / %.0f" % (
                100.0 * b / tot, 100.0 * h / tot, 100.0 * w / tot), kr] + ["-"] * 8 + [
                "%.1f / %.1f" % (100.0 * (1 - mm["4k/16"] / max(1, acc)), 100.0 * (1 - mm["16k/32"] / max(1, acc)))])
            continue
        rg, sq = d["reg"], d["seq"]
        no = max(1, d["nout"])
        rows.append([
            R.short, "%.3f" % (t["rd_rom"] / n),
            "%.0f / %.0f / %.0f" % (100.0 * b / tot, 100.0 * h / tot, 100.0 * w / tot), kr,
            "%.1f" % (100.0 * rg["code span"] / d["tot"]), "%.1f" % (100.0 * rg["below code"] / d["tot"]),
            "%.1f" % (100.0 * rg["above code"] / d["tot"]),
            "%.0f / %.0f / %.0f" % (100.0 * sq["recent"] / no, 100.0 * sq["next"] / no, 100.0 * sq["new"] / no),
            "%.0f" % (100.0 * d["calls_with_data"]),
            "%.2f / %.2f" % (d["call_kib_p50"], d["call_kib_max"]), "%.1f" % d["all_kib"],
            "%.0f" % (100.0 * d["reuse"]),
            "%.1f / %.1f" % (100.0 * (1 - mm["4k/16"] / max(1, acc)), 100.0 * (1 - mm["16k/32"] / max(1, acc)))])
        var_rows.append([R.short, d["nout"]] + ["%.2f" % (100.0 * (1 - m / max(1, d["nout"])))
                                                for _, m in d["variants"]])
    out = [table(hdr, rows)]
    if var_rows:
        out += ["", "D-only cache variants on the reads outside the code span (hit %):", "",
                table(["Demo", "Reads outside code", "1K/32 + next line", "2K/32", "4K/32", "8K/32", "8K/64",
                       "4K/32 + next line", "8K/32 + next line"], var_rows)]
    return "\n".join(out)


def sec_ram(runs, margin):
    hdr = ["Demo", "RAM KiB touched (reads or writes)", "Highest KiB", "Mapper RAM KiB", "RAM reads / instr",
           "RAM writes / instr", "Unaligned rd / wr (bus)"]
    rows = []
    for R in runs:
        t = R.summ["total"]
        n = t["thumb"] + t["arm"]
        kib = sorted(k for k, rd, wr in R.summ["ram"] if rd or wr)
        rows.append([R.short, ",".join(str(k) for k in kib), max(kib) + 1 if kib else 0,
                     R.static.get("ram_size", 0) // 1024 if R.static.get("ram_size") else "-",
                     "%.3f" % (t["rd_ram"] / n), "%.3f" % (t["wr_ram"] / n),
                     "%d / %d" % R.unaligned if R.unaligned else "-"])
    out = [table(hdr, rows)]
    ex = ["%s: %s" % (R.short, "; ".join(R.unaligned_ex[:4])) for R in runs if R.unaligned_ex]
    if ex:
        out += ["", "Unaligned examples: " + " | ".join(ex)]
    return "\n".join(out)


def sec_schemes(runs, margin):
    """One line per scheme: the worst of its demos."""
    hdr = ["Scheme", "Demos", "Calls/frame", "Instr/call max (demo)", "Typical VB / OS call instr (p50 range)",
           "Ref max % of safe budget", "MHz @CPI 1.0 / 1.2 / 1.4, margin", "S1 / S3 est. MHz, margin",
           "Late calls S1@28.636 / S3@21.477 / S3 CPI@28.636", "Code KiB run / per call", "Thumb %"]
    by = defaultdict(list)
    for R in runs:
        by[R.scheme].append(R)
    rows = []
    for sch in sorted(by, key=lambda s: SCHEME_ORDER.get(s, 9)):
        rs = by[sch]
        allc = [r for R in rs for r in R.rows]
        fr = sum(len(set(r["frame"] for r in R.rows)) for R in rs)
        mx = max(((r["instr"], R.short) for R in rs for r in R.rows))
        vb = [pct([r["instr"] for r in R.rows if r["type"].startswith("VB")], 50) for R in rs]
        os_ = [pct([r["instr"] for r in R.rows if r["type"].startswith("OS")], 50) for R in rs]
        ref = max(r["stall_sys"] / r["safe"] for R in rs for r in R.budgeted)
        cl = [clock_rows(R, margin) for R in rs]
        mxk = lambda k: max(c[k][0] for c in cl) if all(k in c for c in cl) else float("nan")
        late = [0, 0, 0]
        for R in rs:
            if not R.has_s:
                continue
            for r in R.budgeted:
                b = r["safe"] / SYS_HZ
                late[0] += r["s1_cyc"] / (S1_MHZ * 1e6) > b
                late[1] += r["s3_cyc"] / (S3_MHZ * 1e6) > b
                late[2] += r["s3_cyc"] / (S1_MHZ * 1e6) > b
        t = [R.summ["total"] for R in rs]
        rows.append([
            sch, ", ".join(R.short for R in rs), "%.2f" % (len(allc) / max(1, fr)), "%d (%s)" % mx,
            "%d-%d / %d-%d" % (min(vb), max(vb), min(os_), max(os_)), "%.0f%%" % (100 * ref),
            "%.1f / %.1f / %.1f" % (mxk("cpi1.0"), mxk("cpi1.2"), mxk("cpi1.4")),
            "%.1f / %.1f" % (mxk("s1"), mxk("s3")), "%d / %d / %d" % tuple(late),
            "%.1f / %.1f" % (max(R.summ["misc"]["dl16"] * 16 / 1024.0 for R in rs),
                             max(max(r["dist_l16"] for r in R.rows) * 16 / 1024.0 for R in rs)),
            "%.2f" % (100.0 * sum(x["thumb"] for x in t) / sum(x["thumb"] + x["arm"] for x in t))])
    return table(hdr, rows)


def frame_runs(frames):
    out = []
    for f in sorted(set(frames)):
        if out and f == out[-1][1] + 1:
            out[-1][1] = f
        else:
            out.append([f, f])
    return ", ".join("%d" % a if a == b else "%d-%d" % (a, b) for a, b in out)


def sec_late(runs, margin):
    """Frames whose calls would end after the INTIM-zero deadline (block RAM, zero-wait)."""
    hdr = ["Demo", "S3 @21.477: late calls (frames)", "S1 @28.636: late calls (frames)",
           "S3 CPI @28.636: late calls (frames)",
           "Max share of safe budget, all calls: S3 @21.477 / S1 / S3 CPI @28.636",
           "Steady play (frames >= 600): max S3 / S1 share"]
    rows = []
    for R in runs:
        if not R.has_s:
            continue
        bud = R.budgeted
        l3 = [r["frame"] for r in bud if r["s3_cyc"] / (S3_MHZ * 1e6) > r["safe"] / SYS_HZ]
        l1 = [r["frame"] for r in bud if r["s1_cyc"] / (S1_MHZ * 1e6) > r["safe"] / SYS_HZ]
        l33 = [r["frame"] for r in bud if r["s3_cyc"] / (S1_MHZ * 1e6) > r["safe"] / SYS_HZ]
        share = lambda col, mhz: max(((r[col] / (mhz * 1e6)) / (r["safe"] / SYS_HZ) for r in bud), default=0)
        steady = [r for r in bud if r["frame"] >= 600]
        sh3 = max((r["s3_cyc"] / (S3_MHZ * 1e6)) / (r["safe"] / SYS_HZ) for r in steady) if steady else 0
        sh1 = max((r["s1_cyc"] / (S1_MHZ * 1e6)) / (r["safe"] / SYS_HZ) for r in steady) if steady else 0
        rows.append([R.short, "%d (%s)" % (len(l3), frame_runs(l3) or "-"),
                     "%d (%s)" % (len(l1), frame_runs(l1) or "-"), "%d (%s)" % (len(l33), frame_runs(l33) or "-"),
                     "%.0f%% / %.0f%% / %.0f%%" % (100 * share("s3_cyc", S3_MHZ), 100 * share("s1_cyc", S1_MHZ),
                                                   100 * share("s3_cyc", S1_MHZ)),
                     "%.0f%% / %.0f%%" % (100 * sh3, 100 * sh1)])
    return table(hdr, rows)


def sec_harmony(runs, margin):
    """The call that uses most of its budget on a Harmony at zero wait.

    Harmony range [E]: from the ARM7TDMI zero-wait cycles (est_arm7) to that
    plus MAMTIM clocks (4 at 70 MHz, 3 at 60) for every change of flow and
    every ROM data read, as if the MAM's branch-trail and data buffers always
    missed. Sequential fetches are taken as covered by the MAM's prefetch.
    """
    hdr = ["Demo", "Harmony MHz", "Call (type, instr)", "ARM7 0-wait cycles", "Harmony us, 0-wait .. all MAM misses",
           "Safe budget us", "Ref 71.59 MHz us", "DARIA S1 @28.636 us", "DARIA S3 @21.477 us",
           "S3 vs Harmony 0-wait"]
    rows = []
    for R in runs:
        mhz = R.harmony_mhz()
        bud = R.budgeted
        if not bud or not mhz:
            continue
        mamtim = 4 if mhz == 70.0 else 3
        r = max(bud, key=lambda r: r["est_arm7"] / r["safe"])
        hi = r["est_arm7"] + mamtim * (r["taken"] + r["rd_rom"])
        rows.append([R.short, int(mhz), "%s, %d" % (r["type"], r["instr"]), r["est_arm7"],
                     "%.0f .. %.0f" % (r["est_arm7"] / mhz, hi / mhz), "%.0f" % us(r["safe"]),
                     "%.0f" % (r["arm_cyc"] / ARM_HZ * 1e6),
                     "%.0f" % (r["s1_cyc"] / S1_MHZ) if R.has_s else "-",
                     "%.0f" % (r["s3_cyc"] / S3_MHZ) if R.has_s else "-",
                     "%.2fx" % ((r["s3_cyc"] / S3_MHZ) / (r["est_arm7"] / mhz)) if R.has_s else "-"])
    return table(hdr, rows)


def sec_overruns(runs, margin):
    """Calls that would end after the INTIM-zero deadline, per core and memory model."""
    models = [("S3 @21.477, block RAM", "s3_cyc", S3_MHZ, [], 0.0),
              ("S1 @28.636, block RAM", "s1_cyc", S1_MHZ, [], 0.0),
              ("S1 @28.636, U 16K/16", "s1_cyc", S1_MHZ, ["miss_U_16k_16"], T16),
              ("S1 @28.636, I 4K + D 2K", "s1_cyc", S1_MHZ, ["miss_I_4k_16", "miss_D_2k_16"], T16),
              ("S3 CPI @28.636, block RAM", "s3_cyc", S1_MHZ, [], 0.0),
              ("S3 CPI @28.636, code in BRAM + D 8K/32", "s3_cyc", S1_MHZ, ["miss_D_8k_32"], T32),
              ("S3 CPI +1/flow change @28.636, block RAM", "s3f", S1_MHZ, [], 0.0),
              ("S3 @42.955, block RAM", "s3_cyc", 42.955, [], 0.0)]
    hdr = ["Demo", "Budgeted calls"] + ["%s: late / over 80%%" % m[0] for m in models]
    rows = []
    for R in runs:
        if not R.has_s:
            continue
        bud = R.budgeted
        line = [R.short, len(bud)]
        for _, col, mhz, cols, tm in models:
            late = over = 0
            for r in bud:
                cyc = r["s3_cyc"] + r["taken"] if col == "s3f" else r[col]
                t = cyc / (mhz * 1e6) + sum(r[k] for k in cols) * tm
                b = r["safe"] / SYS_HZ
                late += t > b
                over += t > 0.8 * b
            line.append("%d / %d" % (late, over))
        rows.append(line)
    return table(hdr, rows)


def sec_polls(runs, margin):
    hdr = ["Demo", "Call type", "Poll PC", "Calls", "End to poll us", "Slack to wrap us min / p50"]
    rows = []
    for R in runs:
        g = defaultdict(list)
        for r in R.rows:
            if r["slack"] is not None and r["poll_pc"]:
                g[(r["type"], r["poll_pc"])].append(r)
        for (ty, pc), rs in sorted(g.items()):
            if len(rs) < 3:
                continue
            sl = sorted(r["slack"] for r in rs)
            rows.append([R.short, ty, pc, len(rs), "%.0f" % us(pct([r["to_poll"] for r in rs], 50)),
                         "%.0f / %.0f" % (us(sl[0]), us(pct(sl, 50)))])
    return table(hdr, rows)


def sec_determinism(runs, margin, ref):
    hdr = ["Demo", "Calls compared", "Columns", "Differences"]
    rows = []
    for R in runs:
        p = os.path.join(ref, R.name)
        if not os.path.isdir(p):
            continue
        old = list(csv.DictReader(gzip.open(os.path.join(p, "calls.csv.gz"), "rt")))
        new = list(csv.DictReader(gzip.open(os.path.join(R.path, "calls.csv.gz"), "rt")))
        diff = sum(1 for a, b in zip(new, old) for k in b if a.get(k) != b[k])
        rows.append([R.short, "%d / %d" % (len(new), len(old)), len(old[0]), diff])
    return table(hdr, rows)


SECTIONS = ["schemes", "overview", "types", "clock", "overruns", "late", "cache", "mix", "rom", "ram", "harmony", "polls",
            "determinism"]


def main():
    args = sys.argv[1:]
    opts = {"--scan": None, "--margin": "0.2", "--only": ",".join(SECTIONS), "--ref": None}
    i = 0
    dirs = []
    while i < len(args):
        if args[i] in opts:
            opts[args[i]] = args[i + 1]
            i += 2
        else:
            dirs.append(args[i])
            i += 1
    scan = load_scan(opts["--scan"])
    margin = float(opts["--margin"])
    runs = []
    for d in dirs:
        # A run in progress (or being redone) has a plain calls.csv: leave it out.
        if (os.path.exists(os.path.join(d, "calls.csv.gz")) and os.path.exists(os.path.join(d, "report.txt"))
                and not os.path.exists(os.path.join(d, "calls.csv"))):
            runs.append(Run(d, scan))
    runs.sort(key=lambda R: (SCHEME_ORDER.get(R.scheme, 9), R.short))
    for sec in opts["--only"].split(","):
        if sec == "determinism":
            if not opts["--ref"]:
                continue
            body = sec_determinism(runs, margin, opts["--ref"])
        else:
            body = globals()["sec_" + sec](runs, margin)
        print("### %s\n\n%s\n" % (sec, body))


if __name__ == "__main__":
    main()
