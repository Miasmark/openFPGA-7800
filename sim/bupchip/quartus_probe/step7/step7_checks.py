#!/usr/bin/env python3
"""The step-7 checks that read report files (docs/daria_step7/plan.md 5.4),
and the verdict per kind of build (run_step7.sh).

Usage: step7_checks.py DIR
  DIR holds fpga/ (the compiled copy, with output_files/, step7_prep.txt and
  the files step7_report.tcl wrote), quartus.log (the compile) and report.log
  (quartus_sta -t step7_report.tcl).

Reads checks.txt (step7_report.tcl's STA checks) and adds:
  (c) netlist optimizations: no first flop of plan 2.7 present in this build,
      and neither pd_tog nor pd_rx, is duplicated or retimed by the fitter;
      nor is sram|t_*_q retimed (Fix B check 4, part of (h))
  (e) daria_constraints.sdc read without a warning, and the status of its
      four +-20 ns lines and its 6 / 1 ns pair in report_exceptions
  (f) report_metastability: every first flop present in this build heads a
      chain identified "Forced"; no other chain is forced
  (k') every clk_sys <-> clk_arm endpoint is in f3_crossings.txt for this
      kind of build, and each first flop's whole fan-in (fanin.tsv: every
      timed path into it, from any clock) is one register of the other clock;
      a first flop with a synchronous reset of its own clock (class "reset")
      may have one more register, of its own clock (P21). The logic levels
      are listed, not judged: a NOT gate before an inverted register (a
      power-up value of 1) or a routing cell the router inserts has one input
      and cannot glitch, while logic with two registers in its fan-in fails
      whatever its depth
  (m) area: ALMs needed, the share of the device, LABs, peak interconnect
      usage, M10K
  (n) psram's CLOCK_SPEED in the synthesis report: 50.0 with DARIA,
      28.636364 without (P18)
  (o) the PSRAM pins' datasheet figures (reported, not gating)
  (report) step7_report.tcl ran to its end ("# step7_report.tcl: end" in
      checks.txt) and quartus_sta exited 0 (fpga/report_rc.txt, written by
      run_step7.sh)
Then prints every check with PASS, FAIL or INFO, and the verdict: the checks
that gate this kind of build (5.4: the chain checks only with DARIA; the Fix B
checks with Fix B; on aeee6d2, kind base, (g) is the negative control and must
FAIL). Every gating check must be present: one that never ran (quartus_sta
stopped, a report file missing) fails as "not reported". Exit status 0 when
every gating check passes.
"""
import os
import re
import sys

d = sys.argv[1]
fpga = os.path.join(d, "fpga")
out = os.path.join(fpga, "output_files")
here = os.path.dirname(os.path.abspath(__file__))


def rd(p):
    try:
        with open(p, encoding="latin-1") as f:
            return f.read()
    except FileNotFoundError:
        return None


prep = {}
for line in (rd(os.path.join(fpga, "step7_prep.txt")) or "").splitlines():
    k, _, v = line.partition(" ")
    prep[k] = v
kind = prep.get("kind", "?")
daria = kind in ("daria", "q5")
results = []          # (id, verdict, text)

# A section of step7_report.tcl that failed reports every check it makes;
# older reports named the section instead, so those names stand for them.
SECTION_IDS = {"ab": ["a", "b", "d"], "kfan": ["k'"], "sdram": ["sdram.files"]}


def check(cid, verdict, text):
    for c in SECTION_IDS.get(cid, [cid]):
        results.append((c, verdict, text))


def glob_re(pat):
    """'*' matches anything; everything else is literal."""
    return re.compile("^" + ".*".join(re.escape(p) for p in pat.split("*")) + "$")


def strip_suffix(name):
    return re.sub(r"~(DUPLICATE|feeder|_Duplicate|_emulated|_NEW_REG\d*|_OTERM\d*|RTM\d*)\S*$", "", name)


# ---- checks.txt -----------------------------------------------------------------------
ct = rd(os.path.join(fpga, "checks.txt"))
detail = []
if kind not in ("base", "builda", "daria", "q5"):
    check("kind", "FAIL", f"unknown kind of build '{kind}' (fpga/step7_prep.txt missing or wrong)")
rc = (rd(os.path.join(fpga, "report_rc.txt")) or "").strip()
if ct is None:
    check("report", "FAIL", "checks.txt missing: step7_report.tcl did not run or failed (report.log)")
