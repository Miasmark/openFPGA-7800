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
      nor is sram|t_*_q retimed (Fix B check 4, part of (h)). A fit report
      without the Fitter Netlist Optimizations table fails both
  (c.cells) judged again from step7_report.tcl's counts (firstflops.tsv) by
      the tree's plan 2.7 table (step7_report.tcl's ff_table), so that a
      corrected table re-judges a fit with no refit; a misread as for (a)
  (e) daria_constraints.sdc read without a warning, and the status of its
      four +-20 ns lines and of the guard pair's two lines, at the SDC's
      bounds (below), in report_exceptions; the fitter-only line on the pair
      in the run directory's copy of the SDC is reported, not gated
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
The guard pair's bounds (plan 5.4 as amended for G1, 2026-10-19, in
docs/daria_step10/plan.md section 10): what
(a), (b), (k) and (e) hold pd_tog -> pd_rx to is the SDC's, as the Timing
Analyzer read it for this fit (sdc.rpt: its one set_max_delay and one
set_min_delay from pd_tog to pd_rx), and must be a row of the tree's table of
known pairs (step7_report.tcl's guard_pairs): [1.000, 6.000] ns as first
written (design.md 8.2, fitter 5.5) or G1's [0.500, 8.000] ns (fitter 7.5).
Any other pair, a line missing or given twice, or no sdc.rpt fails (a), (b),
(k) and (e). (a), (b) and (k) are judged again by those bounds from the
report script's per-corner lines of the pair (checks.txt) and crossings.tsv;
this script's reading of them by the bounds the report script used (its
"# guard bounds:" line; 6.000 / 1.000 ns in a report written before that
line existed) must give the report script's verdict, or the check fails as
a misread. So a G1 fit judged by the older report script, which held the
pair to 6 / 1, is judged again correctly from its own files.
It also judges (a), (l) and (h) again by the build's divider (plan 5.4 as
amended 2026-10-14, the lead's decision on Q2 at VCO/19), from the figures
that step7_report.tcl wrote and judged by the rules as first written:
  (a) at VCO/19 the guard pair's setup slack is reported, not gated; there
      must still be exactly one setup path pd_tog -> pd_rx at every corner,
      with the SDC's relationship (the constraint applied, the pair single)
  (l) at VCO/19 the guard pair's setup, and only it, is left out: a negative
      clk_sys setup slack at a corner passes when it is pd_tog -> pd_rx's
      slack there and the compile's Timing Analyzer summary (ap_core.sta.rpt)
      shows no other failing clk_sys endpoint (its Slack and End Point TNS
      both equal to the pair's slack), pd_rx's only timed fan-in being pd_tog
      (fanin.tsv). The pair's hold stays in (l), (b) and gate.hold
  (h) t_*_q -> clk_sdram setup >= +3.0 ns at VCO/19 (+4.5 ns otherwise)
  Any other divider (VCO/18; 24, a build without DARIA) keeps the rules as
  first written. This script's own reading of the figures by those rules
  must give the report script's verdict, or the check fails (a misread).
Then prints every check with PASS, FAIL or INFO, and the verdict: the checks
that gate this kind of build (5.4: the chain checks only with DARIA; the Fix B
checks with Fix B; on aeee6d2, kind base, (g) is the negative control and must
FAIL). Every gating check must be present: one that never ran (quartus_sta
stopped, a report file missing) fails as "not reported". Exit status 0 when
every gating check passes. The line after it, "rules as first written: ...",
gives the verdict with (a), (l) and (h) by the rules as first written ((l)
and (h) as step7_report.tcl judged them, (a) by the SDC's bounds); (b), (k),
(e) and (c.cells), judged again as above, stand in both lines.
A change to a check made in step7_report.tcl reaches an old fit only through
the files it wrote; this script re-judges (a), (b), (k), (l), (h) and
(c.cells) from them, and any other such check needs the fit's kept database
(REPORT_ONLY=1 in run_step7.sh) or a refit.
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


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def fmt(x):
    return "?" if x is None else f"{x:.3f}"


def same(x, y):       # figures printed to 1 ps
    return x is not None and y is not None and abs(x - y) < 0.0005


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
    # No table: what the fitter duplicated or retimed is not known, so (c) and
    # (h.retime) fail (an absent figure is no pass, 5.4). Every DARIA and Fix B
    # fit so far has had the table (c76: 4,902 to 5,037 optimized nodes); a
    # report without it was cut short or is in another format.
    notab = "the fit report has no Fitter Netlist Optimizations table: what the fitter duplicated or retimed is not known"
    if not daria:
        check("c", "FAIL", "no DARIA in this build: the first flops of plan 2.7 are not there (no such cell)")
    elif i < 0:
        check("c", "FAIL", notab)
    else:
        check("c", "FAIL" if bad else "PASS",
              f"{len(rows)} optimized nodes; pd_tog, pd_rx and the {len([t for t in firsts_here if t['cls'] != 'guard'])} "
              "first flops of this build: "
              + (f"{len(bad)} duplicated or retimed: " + "; ".join(bad) if bad else "none duplicated or retimed"))
    if prep.get("fixb") != "1":
        check("h.retime", "FAIL", "no Fix B in this build: no sram|t_*_q (no such cell)")
    elif i < 0:
        check("h.retime", "FAIL", notab + " (sram|t_*_q)")
    else:
        check("h.retime", "FAIL" if tbad else "PASS",
              "sram|t_*_q " + ("retimed: " + "; ".join(tbad) if tbad else "not retimed by the fitter"))

# ---- the guard pair's bounds (plan 5.4 as amended for G1, 2026-10-19: docs/daria_step10/plan.md section 10) --
# What (a), (b), (k) and (e) hold pd_tog -> pd_rx to is the SDC's, as the Timing Analyzer read it for this fit:
# sdc.rpt's one set_max_delay and one set_min_delay from pd_tog to pd_rx. The pair must be a row of the tree's
# table of known pairs (step7_report.tcl's guard_pairs): design.md 8.2's [1.000, 6.000] ns as first written, or
# G1's [0.500, 8.000] ns. A pair not in the table, a line missing or given twice, or no sdc.rpt: (a), (b), (k) and
# (e) fail. The bounds are absolute; they do not follow the divider. The report script writes the bounds it judged
# (a), (b) and (k) with to checks.txt ("# guard bounds: ..."); a report written before that line existed held the
# pair to 6.000 / 1.000 ns whatever the SDC said, which is how this script reads such a report's own verdicts.


def guard_pairs():
    """the tree's table of known pairs: [(setup, hold, fitter, name)]"""
    m = re.search(r"(?ms)^set guard_pairs \{\n(.*?)^\}", rd(os.path.join(here, "step7_report.tcl")) or "")
    out = []
    for line in (m.group(1) if m else "").splitlines():
        r = re.match(r"\s*\{(\S+) (\S+) (\S+) (\w+)\}\s*$", line)
        if r and None not in (num(r.group(1)), num(r.group(2)), num(r.group(3))):
            out.append((num(r.group(1)), num(r.group(2)), num(r.group(3)), r.group(4)))
    return out


PAIRS = guard_pairs()
PAIRS_TXT = ", ".join(f"{n} [{h:.3f}, {s:.3f}]" for s, h, _, n in PAIRS)


def read_guard():
    """((setup, hold, fitter, name) or None, text): the fit's bounds from sdc.rpt, by the tree's table"""
    if not PAIRS:
        return None, "no guard_pairs table in " + os.path.join(here, "step7_report.tcl")
    txt = rd(os.path.join(fpga, "sdc.rpt"))
    if txt is None:
        return None, "sdc.rpt missing: the SDC the fit was made with is not known"
    mx, mn = [], []
    for line in txt.splitlines():
        cols = [c.strip() for c in line.strip().strip(";").split(";")]
        if cols[0] not in ("set_max_delay", "set_min_delay") or "-to" not in cols[1:]:
            continue
        ti = cols.index("-to")
        if ti < 1 or ti + 2 >= len(cols) or "u_guard|pd_tog" not in " ".join(cols[1:ti]) or "u_guard|pd_rx" not in cols[ti + 1]:
            continue
        (mx if cols[0] == "set_max_delay" else mn).append((cols[ti + 2], cols[ti + 3] if ti + 3 < len(cols) else "?"))
    seen = (f"set_max_delay {', '.join(f'{v} at {at}' for v, at in mx) or 'none'}; "
            f"set_min_delay {', '.join(f'{v} at {at}' for v, at in mn) or 'none'}")
    if len(mx) != 1 or len(mn) != 1:
        return None, (f"sdc.rpt has {len(mx)} set_max_delay and {len(mn)} set_min_delay from pd_tog to pd_rx, "
                      f"not one of each ({seen})")
    for ps, ph, pf, pn in PAIRS:
        if same(num(mx[0][0]), ps) and same(num(mn[0][0]), ph):
            return (ps, ph, pf, pn), f"sdc.rpt: {seen}"
    return None, (f"the SDC's pair (setup {mx[0][0]}, hold {mn[0][0]} ns) is not one of the known pairs "
                  f"({PAIRS_TXT}); sdc.rpt: {seen}")


GUARD, GUARD_WHY = read_guard()
GUARD_TXT = (f"{GUARD[0]:.3f} / {GUARD[1]:.3f} ns ({GUARD[3]}, the SDC's)" if GUARD
             else f"not known: {GUARD_WHY}")
# The bounds the report script used: its "# guard bounds:" line, or 6.000 / 1.000 ns before the line existed.
TCL_LINE = False
TCL_GUARD = (6.0, 1.0, None, "fixed")
TCL_WHY = "6.000 / 1.000 ns, fixed in the report script (a report made before it read the SDC's bounds)"
for line in (ct or "").splitlines():
    m = re.match(r"# guard bounds: setup (\S+) hold (\S+) \((\w+);", line)
    if m:
        TCL_LINE, TCL_GUARD = True, (num(m.group(1)), num(m.group(2)), None, m.group(3))
        TCL_WHY = f"{m.group(1)} / {m.group(2)} ns ({m.group(3)}, the SDC's)"
    elif line.startswith("# guard bounds: none"):
        TCL_LINE, TCL_GUARD, TCL_WHY = True, None, "not known to the report script" + line[len("# guard bounds: none"):]
# A report script that read known bounds must have read sdc.rpt's (the same file): otherwise its verdicts and this
# script's are about different constraints. One that read none, where the tree's table now knows the pair (a row
# added since the fit), is judged again by the tree's table, as (c.cells) is; its own verdicts were FAIL.
TCL_DIFFERS = bool(TCL_LINE and TCL_GUARD and GUARD) and not (same(TCL_GUARD[0], GUARD[0]) and same(TCL_GUARD[1], GUARD[1]))


def fitter_line():
    """information: the fitter-only set_max_delay on the pair in the run directory's copy of the SDC"""
    for p in (os.path.join(fpga, "core", "daria_constraints.sdc"), os.path.join(fpga, "daria_constraints.sdc")):
        t = rd(p)
        if t is not None:
            break
    else:
        return "fitter-only line not seen (no copy of daria_constraints.sdc in the run directory)"
    t = "\n".join(l for l in re.sub(r"\\\n", " ", t).splitlines() if not l.strip().startswith("#"))
    m = re.search(r'nameofexecutable\)\s*eq\s*"quartus_fit"\s*\}\s*\{(.*?)\n\}', t, re.S)
    v = re.findall(r"set_max_delay\s+-from\s+\[get_registers[^\]]*u_guard\|pd_tog\}\]\s+-to\s+\[get_registers[^\]]*"
                   r"u_guard\|pd_rx\}\]\s+(\S+)", m.group(1)) if m else []
    if not v:
        return "fitter-only line: none on the pair in the copy of daria_constraints.sdc"
    own = "" if GUARD is None else (" (the pair's own)" if len(v) == 1 and same(num(v[0]), GUARD[2])
                                    else f" (NOT {GUARD[2]:.3f}, the pair's own; information only)")
    return f"fitter-only line: {', '.join(v)} ns{own}"


# ---- (e): the SDC file and its exceptions -------------------------------------------------------------
log = (rd(os.path.join(d, "quartus.log")) or "") + (rd(os.path.join(d, "report.log")) or "")
warn = [l.strip() for l in log.splitlines() if "daria_constraints.sdc" in l and re.search(r"Warning|Error", l)]
exc = rd(os.path.join(fpga, "exceptions.rpt")) or ""
summ = exc[:exc.find("\n\n")] if exc else ""
want = [("set_max_delay", "counter[0]", "counter[3]", "20.000"), ("set_max_delay", "counter[3]", "counter[0]", "20.000"),
        ("set_min_delay", "counter[0]", "counter[3]", "-20.000"), ("set_min_delay", "counter[3]", "counter[0]", "-20.000")]
if GUARD:
    want += [("set_max_delay", "pd_tog", "pd_rx", f"{GUARD[0]:.3f}"), ("set_min_delay", "pd_tog", "pd_rx", f"{GUARD[1]:.3f}")]
estat = [] if GUARD else [f"the guard pair's bounds {GUARD_TXT}"]
eok = GUARD is not None
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
          + (f"the guard pair's bounds {GUARD_TXT}; " if GUARD else "")
          + "; ".join(estat) + " (clk_arm -> clk_sys lines may be Partially Overridden by the pair; (k) shows where); "
          + fitter_line())

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
            own = sorted(f for f, x in srcs if not x)
            allow = 1 if t["cls"] == "reset" else 0
            if len(cross) != 1 or len(own) > allow:
                bad_first.append(f"{to}: fan-in {len(cross)} register(s) of the other clock {cross[:4]}, "
                                 f"{len(own)} of its own (at most {allow}) {own[:4]}")
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

# ---- (a), (l), (h) by the divider (plan 5.4 as amended 2026-10-14); (a), (b), (k) by the SDC's bounds ----------
# step7_report.tcl judges (a), (l) and (h) by the rules as first written. The lead's decision on Q2 at VCO/19
# (2026-10-14) amends them for a build at VCO/19, the shipped divider (step7_prep.txt's div 19): the guard
# cannot lock at VCO/19 whatever the pair's delay, so its window guards no function there, and (h)'s
# threshold drops to +3.0 ns. Any other divider keeps the rules as first written. The figures come from the
# report script's files: (a)'s per-corner lines and the corner list in checks.txt, timing.txt (every clock's
# worst setup and hold per corner, what (l) reads) and (h)'s lines; for (l), the compile's Timing Analyzer
# summary and fanin.tsv as well.
# (a), (b) and (k) are judged again by the guard pair's bounds from sdc.rpt (above): (a) and (b) from the per-corner
# setup and hold lines of pd_tog -> pd_rx in checks.txt, (k) from crossings.tsv (every clk_sys <-> clk_arm pair,
# its setup and hold relationship). This script's reading of those figures by the bounds the report script used
# (its "# guard bounds:" line, or 6.000 / 1.000 ns before that line existed) must give the report script's
# verdict, or the check fails as a misread. Bounds are not a rule of 5.4 but what it measures against, so the
# re-judged (a), (b) and (k) stand in both verdict lines, as (c.cells) does.
div = prep.get("div", "?")
AT19 = div == "19"
H_MIN = 3.0 if AT19 else 4.5
SYS = "ic|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk"
first = {}            # check id -> its verdict by the rules as first written ((a): by the SDC's bounds)


fig = {"corners": None, "a": {}, "b": {}, "h": None, "hin": None}
in_ab = False
for line in (ct or "").splitlines():
    m = re.match(r"# corners: (.+)$", line)
    if m:
        fig["corners"] = m.group(1).split()
    if line.startswith("## "):
        in_ab = line.startswith("## (a) (b) (d)")
        continue
    m = re.match(r"  (\S+) (setup|hold): (\d+) path\(s\);(.*)$", line)
    if in_ab and m:
        fig["a" if m.group(2) == "setup" else "b"][m.group(1)] = (
            int(m.group(3)), [(num(r), num(s)) for r, s in re.findall(r" rel (\S+) slack (\S+) skew \S+ data \S+;", m.group(4))])
    m = re.match(r"  t_\*_q -> clk_sdram: worst setup (\S+) ns .*worst hold over corners (\S+) ns", line)
    if m:
        fig["h"] = (num(m.group(1)), num(m.group(2)))
    m = re.match(r"  into t_\*_q: worst setup (\S+) ns", line)
    if m:
        fig["hin"] = num(m.group(1))

tt = rd(os.path.join(fpga, "timing.txt"))
tim = {}              # (corner, clock) -> (setup, hold), as printed
cond = None
for line in (tt or "").splitlines():
    m = re.match(r"== (\S+)$", line)
    if m:
        cond = m.group(1)
        continue
    m = re.match(r"  (\S+)\s+setup\s+(\S+)\s+hold\s+(\S+)\s*$", line)
    if m and cond:
        tim[(cond, m.group(1))] = (m.group(2), m.group(3))

sta = None            # (corner, clock) -> (Slack, End Point TNS) from the compile's Setup Summary tables
srpt = rd(os.path.join(out, "ap_core.sta.rpt"))
if srpt is not None:
    sta = {}
    for m in re.finditer(r"; (Slow|Fast) (\d+)mV (-?\d+)C Model Setup Summary\s*;\n(.*?)\n\n", srpt, re.S):
        key = f"{m.group(1).lower()}_{m.group(2)}mv_{m.group(3)}c"
        for row in m.group(4).splitlines():
            cols = [c.strip() for c in row.strip().strip(";").split(";")]
            if len(cols) == 3 and cols[0] != "Clock":
                sta[(key, cols[0])] = (num(cols[1]), num(cols[2]))


def sta_key(c):       # 8_slow_1100mv_85c -> slow_1100mv_85c (the summary table's "Slow 1100mV 85C")
    return re.sub(r"^[^_]*_", "", c).lower()


rx_src = set()        # pd_rx's timed fan-in, by register (fanin.tsv)
for row in (fan or "").splitlines()[1:]:
    cols = row.split("\t")
    if len(cols) >= 7 and re.search(r"\|daria_fe_guard:u_guard\|pd_rx$", strip_suffix(cols[1])):
        rx_src.add(strip_suffix(cols[3]))
rx_only_tog = bool(rx_src) and all(re.search(r"\|daria_fe_guard:u_guard\|pd_tog$", s) for s in rx_src)


def pair_figs(key):
    """(single, figures by corner, text, error) for the guard pair's setup ("a") or hold ("b") lines"""
    which = "setup" if key == "a" else "hold"
    cs = fig["corners"]
    if not cs:
        return None, None, None, "the corner list ('# corners:') is not in checks.txt"
    miss = [c for c in cs if c not in fig[key]]
    if miss:
        return None, None, None, f"no {which} figures for pd_tog -> pd_rx at {miss} in checks.txt"
    single = all(fig[key][c][0] == 1 and len(fig[key][c][1]) == 1 for c in cs)
    sl = "; ".join(f"{c} {fig[key][c][0]} path(s)" + "".join(f" rel {fmt(r)} slack {fmt(s)}" for r, s in fig[key][c][1])
                   for c in cs)
    return single, [fig[key][c][1] for c in cs], sl, None


def judge_a(g, why):
    """(first, amended, text) by the bounds g (None: not known, why); first is None when the figures are missing."""
    single, paths, sl, err = pair_figs("a")
    if err:
        return None, "FAIL", err
    if g is None:
        return "FAIL", "FAIL", f"VCO/{div}: the guard pair's bounds are {why}: {sl}"
    rel = all(p and all(same(r, g[0]) for r, _ in p) for p in paths)
    met = all(s is not None and s >= 0 for p in paths for _, s in p)
    f = "PASS" if single and rel and met else "FAIL"
    if not AT19:
        return f, f, f"VCO/{div}: exactly one setup path pd_tog -> pd_rx at every corner, relationship {g[0]:.3f} ns, met: {sl}"
    a = "PASS" if single and rel else "FAIL"
    return f, a, (f"VCO/19 (plan 5.4 (a) as amended 2026-10-14): exactly one setup path pd_tog -> pd_rx at every corner "
                  f"({'yes' if single else 'NO'}), relationship {g[0]:.3f} ns, the constraint applied ({'yes' if rel else 'NO'}); "
                  f"its slack reported, not gated: {sl}")


def judge_b(g, why):
    """(verdict, verdict, text) by the bounds g; the verdict is None when the figures are missing. No amendment."""
    single, paths, sl, err = pair_figs("b")
    if err:
        return None, "FAIL", err
    if g is None:
        return "FAIL", "FAIL", f"the guard pair's bounds are {why}: {sl}"
    rel = all(p and all(same(r, g[1]) for r, _ in p) for p in paths)
    met = all(s is not None and s >= 0 for p in paths for _, s in p)
    v = "PASS" if single and rel and met else "FAIL"
    return v, v, f"exactly one hold path pd_tog -> pd_rx at every corner, relationship {g[1]:.3f} ns, met: {sl}"


def judge_k(g, why):
    """(verdict, verdict, text) from crossings.tsv by the bounds g, as step7_report.tcl's (k) judges"""
    if tsv is None:
        return None, "FAIL", "crossings.tsv missing"
    rows = [l.split("\t") for l in tsv.splitlines()[1:] if l.strip()]
    if any(len(r) != 8 for r in rows):
        return None, "FAIL", "crossings.tsv: a row not in its format"
    if not rows:
        return "FAIL", "FAIL", "no clk_sys <-> clk_arm path at all (crossings.tsv)"
    if g is None:
        return "FAIL", "FAIL", f"the guard pair's bounds are {why} ({len(rows)} pairs; crossings.tsv)"
    bad, ng = [], 0
    for dirn, rel, _sl, hrel, _hsl, _lv, fr, to in rows:
        guard = bool(re.match(r".*\|daria_fe_guard:u_guard\|pd_tog$", re.sub(r"~DUPLICATE\S*$", "", fr))
                     and re.match(r".*\|daria_fe_guard:u_guard\|pd_rx$", re.sub(r"~DUPLICATE\S*$", "", to)))
        ng += guard
        wr, wrh = (g[0], g[1]) if guard else (20.0, -20.0)
        if not same(num(rel), wr) or hrel == "-" or not same(num(hrel), wrh):
            bad.append(f"{dirn}: {fr} -> {to} setup rel {rel}, hold rel {hrel} (expected {wr:.3f} / {wrh:.3f})")
    v = "FAIL" if bad else "PASS"
    return v, v, (f"every clk_sys <-> clk_arm path pair at the 20 / -20 ns relationship, pd_tog -> pd_rx at {g[0]:.3f} / "
                  f"{g[1]:.3f} ns ({len(rows)} pairs, {ng} of them the guard pair; crossings.tsv)"
                  + (f"; {len(bad)} not: {'; '.join(bad[:4])}" if bad else ""))


def judge_l():
    if tt is None or not tim:
        return None, "FAIL", "timing.txt missing or empty"
    neg = []
    for (c, lab), (ss, hs) in sorted(tim.items()):
        for k, v in (("setup", ss), ("hold", hs)):
            if v != "-" and (num(v) is None or num(v) < 0):
                neg.append((c, lab, k, v))
    f = "FAIL" if neg else "PASS"
    shown = "; ".join(f"{lab} {k} {v} at {c}" for c, lab, k, v in neg)
    if not AT19:
        return f, f, f"VCO/{div}: setup and hold slack >= 0 for every clock at every corner" + (f"; failing: {shown}" if neg else "")
    left, out_ = [], []
    for c, lab, k, v in neg:
        why = None
        if lab != "clk_sys" or k != "setup":
            why = "not the guard pair's setup"
        else:
            ga = fig["a"].get(c)
            sa = sta.get((sta_key(c), SYS)) if sta is not None else None
            if not ga or ga[0] != 1 or len(ga[1]) != 1:
                why = "no single pd_tog -> pd_rx setup path at this corner in (a)'s figures"
            elif not same(ga[1][0][1], num(v)):
                why = f"not the guard pair's (its slack here is {fmt(ga[1][0][1])}): another clk_sys path is worse"
            elif sta is None:
                why = "no ap_core.sta.rpt: the other clk_sys endpoints are not known"
            elif sa is None:
                why = "clk_sys is not in the compile's Setup Summary for this corner"
            elif not same(sa[0], num(v)):
                why = f"the compile's Setup Summary has clk_sys at {fmt(sa[0])}, not {v} (another analysis)"
            elif not same(sa[1], num(v)):
                why = f"End Point TNS {fmt(sa[1])}: another clk_sys endpoint fails too"
            elif not rx_only_tog:
                why = f"pd_rx's timed fan-in is not pd_tog alone (fanin.tsv: {sorted(rx_src)[:4] or 'none'})"
            else:
                out_.append(f"clk_sys setup {v} at {c} is pd_tog -> pd_rx's (Setup Summary: slack {sa[0]:.3f}, End Point "
                            f"TNS {sa[1]:.3f}, so no other clk_sys endpoint fails; pd_rx's only fan-in pd_tog)")
        if why:
            left.append(f"{lab} {k} {v} at {c} ({why})")
    a = "FAIL" if left else "PASS"
    return f, a, ("VCO/19 (plan 5.4 (l) as amended 2026-10-14): setup and hold slack >= 0 for every clock at every corner, "
                  "the guard pair's setup left out" + (f"; left out: {'; '.join(out_)}" if out_ else " (nothing to leave out)")
                  + (f"; failing: {'; '.join(left)}" if left else ""))


def judge_h():
    if fig["h"] is None or fig["hin"] is None:
        return None, "FAIL", "the t_*_q figures are not in checks.txt"
    (ws, wh), wi = fig["h"], fig["hin"]
    rest = wh is not None and wh >= 0 and wi is not None and wi >= 40.0
    f = "PASS" if ws is not None and ws >= 4.5 and rest else "FAIL"
    a = "PASS" if ws is not None and ws >= H_MIN and rest else "FAIL"
    return f, a, (f"VCO/{div}" + (" (plan 5.4 (h) as amended 2026-10-14)" if AT19 else "")
                  + f": t_*_q -> clk_sdram setup {fmt(ws)} (>= +{H_MIN:.1f}), hold {fmt(wh)} (>= 0); into t_*_q {fmt(wi)} (>= +40)")


GUARDED = ("a", "b", "k")      # judged by the guard pair's bounds
for cid, judge in (("a", judge_a), ("b", judge_b), ("k", judge_k), ("l", judge_l), ("h", judge_h)):
    idx = [i for i, r in enumerate(results) if r[0] == cid]
    if len(idx) != 1:
        continue          # never ran: "not reported" below, if it gates
    i = idx[0]
    _, tv, ttext = results[i]
    if tv not in ("PASS", "FAIL") or "Tcl error" in ttext or "no such cell" in ttext:
        continue          # the report script's failure stands
    if cid not in GUARDED:
        first[cid] = tv
        fv, av, text = judge()
        if fv is None:
            results[i] = (cid, "FAIL", f"{text}; the report script said {tv}")
        elif fv != tv:
            results[i] = (cid, "FAIL", f"misread: this script reads the report script's figures as {fv} by the rules as "
                                       f"first written, the report script said {tv}; {text}")
        else:
            results[i] = (cid, av, f"{text}; as first written (the report script): {tv}")
        continue
    # (a), (b), (k): first by the bounds the report script used (the misread check), then by the SDC's.
    tf, _, ttxt = judge(TCL_GUARD, TCL_WHY)
    fv, av, text = judge(GUARD, GUARD_TXT)
    first[cid] = "FAIL"
    if tf is None or fv is None:
        results[i] = (cid, "FAIL", f"{ttxt if tf is None else text}; the report script said {tv}")
    elif tf != tv:
        results[i] = (cid, "FAIL", f"misread: this script reads the report script's figures as {tf} by the bounds it used "
                                   f"({TCL_WHY}), the report script said {tv}; {ttxt}")
    elif TCL_DIFFERS:
        results[i] = (cid, "FAIL", f"the report script judged with {TCL_WHY}, but sdc.rpt gives {GUARD_TXT}; {text}")
    else:
        first[cid] = fv
        results[i] = (cid, av, text + (f"; by the SDC's bounds {GUARD_TXT}" if GUARD else "")
                      + (f"; as first written: {fv}" if cid == "a" else "")
                      + f"; the report script, with {TCL_WHY}: {tv}")

# ---- (c.cells) judged again by the tree's table (plan 2.7) ---------------------------------------------------------
# step7_report.tcl counts the registers of each first flop of its ff_table and writes the counts to firstflops.tsv
# (pattern, present by the table it ran with, found without duplicates, found with suffixes), then judges them by
# that table. A later correction of the table (2.7: cap_err_a[0] absent from Q5 too, the D fix round) changes no
# count, so (c.cells) is judged again here from the counts by the tree's ff_table (the step7_report.tcl beside this
# script), with no refit: a row present must be found once, a row absent not at all, as step7_report.tcl judges.
# This script's reading of the counts by the fit's own table (the file's second column) must give the report
# script's verdict, or the check fails as a misread; a row of either table missing from the other fails. The
# correction is of the table, not of a rule, so "rules as first written" takes this verdict too; the report
# script's own verdict is in the check's text.


def ff_table():
    """the tree's plan 2.7 table: pattern -> (present in Build B, present in Q5)"""
    m = re.search(r"(?ms)^set ff_table \{\n(.*?)^\}", rd(os.path.join(here, "step7_report.tcl")) or "")
    tab = {}
    for line in (m.group(1) if m else "").splitlines():
        r = re.match(r"\s*\{([^}]+)\}\s+([01])\s+([01])\s*$", line)
        if r:
            tab[r.group(1)] = (int(r.group(2)), int(r.group(3)))
    return tab


def judge_cells():
    """(by the fit's own table, by the tree's, text); the first is None when the counts are not there"""
    tab = ff_table()
    if not tab:
        return None, "FAIL", "no ff_table in " + os.path.join(here, "step7_report.tcl")
    tsv = rd(os.path.join(fpga, "firstflops.tsv"))
    if tsv is None:
        return None, "FAIL", "firstflops.tsv missing: the report script's counts are not known"
    rows = []
    for line in tsv.splitlines():
        if not line.strip():
            continue
        c = line.split("\t")
        if len(c) != 4 or c[1] not in ("0", "1") or not c[2].isdigit() or not c[3].isdigit():
            return None, "FAIL", f"firstflops.tsv: a row not in its format: {line[:120]}"
        rows.append((c[0], int(c[1]), int(c[2]), int(c[3])))
    if not rows:
        return None, "FAIL", "firstflops.tsv holds no row"
    col = 1 if kind == "q5" else 0      # as step7_report.tcl: Q5's column for kind q5, Build B's for any other

    def wrong(want, n):
        return "MISSING" if want and n != 1 else ("PRESENT" if not want and n != 0 else None)
    f = "FAIL" if any(wrong(w, n) for _, w, n, _ in rows) else "PASS"
    counted = [p for p, _, _, _ in rows]
    extra = [p for p in counted if p not in tab]
    uncounted = [p for p in tab if p not in counted]
    bad, changed = [], []
    for p, w, n, _ in rows:
        if p not in tab:
            continue
        want = tab[p][col]
        if want != w:
            changed.append(f"{p.split('|')[-1]} {'present' if w else 'absent'} -> {'present' if want else 'absent'}")
        st = wrong(want, n)
        if st:
            bad.append(f"{p} {st} (expected {'present' if want else 'absent'}, found {n})")
    a = "FAIL" if bad or extra or uncounted else "PASS"
    return f, a, (f"each first flop of plan 2.7 present or absent as the tree's table (step7_report.tcl's ff_table) "
                  f"says for kind {kind}, from the report script's counts (firstflops.tsv, {len(rows)} rows): "
                  + ("; ".join(bad) if bad else "every row as the table says")
                  + (f"; counted but not in the tree's table: {extra}" if extra else "")
                  + (f"; in the tree's table but not counted: {uncounted}" if uncounted else "")
                  + f"; rows the tree's table changed since the fit: {changed or 'none'}")


idx = [i for i, r in enumerate(results) if r[0] == "c.cells"]
if len(idx) == 1 and results[idx[0]][1] in ("PASS", "FAIL") and "Tcl error" not in results[idx[0]][2]:
    i = idx[0]
    tv = results[i][1]
    fv, av, text = judge_cells()
    if fv is None:
        results[i] = ("c.cells", "FAIL", f"{text}; the report script said {tv}")
    elif fv != tv:
        results[i] = ("c.cells", "FAIL", f"misread: this script reads the report script's counts by the fit's own table "
                                         f"as {fv}, the report script said {tv}; {text}")
    else:
        results[i] = ("c.cells", av, f"{text}; the report script, by the table it ran with: {tv}")

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
fails_first = []      # the same with (a), (l) and (h) by the rules as first written (the report script's verdicts)
for cid, verdict, text in results:
    role = "gating" if cid in gating else "info"
    if kind == "base" and cid == "g":
        role = "negative control (must FAIL on aeee6d2)"
        if verdict == "PASS" or text.startswith("not reported") or "no such cell" in text or "Tcl error" in text:
            fails.append(cid)
            fails_first.append(cid)
    elif role == "gating":
        if verdict == "FAIL":
            fails.append(cid)
        if first.get(cid, verdict) == "FAIL":
            fails_first.append(cid)
    print(f"  ({cid}) {verdict} [{role}] {text}")
line = "verdict: " + ("PASS" if not fails else "FAIL: " + " ".join(fails))
line_first = "rules as first written: " + ("PASS" if not fails_first else "FAIL: " + " ".join(fails_first))
print(line)
print(line_first)
with open(os.path.join(d, "checks_summary.txt"), "w") as f:
    f.write("\n".join(f"({c}) {v} {t}" for c, v, t in results) + "\n")
    f.write(line + "\n" + line_first + "\n")
    f.write("\n# step7_report.tcl's detail\n" + "\n".join(detail) + "\n")
sys.exit(1 if fails else 0)