else:
    for line in ct.splitlines():
        m = re.match(r"CHECK (\S+) (PASS|FAIL|INFO): (.*)", line)
        if m:
            check(m.group(1), m.group(2), m.group(3))
        detail.append(line)
    ended = "# step7_report.tcl: end" in ct
    if not ended or rc not in ("", "0"):
        check("report", "FAIL", ("step7_report.tcl stopped before its end; " if not ended else "")
              + (f"quartus_sta exited {rc}; " if rc not in ("", "0") else "") + "see report.log")
    else:
        check("report", "PASS", "step7_report.tcl ran to its end" + (", quartus_sta exit 0" if rc == "0" else
                                                                    " (no report_rc.txt: exit status not recorded)"))

# ---- the expected crossing table -------------------------------------------------------------
table = []
for line in (rd(os.path.join(here, "f3_crossings.txt")) or "").splitlines():
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    dirn, builds, cls, ep, src = line.split()
    table.append(dict(dir=dirn, builds=builds.split(","), cls=cls, ep=ep, re=glob_re(ep),
                      src=src, src_re=None if src == "-" else glob_re(src)))
expected_here = [t for t in table if kind in t["builds"]]
firsts_here = [t for t in expected_here if t["cls"] in ("first", "reset", "guard")]

# ---- (c): the fitter's netlist optimizations -------------------------------------------------------
fit = rd(os.path.join(out, "ap_core.fit.rpt"))
if fit is None:
    check("c", "FAIL", "ap_core.fit.rpt missing")
    check("h.retime", "FAIL", "ap_core.fit.rpt missing: the retiming of sram|t_*_q is not known")
else:
    i = fit.find("; Fitter Netlist Optimizations")
    sec = fit[i:fit.find("\n\n\n", i)] if i >= 0 else ""
    rows = []
    for line in sec.splitlines():
        cols = [c.strip() for c in line.strip().strip(";").split(";")]
        if len(cols) >= 3 and "|" in cols[0]:
            rows.append(cols)
    watch = [t for t in firsts_here] + [dict(ep="*|daria_fe_guard:u_guard|pd_tog", re=glob_re("*|daria_fe_guard:u_guard|pd_tog"))]
    # Each row of the table that duplicates or retimes a watched register, by
    # the register's own name (a duplicate's suffix stripped), named in full:
    # the node, what was done (action, operation, reason) and the node it made
    # (the Destination Node column: the duplicate, "<name>~DUPLICATE").
    bad = []
    for t in watch:
        for cols in rows:
            if t["re"].match(strip_suffix(cols[0])) and re.search(r"Duplicat|Retim", " ".join(cols[1:3]), re.I):
                made = cols[6] if len(cols) > 6 and cols[6] else "-"
                bad.append(f"{cols[0]} {cols[1].lower()} as {made} ({cols[2]}; {cols[3] if len(cols) > 3 else '-'})")
    tbad = [f"{c[0]}: {c[1]} / {c[2]}" for c in rows
            if re.search(r"\|sram_ctrl:sram\|t_\w+_q", c[0]) and re.search(r"Retim", " ".join(c[1:3]), re.I)]
    if i < 0:
        check("c", "INFO", "the fit report has no Fitter Netlist Optimizations table (nothing optimized)")
    elif daria:
        check("c", "FAIL" if bad else "PASS",
              f"{len(rows)} optimized nodes; pd_tog, pd_rx and the {len([t for t in firsts_here if t['cls'] != 'guard'])} "
              "first flops of this build: "
              + (f"{len(bad)} duplicated or retimed: " + "; ".join(bad) if bad else "none duplicated or retimed"))
    else:
        check("c", "FAIL", "no DARIA in this build: the first flops of plan 2.7 are not there (no such cell)")
    if prep.get("fixb") == "1":
        check("h.retime", "FAIL" if tbad else "PASS",
              "sram|t_*_q " + ("retimed: " + "; ".join(tbad) if tbad else "not retimed by the fitter"))
    else:
        check("h.retime", "FAIL", "no Fix B in this build: no sram|t_*_q (no such cell)")

# ---- (e): the SDC file and its exceptions -------------------------------------------------------------
log = (rd(os.path.join(d, "quartus.log")) or "") + (rd(os.path.join(d, "report.log")) or "")
warn = [l.strip() for l in log.splitlines() if "daria_constraints.sdc" in l and re.search(r"Warning|Error", l)]
exc = rd(os.path.join(fpga, "exceptions.rpt")) or ""
summ = exc[:exc.find("\n\n")] if exc else ""
want = [("set_max_delay", "counter[0]", "counter[3]", "20.000"), ("set_max_delay", "counter[3]", "counter[0]", "20.000"),
        ("set_min_delay", "counter[0]", "counter[3]", "-20.000"), ("set_min_delay", "counter[3]", "counter[0]", "-20.000"),
        ("set_max_delay", "pd_tog", "pd_rx", "6.000"), ("set_min_delay", "pd_tog", "pd_rx", "1.000")]
estat = []
eok = True
for cmd, fr, to, val in want:
    st = None
    for line in summ.splitlines():
        cols = [c.strip() for c in line.strip().strip(";").split(";")]
        if len(cols) >= 9 and cols[1] == cmd and fr in cols[4] and to in cols[7] and cols[8] == val:
            st = cols[0]
    estat.append(f"{cmd} {fr}->{to} {val}: {st or 'not listed'}")
    if st is None:
        eok = False
    elif cmd and fr == "counter[3]" and to == "counter[0]":
        if st.lower() not in ("complete", "partially overridden"):
            eok = False
    elif st.lower() != "complete":
        eok = False
read_ok = "daria_constraints.sdc" in log
if not daria:
    check("e", "FAIL", "no DARIA in this build: daria_constraints.sdc not read (no such file in the SDC set); "
          + "; ".join(estat))
else:
    check("e", "PASS" if eok and not warn and read_ok else "FAIL",
          ("read; " if read_ok else "NOT seen in the logs; ") + (f"{len(warn)} warning(s): " + " | ".join(warn[:3]) + "; " if warn else "no warnings; ")
          + "; ".join(estat) + " (clk_arm -> clk_sys lines may be Partially Overridden by the pair; (k) shows where)")

# ---- (f): metastability -----------------------------------------------------------------------------
# report_metastability writes one block per chain ("Synchronizer Chain #n"),
# whose Chain Summary names the Synchronization Node (the first flop) and
# whose Statistics give the "Method of Synchronizer Identification":
# "Automatic", or "User Specified" for a register marked FORCED (by an RTL
# attribute or an instance assignment). Plan 5.4 (f)'s "Forced" is the latter.
meta = rd(os.path.join(fpga, "metastability.rpt"))
if meta is None:
    check("f", "FAIL", "metastability.rpt missing")
else:
    chains = []
    for b in re.split(r"(?m)^Synchronizer Chain #\d+:", meta)[1:]:
        m = re.search(r";\s*Synchronization Node\s*;\s*([^;]+?)\s*;", b)
        k = re.search(r";\s*Method of Synchronizer Identification\s*;\s*([^;]+?)\s*;", b)
        if m:
            chains.append((strip_suffix(m.group(1)), k.group(1) if k else "?"))
    user = [c for c, how in chains if how.lower().startswith("user")]
    want_f = [t for t in firsts_here if t["cls"] != "guard"]
    miss, auto = [], []
    for t in want_f:
        how = [h for c, h in chains if t["re"].match(c)]
        if not how:
            miss.append(t["ep"])
        elif not any(h.lower().startswith("user") for h in how):
            auto.append(f"{t['ep']} ({'/'.join(how)})")
    firsts_all = [t for t in table if t["cls"] in ("first", "reset")]
    other = [c for c in user if not any(t["re"].match(c) for t in firsts_all)]
    ours = [c for c in other if re.search(r"\|(bupchip_pocket|daria_\w+|bup_\w+):", c)]
    if not chains:
        check("f", "FAIL", "no synchronizer chain in metastability.rpt (or its format is not the expected one)")
    elif not daria:
        check("f", "FAIL", f"no DARIA in this build: no DARIA chain (no such cell); {len(chains)} chains, "
              f"{len(user)} user specified: {user[:6]}")
    else:
        check("f", "FAIL" if miss or auto or ours else "PASS",
              f"{len(chains)} chains, {len(user)} user specified (Forced); first flops with no chain: {miss or 'none'}; "
              f"identified automatically, not Forced: {auto or 'none'}; other Forced chains in the BupChip or DARIA: "
              f"{ours or 'none'}; other Forced chains elsewhere (information): {[c for c in other if c not in ours][:6] or 'none'}")

# ---- (k'): the crossing endpoints and the first flops' fan-in -----------------------------------------------
tsv = rd(os.path.join(fpga, "crossings.tsv"))
fan = rd(os.path.join(fpga, "fanin.tsv"))
if tsv is None or fan is None:
    check("k'", "FAIL", ("crossings.tsv" if tsv is None else "fanin.tsv") + " missing (report.log)")
else:
    rows = [l.split("\t") for l in tsv.splitlines()[1:] if l.strip()]
    unexpected = []
    crossing = {}         # first flop pattern -> its crossing sources (from crossings.tsv)
    for r in rows:
        dirn, rel, sl, hrel, hsl, lv, fr, to = r
        ep = strip_suffix(to)
        hit = [t for t in expected_here if t["dir"] == dirn and t["re"].match(ep)]
        if not hit:
            unexpected.append(f"{dirn} {to} <- {fr}")
            continue
        t = hit[0]
        if t["cls"] in ("first", "reset", "guard"):
            crossing.setdefault(t["ep"], set()).add(strip_suffix(fr))
    # fanin.tsv: pattern, to, to_clock, from, from_clock, levels, slack
    frows = [l.split("\t") for l in fan.splitlines()[1:] if l.strip()]
    bad_first, levels, renamed = [], [], []
    for t in firsts_here:
        regs = {}
        for _, to, tclk, fr, fclk, lv, _sl in frows:
            if t["re"].match(strip_suffix(to)):
                regs.setdefault(to, [])
                if fr != "-":
                    regs[to].append((strip_suffix(fr), fclk, tclk, int(lv)))
        if not regs:
            bad_first.append(f"{t['ep']}: no such cell, or no timed path into it")
            continue
        for to, paths in sorted(regs.items()):
            srcs = {}
            for fr, fclk, tclk, lv in paths:
                srcs.setdefault((fr, fclk != tclk), []).append(lv)
            cross = sorted(f for f, x in srcs if x)
            same = sorted(f for f, x in srcs if not x)
            allow = 1 if t["cls"] == "reset" else 0
            if len(cross) != 1 or len(same) > allow:
                bad_first.append(f"{to}: fan-in {len(cross)} register(s) of the other clock {cross[:4]}, "
                                 f"{len(same)} of its own (at most {allow}) {same[:4]}")
            lv = max(max(v) for v in srcs.values()) if srcs else 0
            if lv:
                levels.append(f"{strip_suffix(to).split('|')[-1]} {lv}")
            if len(cross) == 1 and t["src_re"] and not t["src_re"].match(cross[0]):
                renamed.append(f"{t['ep']} <- {cross[0]} (expected {t['src']})")
        if t["ep"] not in crossing:
            bad_first.append(f"{t['ep']}: no clk_sys <-> clk_arm path into it in crossings.tsv")
    if not daria:
        check("k'", "FAIL", f"no DARIA in this build: {len(rows)} crossing pairs; no DARIA endpoint (no such cell)")
    else:
        check("k'", "FAIL" if unexpected or bad_first or not rows else "PASS",
              f"{len(rows)} pairs; unexpected endpoints: {len(unexpected)} {unexpected[:6]}; first flops wrong: "
              f"{bad_first or 'none'}; logic levels on a one-register fan-in (not judged): {levels or 'none'}; "
              f"sources named otherwise: {renamed or 'none'}")

# ---- (m): area ------------------------------------------------------------------------------------------------
fs = rd(os.path.join(out, "ap_core.fit.summary")) or ""
area = []
for key in ("Logic utilization", "Total RAM Blocks", "Total registers"):
    m = re.search(key + r"[^:]*:\s*(.*)", fs)
    if m:
        area.append(f"{key}: {m.group(1).strip()}")
if fit:
    # The fit report's Fitter Resource Usage Summary: plan 5.1's "peak
    # interconnect usage (fit report, routing usage)" is its total/H/V row.
    for key, label in ((r"ALMs needed \[=A-B\+C\]", "ALMs needed"),
                       (r"Total LABs:\s+partially or completely used", "LABs"),
                       (r"M10K blocks", "M10K blocks"),
                       (r"Peak interconnect usage \(total/H/V\)", "peak interconnect usage (total/H/V)"),
                       (r"Average interconnect usage \(total/H/V\)", "average interconnect usage (total/H/V)")):
        m = re.search(r";\s*" + key + r"\s*;\s*([^;]+);", fit)
        if m:
            area.append(f"{label}: {m.group(1).strip()}")
    # The router's own estimate, for one region of the device (a different
    # figure from the summary's: Q0 seed 2 had 36% here and 40.4% there).
    pk = re.findall(r"[Pp]eak interconnect usage is (\d+)%[^\n]*", fit)
    if pk:
        area.append(f"router's estimate of the peak in one region {max(int(x) for x in pk)}%")
check("m", "INFO" if area else "FAIL", "; ".join(area) if area else "no fit summary")

# ---- (n): psram's CLOCK_SPEED -------------------------------------------------------------------------------------------
mp = rd(os.path.join(out, "ap_core.map.rpt")) or ""
i = mp.find("Parameter Settings for User Entity Instance: core_top:ic|atari7800_pocket:atari|psram:bup_psram ;")
cs = None
if i >= 0:
    m = re.search(r";\s*CLOCK_SPEED\s*;\s*([-0-9.]+)\s*;", mp[i:i + 4000])
    cs = m.group(1) if m else None
want_cs = "50.0" if daria else "28.636364"
check("n", "PASS" if cs is not None and abs(float(cs) - float(want_cs)) < 1e-6 else "FAIL",
      f"psram:bup_psram CLOCK_SPEED {cs if cs is not None else 'not found'} (expected {want_cs})")

# ---- (o): the PSRAM pins ----------------------------------------------------------------------------------------------
ds = rd(os.path.join(fpga, "datasheet.rpt")) or ""
pins = []
for line in ds.splitlines():
    if re.search(r";\s*cram0_(a\[|adv_n|oe_n|dq\[)", line):
        cols = [c.strip() for c in line.strip().strip(";").split(";")]
        pins.append(" ".join(cols[:6]))
check("o", "INFO", f"{len(pins)} datasheet rows for cram0_a, adv_n, oe_n, dq (datasheet.rpt); first: {pins[:4]}")

# ---- verdict -----------------------------------------------------------------------------------------------------
DARIA_CHECKS = {"a", "b", "c", "c.cells", "e", "f", "k", "k'", "j", "gate.clk_arm"}
FIXB_CHECKS = {"g", "g.legs", "h", "h.retime"}
ALL_CHECKS = {"l", "l.clocks", "gate.hold", "n", "report", "i", "p", "kind"}
gating = set(ALL_CHECKS)
if kind in ("daria", "q5"):
    gating |= DARIA_CHECKS | FIXB_CHECKS | {"gate.clk_sdram"}
elif kind == "builda":
    gating |= FIXB_CHECKS
# Q5's +1.5 ns is reported, not required (P29).
if kind == "q5":
    gating.discard("gate.clk_sdram")
# Every gating check, and on aeee6d2 the negative control, must be there: one
# that never ran fails.
required = (gating - {"kind"}) | ({"g"} if kind == "base" else set())
for cid in sorted(required - {c for c, _, _ in results}):
    results.append((cid, "FAIL", "not reported: the check never ran (report.log, the compile's reports)"))
print(f"== step-7 checks: {d}")
print(f"   kind {kind}; " + " ".join(f"{k}={v}" for k, v in prep.items() if k != "kind"))
fails = []
for cid, verdict, text in results:
    role = "gating" if cid in gating else "info"
    if kind == "base" and cid == "g":
        role = "negative control (must FAIL on aeee6d2)"
        if verdict == "PASS" or text.startswith("not reported") or "no such cell" in text or "Tcl error" in text:
            fails.append(cid)
    elif role == "gating" and verdict == "FAIL":
        fails.append(cid)
    print(f"  ({cid}) {verdict} [{role}] {text}")
print("verdict: " + ("PASS" if not fails else "FAIL: " + " ".join(fails)))
with open(os.path.join(d, "checks_summary.txt"), "w") as f:
    f.write("\n".join(f"({c}) {v} {t}" for c, v, t in results) + "\n")
    f.write("verdict: " + ("PASS" if not fails else "FAIL: " + " ".join(fails)) + "\n")
    f.write("\n# step7_report.tcl's detail\n" + "\n".join(detail) + "\n")
sys.exit(1 if fails else 0)
