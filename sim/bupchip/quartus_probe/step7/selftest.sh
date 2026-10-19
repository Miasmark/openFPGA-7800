#!/bin/bash
# Self-test of the step-7 fit driver's parts that need no Quartus
# (docs/daria_step7/plan.md 3.5 "Fit scripts", 5.4): step7_prep.py's DARIA
# lines, step7_checks.py's verdict and its (k') rule on made-up report files,
# among them the guard pair's bounds read from sdc.rpt (plan 5.4 as amended
# for G1, 2026-10-19, in docs/daria_step10/plan.md section 10: G1 fits, older reports, unknown or missing pairs,
# misreads), the two copies of plan 2.7's table (step7_report.tcl's ff_table
# and f3_crossings.txt) against each other,
# and run_step7.sh's refusals, with a stand-in docker and a lock file of its
# own (never the machine's Quartus lock). Every directory it makes is under
# one mktemp -d, removed at the end; nothing in the tree is written.
#   sim/bupchip/quartus_probe/step7/selftest.sh
# run_step7.sh's own check of the free space (2,048 MB on /) reads a
# stand-in df here, which reports 2,048 MB (passes) or 2,047 MB (refused, a
# test of its own), so the machine's free space does not decide the result.
# What the tests really write is about 15 MB (three copies of src/fpga, of
# 3.3 MB, and the made-up report files): with less than 100 MB free the
# driver tests that copy src/fpga are skipped, named, and the run exits 3
# (PARTIAL, not a pass). Exit 0 when every test passes, 1 when one fails.
# The quartus side (step7_report.tcl, daria.qip) is smoke/run_smoke.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
T="$(mktemp -d)"
SLEEPER=""
cleanup() { [ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null; rm -rf -- "$T"; }
trap cleanup EXIT
npass=0
nfail=0
nskip=0
ok() { echo "PASS $*"; npass=$((npass + 1)); }
bad() { echo "FAIL $*"; nfail=$((nfail + 1)); }
skip() { echo "SKIPPED $*"; nskip=$((nskip + 1)); }

echo "== selftest.sh $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "HEAD $(git -C "$ROOT" rev-parse HEAD); status $(git -C "$ROOT" status --porcelain | wc -l) lines"
git -C "$ROOT" status --porcelain | sed 's/^/  /'
echo "bash $BASH_VERSION; $(python3 --version 2>&1); flock $(flock --version 2>&1 | head -1)"
echo "md5: $(cd "$HERE" && md5sum selftest.sh run_step7.sh step7_lock.sh step7_prep.py step7_checks.py f3_crossings.txt step7_report.tcl | awk '{printf "%s %s; ", $2, substr($1,1,12)}')"

# ---- 1. step7_prep.py ------------------------------------------------------------------------------------
echo "-- 1. step7_prep.py: the three DARIA lines"
fresh() {	# a copy of the tree's src/fpga at $T/p/fpga, without the user's firmware
	rm -rf -- "$T/p"
	mkdir -p "$T/p"
	tar -C "$ROOT/src" --exclude=fpga/output_files --exclude=fpga/db --exclude=fpga/incremental_db \
		--exclude='bupchip.*' -cf - fpga | tar -C "$T/p" -xf -
}
prep() { python3 "$HERE/step7_prep.py" "$T/p/fpga" "$@" > "$T/prep.out" 2>&1; }
kind() { sed -n 's/^kind //p' "$T/p/fpga/step7_prep.txt" 2>/dev/null; }
daria_lines() { grep -v '^\s*#' "$T/p/fpga/ap_core.qsf" | grep -c 'POCKET_DARIA\|daria\.qip\|daria_constraints\.sdc'; }
macro='set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"'

fresh
if grep -qxF "$macro" "$T/p/fpga/ap_core.qsf"; then
	prep && [ "$(kind)" = daria ] && ok "the tree as it is: kind daria" || bad "the tree as it is: $(kind) $(tail -2 "$T/prep.out")"
	fresh
	prep --nodaria && [ "$(daria_lines)" = 0 ] && [ "$(kind)" != daria ] \
		&& ok "NODARIA: the three lines deleted, kind $(kind)" || bad "NODARIA on the tree: $(tail -2 "$T/prep.out")"
	fresh
	sed -i "s/^$(printf '%s' "$macro" | sed 's/[]\/$*.^[]/\\&/g')\$/& /" "$T/p/fpga/ap_core.qsf"
	grep -qF "$macro " "$T/p/fpga/ap_core.qsf" || bad "could not plant a trailing space"
	if prep --nodaria; then bad "NODARIA with a trailing space on the macro line was not refused (kind $(kind))"
	else grep -q "not one of the three DARIA lines exactly" "$T/prep.out" && ok "NODARIA refuses a macro line with a trailing space" \
		|| bad "NODARIA refused for another reason: $(tail -1 "$T/prep.out")"; fi
	if prep; then bad "a macro line with a trailing space was not refused without NODARIA"; else ok "the same is refused without NODARIA"; fi
	fresh
	sed -i "\\|^$(printf '%s' "$macro" | sed 's/[]\/$*.^[]/\\&/g')\$|d" "$T/p/fpga/ap_core.qsf"
	echo 'set_global_assignment -name VERILOG_MACRO POCKET_DARIA=1' >> "$T/p/fpga/ap_core.qsf"
	if prep --nodaria; then bad "an unquoted macro line elsewhere was not refused"; else ok "NODARIA refuses an unquoted POCKET_DARIA macro line"; fi
	fresh
	sed -i "\\|^$(printf '%s' "$macro" | sed 's/[]\/$*.^[]/\\&/g')\$|d" "$T/p/fpga/ap_core.qsf"
	if prep; then bad "two of the three lines were not refused"; else ok "two of the three DARIA lines are refused"; fi
else
	echo "   (this tree's ap_core.qsf has no DARIA lines: planting them)"
	fresh
fi
fresh
prep --nodaria >/dev/null 2>&1 || true
nod_kind=$(kind)
fresh
echo '`define POCKET_DARIA 1' >> "$T/p/fpga/core/core_top.v"
if prep --nodaria; then bad "a \`define POCKET_DARIA in a source file was not refused"; else ok "a \`define POCKET_DARIA in a source file is refused"; fi
fresh
echo 'set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"' >> "$T/p/fpga/core/core.qip"
if prep --nodaria; then bad "POCKET_DARIA in a qip was not refused"; else ok "POCKET_DARIA in a qip is refused"; fi
fresh
echo 'set_global_assignment -name VERILOG_MACRO "BUP_DEBUG=1"' >> "$T/p/fpga/ap_core.qsf"
if grep -qxF "$macro" "$T/p/fpga/ap_core.qsf"; then
	prep && [ "$(kind)" = q5 ] && ok "BUP_DEBUG with DARIA: kind q5" || bad "BUP_DEBUG: kind $(kind)"
	fresh
	echo 'set_global_assignment -name VERILOG_MACRO "BUP_DEBUG=1"' >> "$T/p/fpga/ap_core.qsf"
	prep --nodaria && [ "$(kind)" = "$nod_kind" ] && ok "BUP_DEBUG without DARIA: kind $(kind), as without BUP_DEBUG" \
		|| bad "BUP_DEBUG with NODARIA: kind $(kind)"
fi

echo "-- 1b. step7_prep.py: the clk_arm divider (pll_core.v's POCKET_DARIA view)"
pll="core/pll/pll_core.v"
fresh
tdiv="$(python3 "$HERE/step7_prep.py" "$T/p/fpga" --tree-div 2>&1)"
case "$tdiv" in 18|19|24) ok "--tree-div: the tree's divider is $tdiv" ;; *) bad "--tree-div: $tdiv" ;; esac
divline() { sed -n 's/^div //p' "$T/p/fpga/step7_prep.txt" 2>/dev/null; }
if [ "$tdiv" = 18 ] || [ "$tdiv" = 19 ]; then
	other=$((37 - tdiv))
	prep && cmp -s "$ROOT/src/fpga/$pll" "$T/p/fpga/$pll" && [ "$(divline)" = "$tdiv" ] \
		&& ok "no --div: pll_core.v as in the tree, div $tdiv" || bad "no --div: $(tail -1 "$T/prep.out"), div $(divline)"
	fresh
	prep --div "$tdiv" && cmp -s "$ROOT/src/fpga/$pll" "$T/p/fpga/$pll" \
		&& ok "--div $tdiv (the tree's): pll_core.v as in the tree" || bad "--div $tdiv: pll_core.v changed or refused"
	fresh
	if prep --div "$other" && [ "$(python3 "$HERE/step7_prep.py" "$T/p/fpga" --tree-div)" = "$other" ] && [ "$(divline)" = "$other" ]; then
		ok "--div $other: the copy's POCKET_DARIA view is ip-generate's C3 = $other, div $other"
		# and back: the round trip gives the tree's file byte for byte
		python3 "$HERE/step7_prep.py" "$T/p/fpga" --div "$tdiv" > "$T/prep2.out" 2>&1 && cmp -s "$ROOT/src/fpga/$pll" "$T/p/fpga/$pll" \
			&& ok "--div $tdiv on that copy restores the tree's pll_core.v exactly" || bad "the round trip $tdiv -> $other -> $tdiv differs"
	else
		bad "--div $other: $(tail -2 "$T/prep.out")"
	fi
	fresh
	if prep --nodaria --div "$other"; then bad "--nodaria --div $other was not refused"; else ok "--nodaria --div $other is refused"; fi
	fresh
	sed -i 's/\.c_cnt_lo_div3(9)/.c_cnt_lo_div3(8)/' "$T/p/fpga/$pll"
	if prep; then bad "a counter 3 that is no ip-generate output was not refused"; else ok "a counter 3 that is no ip-generate output is refused"; fi
fi

# ---- 2. step7_checks.py ------------------------------------------------------------------------------------
echo "-- 2. step7_checks.py: the verdict and (k') on made-up report files"
cat > "$T/fixture.py" <<'PY'
"""Writes a run directory whose report files say a Build B (kind daria) passed
everything, then applies the named changes. Names are made up from
f3_crossings.txt's patterns; no data from any build."""
import os, re, sys
f3, d, kind = sys.argv[1], sys.argv[2], sys.argv[3]
changes = sys.argv[4:]
fpga = os.path.join(d, "fpga")
out = os.path.join(fpga, "output_files")
os.makedirs(out, exist_ok=True)
SYS = "ic|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk"
ARM = "ic|pll|altera_pll_i|cyclonev_pll|counter[3].output_counter|divclk"
def name(p):
    p = p.replace("[*]", "[0]")
    if p.startswith("*|"):
        p = "core_top:ic|atari7800_pocket:atari|" + p[2:]
    return p.replace("*", "x")
rows = []
for line in open(f3):
    line = line.split("#", 1)[0].split()
    if line:
        rows.append(dict(dir=line[0], builds=line[1].split(","), cls=line[2], ep=line[3], src=line[4]))
here = [r for r in rows if kind in r["builds"]]
firsts = [r for r in here if r["cls"] in ("first", "reset", "guard")]
W = lambda p, s: open(p, "w").write(s)
# t:NAME=VALUE: the figures behind (a), (l) and (h) (plan 5.4 as amended 2026-10-14): t:div (18), t:gs (the
# guard pair's setup slack at the slow 85C corner), t:sys (the worst other clk_sys setup there), t:syshold
# (clk_sys hold there), t:gpaths (setup paths pd_tog -> pd_rx there), t:grel (its relationship), t:h (t_*_q ->
# clk_sdram setup), t:nosta (no Timing Analyzer summary), t:stas (its clk_sys Slack at the slow 85C corner, as
# if from another analysis), t:tcl_a/l/h/cells (the report script's verdict, forced), t:hhold (t_*_q ->
# clk_sdram's worst hold over the corners), t:anocorner=N (no setup line for pd_tog -> pd_rx at corner N)
# The guard pair's bounds (plan 5.4 as amended for G1, 2026-10-19; docs/daria_step10/plan.md section 10): t:gb=S,H (sdc.rpt's set_max_delay and
# set_min_delay on pd_tog -> pd_rx, also in exceptions.rpt; "none": no such line, as without DARIA), t:gb2=V
# (another set_max_delay on the pair, listed before it), t:nosdc (no sdc.rpt), t:tclb=S,H|old|none (the report
# script's "# guard bounds:" line; old: no such line, a report from before the bounds were read, which held the
# pair to 6 / 1; by default sdc.rpt's pair when it is a known one, else none), t:ghrel, t:ghs, t:ghpaths (the
# pair's hold relationship, its slack and its paths at the slow 85C corner), t:krel=S,H (the pair's row in
# crossings.tsv), t:kother=S,H (one other crossing row's relationship), t:khold=- (that row with no hold path),
# t:kdup (the pair again as ~DUPLICATE registers), t:fitsdc=V (a copy of daria_constraints.sdc whose
# quartus_fit block asks V of the pair), t:tcl_b, t:tcl_k (the report script's (b), (k), forced). The
# defaults: the pair's relationships follow sdc.rpt's bounds (20 / -20 ns without them).
tv = dict(div="18", gs="0.217", sys="1.000", syshold="0.291", gpaths="1", h="6.697", hhold="0.300")
for c in changes:
    m = re.match(r"t:(\w+)(?:=(.*))?$", c)
    if m:
        tv[m.group(1)] = m.group(2) if m.group(2) is not None else "1"
KNOWN = {("6.000", "1.000"): "first", ("8.000", "0.500"): "G1"}
daria_k = kind in ("daria", "q5")
gb = tv.get("gb", "6.000,1.000" if daria_k else "none")
GB = None if gb == "none" else tuple(f"{float(x):.3f}" for x in gb.split(","))
known = GB in KNOWN and "gb2" not in tv and "nosdc" not in tv
tclb = tv.get("tclb", ",".join(GB) if known else "none")
TB = None if tclb == "none" else ((6.0, 1.0) if tclb == "old" else tuple(float(x) for x in tclb.split(",")))
tv.setdefault("grel", GB[0] if GB else "20.000")
tv.setdefault("ghrel", GB[1] if GB else "-20.000")
KREL = tuple(tv["krel"].split(",")) if "krel" in tv else (GB if GB else ("20.000", "-20.000"))
W(os.path.join(fpga, "step7_prep.txt"), f"kind {kind}\ndaria {int(kind in ('daria', 'q5'))}\nbup_debug {int(kind == 'q5')}\n"
  f"fixb {int(kind != 'base')}\ndiv {tv['div']}\nseed 2\npin_id 0\noldpad 0\n")
CORNERS = [("8_slow_1100mv_85c", "Slow 1100mV 85C"), ("8_slow_1100mv_0c", "Slow 1100mV 0C"),
           ("MIN_fast_1100mv_85c", "Fast 1100mV 85C"), ("MIN_fast_1100mv_0c", "Fast 1100mV 0C")]
gs = {c: float(tv["gs"]) if n == 0 else 0.45 + n for n, (c, _) in enumerate(CORNERS)}
osys = {c: float(tv["sys"]) if n == 0 else 1.0 + n for n, (c, _) in enumerate(CORNERS)}
fig = [f"# corners: {' '.join(c for c, _ in CORNERS)}", "## (a) (b) (d) the guard pair pd_tog -> pd_rx (made up)"]
if tclb != "old":
    fig.insert(1, f"# guard bounds: setup {TB[0]:.3f} hold {TB[1]:.3f} "
               f"({KNOWN.get((f'{TB[0]:.3f}', f'{TB[1]:.3f}'), 'x')}; made up)" if TB else "# guard bounds: none (made up)")
ghs = float(tv.get("ghs", "2.000"))
for n, (c, _) in enumerate(CORNERS):
    k = int(tv["gpaths"]) if n == 0 else 1
    if str(n) != tv.get("anocorner"):
        fig.append(f"  {c} setup: {k} path(s);" + f" rel {float(tv['grel']):.3f} slack {gs[c]:.3f} skew -1.000 data 4.000;" * k)
    hk = int(tv.get("ghpaths", "1")) if n == 0 else 1
    fig.append(f"  {c} hold: {hk} path(s);"
               + f" rel {float(tv['ghrel']):.3f} slack {ghs if n == 0 else 2.0:.3f} skew 0.000 data 3.000;" * hk)
fig += ["## (h) Fix B checks 2-4: t_*_q (made up)",
        f"  t_*_q -> clk_sdram: worst setup {float(tv['h']):.3f} ns (6 levels, >= +4.5), worst hold over corners "
        f"{float(tv['hhold']):.3f} ns (>= 0)",
        "  into t_*_q: worst setup 54.000 ns (>= +40)", "## the checks (made up)"]
tim, summ = [], []
for n, (c, name_) in enumerate(CORNERS):
    sys_s = min(gs[c], osys[c])
    rows = [("clk_sys", sys_s, float(tv["syshold"]) if n == 0 else 0.291), ("clk_sdram", 2.936, 0.392),
            ("clk_sys_90", None, None), ("clk_arm", 1.765, 0.401), ("clk_74a", 3.183, 0.412)]
    tim.append(f"== {c}")
    for lab, st, ht in rows:
        tim.append(f"  {lab:<10} setup {'-' if st is None else f'{st:.3f}':>8}  hold {'-' if ht is None else f'{ht:.3f}':>8}")
    tns = sum(v for v in (gs[c], osys[c]) if v < 0)
    sta_s = float(tv["stas"]) if n == 0 and "stas" in tv else sys_s
    summ.append(f"+---+\n; {name_} Model Setup Summary ;\n+---+\n; Clock ; Slack ; End Point TNS ;\n+---+\n"
                f"; ic|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk ; {sta_s:.3f} ; {tns:.3f} ;\n"
                f"; ic|pll|altera_pll_i|cyclonev_pll|counter[3].output_counter|divclk ; 1.765 ; 0.000 ;\n+---+\n\n\n")
W(os.path.join(fpga, "timing.txt"), "\n".join(tim) + "\n")
if "nosta" not in tv:
    W(os.path.join(out, "ap_core.sta.rpt"), "".join(summ))
# The report script's verdicts by the rules as first written, unless forced.
first = dict(a=TB is not None and int(tv["gpaths"]) == 1 and abs(float(tv["grel"]) - TB[0]) < 0.0005 and min(gs.values()) >= 0,
             b=TB is not None and int(tv.get("ghpaths", "1")) == 1 and abs(float(tv["ghrel"]) - TB[1]) < 0.0005 and ghs >= 0,
             l=all(not (l.split()[2] != "-" and float(l.split()[2]) < 0) and not (l.split()[4] != "-" and float(l.split()[4]) < 0)
                   for l in tim if not l.startswith("==")),
             h=float(tv["h"]) >= 4.5 and float(tv["hhold"]) >= 0)
# firstflops.tsv: the report script's counts for step7_report.tcl's ff_table (beside f3_crossings.txt), each row
# as its column for this kind says (Q5's for q5, Build B's for any other); without DARIA none of them is there.
# ff:NAME=N sets a row's count, ffwant:NAME flips the row's own table column (a fit made with another table),
# ffdrop:NAME drops the row, noff writes no file; the report script's (c.cells) is its verdict on the file.
tcl = open(os.path.join(os.path.dirname(f3), "step7_report.tcl")).read()
ffm = re.search(r"(?ms)^set ff_table \{\n(.*?)^\}", tcl)
ff = []
for line in ffm.group(1).splitlines():
    r = re.match(r"\s*\{([^}]+)\}\s+([01])\s+([01])\s*$", line)
    if r:
        want = int(r.group(3) if kind == "q5" else r.group(2))
        n = want if kind in ("daria", "q5") else 0
        ff.append([r.group(1), want, n, n])
def ffrow(short):
    return [x for x in ff if x[0].endswith("|" + short)][0]
for c in changes:
    m = re.match(r"(ff|ffwant|ffdrop):([^=]+)(?:=(\d+))?$", c)
    if m:
        x = ffrow(m.group(2))
        if m.group(1) == "ff":
            x[2] = x[3] = int(m.group(3))
        elif m.group(1) == "ffwant":
            x[1] = 1 - x[1]
        else:
            ff.remove(x)
if "noff" not in changes:
    W(os.path.join(fpga, "firstflops.tsv"), "".join(f"{p}\t{w}\t{n}\t{a}\n" for p, w, n, a in ff))
first["cells"] = all((n == 1) if w else (n == 0) for _, w, n, _ in ff)
first = {k: tv.get("tcl_" + k, "PASS" if v else "FAIL") for k, v in first.items()}
first["c.cells"] = first.pop("cells")
ids = ["l.clocks", "l", "gate.clk_sdram", "gate.clk_arm", "gate.hold", "a", "b", "d", "c.cells", "e.files", "f.files",
       "g", "g.legs", "h", "i", "j", "k", "k'.files", "k'.fanin", "sdram.files", "p", "o.files"]
info = {"d", "e.files", "f.files", "i", "k'.files", "k'.fanin", "sdram.files", "p", "o.files"}
checks = [f"CHECK {i} {'INFO' if i in info else first.get(i, 'PASS')}: made up" for i in ids]
if kind == "base":
    checks = [c.replace("CHECK g PASS", "CHECK g FAIL") for c in checks]
if not daria_k:         # as step7_report.tcl reports a build without DARIA
    checks = [f"CHECK {c.split()[1]} FAIL: no such cell: pd_tog or pd_rx" if c.split()[1] in ("a", "b", "d") else c
              for c in checks]
for c in changes:
    if c.startswith("drop="):
        gone = c[5:].split(",")
        checks = [x for x in checks if x.split()[1] not in gone]
    if c == "ab_error":
        checks = [x for x in checks if x.split()[1] not in ("a", "b", "d")] + ["CHECK ab FAIL: Tcl error in the report script: made up"]
end = "noend" not in changes
W(os.path.join(fpga, "report_rc.txt"), "1\n" if "rc1" in changes else "0\n")
if "nofit" not in changes:
    # notable: a fit report without its Fitter Netlist Optimizations table
    W(os.path.join(out, "ap_core.fit.rpt"), ("" if "notable" in changes else
      "; Fitter Netlist Optimizations ;\n; Node ; Action ; Operation ;\n"
      "; core_top:ic|other|r[0] ; Duplicated ; Router Logic Cell Insertion ;\n\n\n")
      + "; ALMs needed [=A-B+C] ; 13,000 / 18,480 ( 70 % ) ;\n; Peak interconnect usage (total/H/V) ; 40% / 42% / 38% ;\n")
W(os.path.join(out, "ap_core.fit.summary"), "Logic utilization (in ALMs) : 13,000 / 18,480 ( 70 % )\n")
cs = "50.0" if kind in ("daria", "q5") else "28.636364"
W(os.path.join(out, "ap_core.map.rpt"), "; Parameter Settings for User Entity Instance: core_top:ic|atari7800_pocket:atari|psram:bup_psram ;\n"
  f"; CLOCK_SPEED ; {cs} ; Signed Float ;\n")
W(os.path.join(d, "quartus.log"), "Info (332104): Reading SDC File: 'core/daria_constraints.sdc'\n" if kind in ("daria", "q5") else "")
W(os.path.join(d, "report.log"), "")
ex = []
gl = ([("set_max_delay", "pd_tog", "pd_rx", tv["gb2"], "Fully overridden", 45)] if "gb2" in tv and GB else []) \
    + ([("set_max_delay", "pd_tog", "pd_rx", GB[0], "Complete", 46), ("set_min_delay", "pd_tog", "pd_rx", GB[1], "Complete", 48)]
       if GB else [])
for cmd, fr, to, v, st, _ in [("set_max_delay", "counter[0]", "counter[3]", "20.000", "Complete", 32),
                              ("set_max_delay", "counter[3]", "counter[0]", "20.000", "Partially overridden", 33),
                              ("set_min_delay", "counter[0]", "counter[3]", "-20.000", "Complete", 34),
                              ("set_min_delay", "counter[3]", "counter[0]", "-20.000", "Partially overridden", 35)] + gl:
    ex.append(f"; {st} ; {cmd} ; x ; x ; {{{fr}}} ; x ; x ; {{{to}}} ; {v} ;")
W(os.path.join(fpga, "exceptions.rpt"), "\n".join(ex) + "\n\n")
# sdc.rpt: the SDC as the Timing Analyzer read it (report_sdc's delay tables), the DARIA lines with DARIA only
REG = {"pd_tog": "[get_registers {*|daria_fe_guard:u_guard|pd_tog}]", "pd_rx": "[get_registers {*|daria_fe_guard:u_guard|pd_rx}]",
       "counter[0]": "[get_clocks {" + SYS + "}]", "counter[3]": "[get_clocks {" + ARM + "}]"}
if "nosdc" not in tv:
    sd = ["; Set Maximum Delay ;", "; SDC Command ; From Flags ; From ; Through ; To Flags ; To ; Delay ; Location ; Comment ;"]
    for cmd, fr, to, v, st, ln in ([("set_max_delay", "counter[0]", "counter[3]", "20.000", "", 32),
                                    ("set_max_delay", "counter[3]", "counter[0]", "20.000", "", 33),
                                    ("set_min_delay", "counter[0]", "counter[3]", "-20.000", "", 34),
                                    ("set_min_delay", "counter[3]", "counter[0]", "-20.000", "", 35)] if daria_k else []) + gl:
        sd.append(f"; {cmd} ; -from ; {REG[fr]} ; ; -to ; {REG[to]} ; {v} ; daria_constraints.sdc:{ln} ; ;")
    W(os.path.join(fpga, "sdc.rpt"), "\n".join(sd) + "\n")
if "fitsdc" in tv:
    os.makedirs(os.path.join(fpga, "core"), exist_ok=True)
    W(os.path.join(fpga, "core", "daria_constraints.sdc"), "# made up\n"
      'if {$::TimeQuestInfo(nameofexecutable) eq "quartus_fit"} {\n'
      "\tset_max_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \\\n"
      f"\t              -to   [get_registers -nowarn {{*|daria_fe_guard:u_guard|pd_rx}}] {tv['fitsdc']}\n}}\n")
meta = []
for n, r in enumerate([r for r in firsts if r["cls"] != "guard"]):
    meta.append(f"Synchronizer Chain #{n + 1}: Typical MTBF is made up\n; Synchronization Node ; {name(r['ep'])} ;\n"
                f"; Method of Synchronizer Identification ; User Specified ;\n")
W(os.path.join(fpga, "metastability.rpt"), "\n".join(meta))
W(os.path.join(fpga, "datasheet.rpt"), "; cram0_a[0] ; clk ; 5.0 ; 5.0 ; Rise ; x ;\n")
# crossings.tsv: one path into every expected endpoint
cr = ["dir\tsetup_rel\tsetup_slack\thold_rel\thold_slack\tlevels\tfrom\tto"]
odd = "kother" in tv or "khold" in tv      # one ordinary row still to change
for r in here:
    src = name(r["src"]) if r["src"] != "-" else "core_top:ic|held_source[0]"
    rel, hrel = KREL if r["cls"] == "guard" else ("20.000", "-20.000")
    if r["cls"] != "guard" and odd:
        odd = False
        rel, hrel = tuple(tv["kother"].split(",")) if "kother" in tv else (rel, hrel)
        hrel = tv.get("khold", hrel)
    cr.append(f"{r['dir']}\t{rel}\t5.000\t{hrel}\t25.000\t0\t{src}\t{name(r['ep'])}")
    if r["cls"] == "guard" and "kdup" in tv:
        cr.append(f"{r['dir']}\t{rel}\t5.000\t{hrel}\t25.000\t0\t{src}~DUPLICATE\t{name(r['ep'])}~DUPLICATE")
# fanin.tsv: every first flop's fan-in, one register of the other clock
fa = ["pattern\tto\tto_clock\tfrom\tfrom_clock\tlevels\tslack"]
fan = {}
for r in firsts:
    oth, own = (SYS, ARM) if r["dir"] == "s2a" else (ARM, SYS)
    fan[r["ep"]] = dict(r=r, own=own, rows=[[name(r["src"]) if r["src"] != "-" else "core_top:ic|src", oth, 0]])
def ep(short):
    return [k for k in fan if k.endswith("|" + short)][0]
for c in changes:
    m = re.match(r"(\w+(?:\[\d\])?)=(.*)", c)
    if not m or m.group(1) in ("drop",):
        continue
    e, how = fan[ep(m.group(1))], m.group(2)
    if how.startswith("levels"):            # levels:N on its one source
        e["rows"][0][2] = int(how.split(":")[1])
    elif how.startswith("dup"):             # the source register, a fitter duplicate
        e["rows"][0][0] += "~DUPLICATE"
    elif how == "two_cross":                # a second register of the other clock
        e["rows"].append(["core_top:ic|another_reg", e["rows"][0][1], 1]); e["rows"][0][2] = 1
    elif how.startswith("own"):             # own:N registers of its own clock
        for k in range(int(how.split(":")[1])):
            e["rows"].append([f"core_top:ic|own_reg{k}", e["own"], 1])
        e["rows"][0][2] = 1
    elif how == "bypass":                   # parked & img_ready: the state bits and img_ready
        e["rows"] = [[f"core_top:ic|atari7800_pocket:atari|bupchip_pocket:bupchip|bup_cpu:cpu|state[{k}]", e["rows"][0][1], 2] for k in range(3)] \
                    + [["core_top:ic|atari7800_pocket:atari|bupchip_pocket:bupchip|img_ready", e["rows"][0][1], 2]]
    elif how == "nopath":
        e["rows"] = []
for k, e in fan.items():
    to = name(k)
    if not e["rows"]:
        fa.append(f"{k}\t{to}\t-\t-\t-\t-\t-")
    for fr, clk, lv in e["rows"]:
        fa.append(f"{k}\t{to}\t{e['own']}\t{fr}\t{clk}\t{lv}\t5.000")
        if clk != e["own"] and not any(x.endswith("\t" + to) and f"\t{fr}\t" in x for x in cr):
            rel, hrel = KREL if e["r"]["cls"] == "guard" else ("20.000", "-20.000")
            cr.append(f"{e['r']['dir']}\t{rel}\t5.000\t{hrel}\t25.000\t{lv}\t{fr}\t{to}")
if "nofanin" not in changes:
    W(os.path.join(fpga, "fanin.tsv"), "\n".join(fa) + "\n")
W(os.path.join(fpga, "crossings.tsv"), "\n".join(cr) + "\n")
# The report script's (k), by the bounds it used (TB), from these rows, unless forced; then checks.txt.
def k_first():
    rows = [x.split("\t") for x in cr[1:]]
    if not rows or TB is None:
        return False
    for dirn, rel, _s, hrel, _h, _l, fr, to in rows:
        g = re.sub(r"~DUPLICATE\S*$", "", fr).endswith("u_guard|pd_tog") and re.sub(r"~DUPLICATE\S*$", "", to).endswith("u_guard|pd_rx")
        wr, wrh = TB if g else (20.0, -20.0)
        if abs(float(rel) - wr) > 0.0005 or hrel == "-" or abs(float(hrel) - wrh) > 0.0005:
            return False
    return True
kv = tv.get("tcl_k", "PASS" if k_first() else "FAIL")
checks = [f"CHECK k {kv}: made up" if c.split()[1] == "k" else c for c in checks]
W(os.path.join(fpga, "checks.txt"), "# step7_report.tcl: kind made up\n" + "\n".join(fig + checks) + "\n"
  + ("# step7_report.tcl: end\n" if end else ""))
PY
case_n=0
checker() {	# EXPECT(PASS or "FAIL: ids...") KIND DESCRIPTION CHANGES...
	local want="$1" kind="$2" what="$3" d got
	shift 3
	case_n=$((case_n + 1))
	d="$T/c/$case_n"
	python3 "$T/fixture.py" "$HERE/f3_crossings.txt" "$d" "$kind" "$@"
	python3 "$HERE/step7_checks.py" "$d" > "$d.out" 2>&1
	got="$(sed -n 's/^verdict: //p' "$d.out")"
	if [ "$want" = PASS ]; then
		[ "$got" = PASS ] && ok "checks: $what -> PASS" || bad "checks: $what -> $got (expected PASS); $d.out"
	else
		# every id expected must be among the failures, and no other
		local w g
		w="$(echo "${want#FAIL: }" | tr ' ' '\n' | sort | tr '\n' ' ')"
		g="$(echo "${got#FAIL: }" | tr ' ' '\n' | sort | tr '\n' ' ')"
		[ "${got%%:*}" = FAIL ] && [ "$w" = "$g" ] && ok "checks: $what -> $got" || bad "checks: $what -> '$got' (expected '$want'); $d.out"
	fi
}
kline() { grep "^  (k') " "$T/c/$case_n.out" | head -1 | cut -c1-400; }

checker PASS daria "Build B, every report as it should be"
checker PASS base "aeee6d2 (kind base), (g) the negative control failing"
checker "FAIL: g" base "kind base whose (g) never ran" "drop=g"
checker "FAIL: report g g.legs h h.retime i p" builda \
	"the review's case: Build A, quartus_sta stopped after (l), section ab's Tcl error, no fit report" \
	"drop=a,b,d,c.cells,e.files,f.files,g,g.legs,h,i,j,k,k'.files,k'.fanin,sdram.files,p,o.files" ab_error noend nofit
checker "FAIL: g.legs" builda "Build A whose (g.legs) never ran" "drop=g.legs"
checker "FAIL: a b" daria "Build B with a Tcl error in section ab (the old form of the id)" ab_error
checker "FAIL: g h" daria "Build B whose (g) and (h) never ran" "drop=g,h"
checker "FAIL: report" daria "Build B, step7_report.tcl stopped before its end" noend
checker "FAIL: report" daria "Build B, quartus_sta exit 1" rc1
checker "FAIL: k'" daria "Build B with no fanin.tsv" nofanin
checker "FAIL: c h.retime" daria "Build B with no fit report" nofit
checker "FAIL: c h.retime" daria "Build B whose fit report has no Fitter Netlist Optimizations table" notable
checker "FAIL: c h.retime" q5 "Q5 whose fit report has no Fitter Netlist Optimizations table" notable
checker "FAIL: h.retime" builda "Build A (Fix B, no DARIA) whose fit report has no such table: (h.retime) fails ((c) gates no Build A)" \
	notable
grep -q "^  (h.retime) FAIL .*no Fitter Netlist Optimizations table" "$T/c/$case_n.out" \
	&& ok "     (h.retime) names the missing table" || bad "     (h.retime) does not name the missing table: $T/c/$case_n.out"
echo "   (k'): the first flops' fan-in"
checker PASS daria "hold_a[0] behind a NOT (an inverted register: 1 level), cmd_s[0] from a fitter duplicate through a routing cell" \
	"hold_a[0]=levels:1" "cmd_s[0]=levels:1" "cmd_s[0]=dup"
echo "     $(kline)"
checker PASS daria "the reset class: en_s[0] with its clock's reset register (one more register)" "en_s[0]=own:1"
checker "FAIL: k'" daria "a two-register cone into prof_a[0]" "prof_a[0]=two_cross"
echo "     $(kline)"
checker "FAIL: k'" daria "the Q-mut bypass: ready_s[0] samples parked & img_ready" "ready_s[0]=bypass"
echo "     $(kline)"
checker "FAIL: k'" daria "run_s[0] (class first) gated by a register of its own clock" "run_s[0]=own:1"
checker "FAIL: k'" daria "en_s[0] (class reset) with two registers of its own clock" "en_s[0]=own:2"
checker "FAIL: k'" daria "the guard's pd_rx with a register of its own clock" "pd_rx=own:1"
checker "FAIL: k'" daria "ftog_s[0] with no timed path into it" "ftog_s[0]=nopath"
echo "   (a), (l), (h) by the divider (plan 5.4 as amended 2026-10-14)"
fline() {	# EXPECT: the "rules as first written:" line of the last case
	local got
	got="$(sed -n 's/^rules as first written: //p' "$T/c/$case_n.out")"
	[ "$(echo "${got#FAIL: }" | tr ' ' '\n' | sort | tr '\n' ' ')" = "$(echo "${1#FAIL: }" | tr ' ' '\n' | sort | tr '\n' ' ')" ] \
		&& [ "${got%%:*}" = "${1%%:*}" ] && ok "     rules as first written: $got" || bad "     rules as first written: '$got' (expected '$1')"
}
has() {	# ID TEXT: the last case's line for check ID says TEXT
	grep "^  ($1) " "$T/c/$case_n.out" | grep -qF -- "$2" && ok "     ($1) says: $2" || bad "     ($1) does not say: $2 ($T/c/$case_n.out)"
}
checker PASS daria "VCO/19, every figure positive" t:div=19
checker PASS daria "VCO/19: the guard pair at -0.046 ns, the only failing clk_sys endpoint, and t_*_q at +4.298 (Q2 seeds 3 and 1)" \
	t:div=19 t:gs=-0.046 t:h=4.298
fline "FAIL: a l h"
has l "clk_sys setup -0.046 at 8_slow_1100mv_85c is pd_tog -> pd_rx's"
has a "its slack reported, not gated"
checker "FAIL: a l h" daria "the same at VCO/18: the rules as first written" t:div=18 t:gs=-0.046 t:h=4.298
fline "FAIL: a l h"
checker PASS q5 "Q5 at VCO/19 with the guard pair at -0.046" t:div=19 t:gs=-0.046
checker "FAIL: l" daria "VCO/19, the pair at -0.046 and another clk_sys endpoint at -0.010 (End Point TNS -0.056)" \
	t:div=19 t:gs=-0.046 t:sys=-0.010
has l "End Point TNS -0.056"
checker "FAIL: l" daria "VCO/19, the pair met and another clk_sys path at -0.010 (the only failing endpoint)" t:div=19 t:sys=-0.010
has l "another clk_sys path is worse"
checker "FAIL: l" daria "VCO/19, another clk_sys path worse than the pair (-0.080 against -0.046)" t:div=19 t:gs=-0.046 t:sys=-0.080
checker "FAIL: l" daria "VCO/19, the pair at -0.046 and no Timing Analyzer summary" t:div=19 t:gs=-0.046 t:nosta
has l "no ap_core.sta.rpt"
checker "FAIL: l" daria "VCO/19, the pair at -0.046 and a Timing Analyzer summary from another analysis (clk_sys -0.030)" \
	t:div=19 t:gs=-0.046 t:stas=-0.030
has l "another analysis"
checker "FAIL: l" daria "VCO/19, clk_sys hold at -0.010 (only the pair's setup is left out)" t:div=19 t:syshold=-0.010
checker "FAIL: l" daria "VCO/19, the pair's setup and clk_sys hold both at -0.046: the hold stays" t:div=19 t:gs=-0.046 t:syshold=-0.046
has l "clk_sys hold -0.046 at 8_slow_1100mv_85c (not the guard pair's setup)"
checker "FAIL: l k'" daria "VCO/19, the pair at -0.046 with a register of pd_rx's own clock in its fan-in" \
	t:div=19 t:gs=-0.046 "pd_rx=own:1"
has l "pd_rx's timed fan-in is not pd_tog alone"
checker "FAIL: a" daria "VCO/19, two setup paths pd_tog -> pd_rx (a copy of a flop)" t:div=19 t:gpaths=2
has a "at every corner (NO)"
checker "FAIL: a" daria "VCO/19, the pair at 20.000 ns (the 6 ns constraint not applied)" t:div=19 t:grel=20.000
has a "the constraint applied (NO)"
checker "FAIL: h" daria "VCO/19, t_*_q -> clk_sdram at +2.900" t:div=19 t:h=2.900
checker "FAIL: h" builda "Build A (no DARIA, divider 24) with t_*_q at +4.298: +4.5 holds" t:div=24 t:h=4.298
checker "FAIL: h" daria "VCO/19, t_*_q -> clk_sdram setup +6.697 and its worst hold -0.010" t:div=19 t:hhold=-0.010
has h "hold -0.010 (>= 0)"
checker "FAIL: h" daria "VCO/18, the same hold" t:div=18 t:hhold=-0.010
checker "FAIL: a" daria "VCO/19, no pd_tog -> pd_rx setup line for the slow 0C corner" t:div=19 t:anocorner=1
has a "no setup figures for pd_tog -> pd_rx at ['8_slow_1100mv_0c']"
checker "FAIL: a" daria "VCO/19, no setup line for the fast 0C corner (the last)" t:div=19 t:anocorner=3
has a "MIN_fast_1100mv_0c"
checker "FAIL: a" daria "VCO/18, no setup line for the slow 0C corner" t:div=18 t:anocorner=1
checker "FAIL: l" daria "VCO/19, the report script said (l) PASS on figures with a failing clock (a misread)" \
	t:div=19 t:sys=-0.080 t:tcl_l=PASS
grep -q "misread" "$T/c/$case_n.out" && ok "     the misread is named" || bad "     the misread is not named: $T/c/$case_n.out"
echo "   (c.cells) judged again from firstflops.tsv by the tree's ff_table"
checker PASS q5 "Q5 fitted with plan 2.7's old table (cap_err_a[0] present in Q5, found 0): the report script failed (c.cells)" \
	t:div=19 "ffwant:cap_err_a[0]"
has c.cells "rows the tree's table changed since the fit: ['cap_err_a[0] present -> absent']"
has c.cells "the report script, by the table it ran with: FAIL"
fline PASS
checker "FAIL: c.cells" q5 "Q5 with cap_err_a[0] found once (absent by the table)" t:div=19 "ff:cap_err_a[0]=1"
has c.cells "cap_err_a[0] PRESENT (expected absent, found 1)"
checker "FAIL: c.cells" daria "Build B with ftog_s[0] not found" "ff:ftog_s[0]=0"
has c.cells "ftog_s[0] MISSING (expected present, found 0)"
checker "FAIL: c.cells" daria "Build B with ftog_s[0] found twice" "ff:ftog_s[0]=2"
checker "FAIL: c.cells" daria "the report script said (c.cells) PASS on counts that fail by its own table (a misread)" \
	"ff:ftog_s[0]=0" t:tcl_cells=PASS
has c.cells "misread"
checker "FAIL: c.cells" daria "Build B with no firstflops.tsv" noff
has c.cells "firstflops.tsv missing"
checker "FAIL: c.cells" daria "firstflops.tsv without ready_s[0]'s row" "ffdrop:ready_s[0]"
has c.cells "in the tree's table but not counted"
echo "   (a), (b), (k), (e) by the guard pair's bounds from sdc.rpt (plan 5.4 as amended for G1, 2026-10-19; docs/daria_step10/plan.md section 10)"
G1="t:gb=8.000,0.500"
checker PASS daria "G1 ([0.500, 8.000] ns) at VCO/18, every figure positive (a candidate fit)" t:div=18 $G1
has a "relationship 8.000 ns"
has b "relationship 0.500 ns"
has k "pd_tog -> pd_rx at 8.000 / 0.500 ns"
has e "set_max_delay pd_tog->pd_rx 8.000: Complete; set_min_delay pd_tog->pd_rx 0.500: Complete"
fline PASS
checker PASS q5 "Q5 with G1 at VCO/18" t:div=18 $G1
checker PASS daria "the pair as first written ([1.000, 6.000] ns) at VCO/18, read from sdc.rpt" t:div=18
has e "the guard pair's bounds 6.000 / 1.000 ns (first, the SDC's)"
checker PASS daria "G1 at VCO/18 from a report made before the bounds were read (no '# guard bounds' line: it held the pair to 6 / 1 and failed (a), (b), (k))" \
	t:div=18 $G1 t:tclb=old
has k "the report script, with 6.000 / 1.000 ns, fixed in the report script"
fline PASS
checker PASS daria "the pair as first written at VCO/19 from such a report (Q2's figures: the pair at -0.046, t_*_q at +4.298)" \
	t:div=19 t:gs=-0.046 t:h=4.298 t:tclb=old
fline "FAIL: a l h"
checker PASS daria "G1 at VCO/19 with the pair's setup at -0.046 (reported, not gated, as amended 2026-10-14)" t:div=19 $G1 t:gs=-0.046
fline "FAIL: a l"
checker "FAIL: a l" daria "G1 at VCO/18 with the pair's setup at -0.046 (gated at VCO/18)" t:div=18 $G1 t:gs=-0.046
checker "FAIL: a b k" daria "G1 in sdc.rpt but the pair timed at 6 / 1 ns at VCO/19 (the relationship not the SDC's)" \
	t:div=19 $G1 t:grel=6.000 t:ghrel=1.000 t:krel=6.000,1.000
has a "relationship 8.000 ns, the constraint applied (NO)"
checker "FAIL: a b e k" daria "a pair not in the table: [0.700, 7.300] ns" t:gb=7.300,0.700
has a "is not one of the known pairs"
has e "is not one of the known pairs"
checker "FAIL: a b e k" daria "G1 half applied: [1.000, 8.000] ns (the setup bound changed, the hold bound not)" t:gb=8.000,1.000
has b "is not one of the known pairs"
checker "FAIL: a b e k" daria "Q-mut's guard pair removed, under G1 as before: no pd_tog -> pd_rx line, the path at the +-20 ns clock bound" t:gb=none
has a "0 set_max_delay and 0 set_min_delay"
has a "rel 20.000"
checker "FAIL: a b e k" daria "the same from a report made before the bounds were read (as c76's stam_noguard)" t:gb=none t:tclb=old
checker "FAIL: a b e k" daria "two set_max_delay lines on the pair (G1's 8.000 added after the 6.000 kept)" $G1 t:gb2=6.000
has a "2 set_max_delay and 1 set_min_delay"
checker "FAIL: a b e k" daria "no sdc.rpt" $G1 t:nosdc
has e "sdc.rpt missing"
checker "FAIL: a b k" daria "the report script judged with 6 / 1 (its line) where sdc.rpt says G1" $G1 t:tclb=6.000,1.000
has k "but sdc.rpt gives 8.000 / 0.500 ns"
checker PASS daria "G1 fitted with a table that lacked G1's row (the report script read no known bounds and failed (a), (b), (k)): judged again by the tree's table" \
	$G1 t:tclb=none
has a "the report script, with not known to the report script"
fline PASS
checker "FAIL: a" daria "G1: the report script said (a) FAIL on figures that pass by its own bounds (a misread)" $G1 t:tcl_a=FAIL
has a "misread"
checker "FAIL: b" daria "G1: the report script said (b) FAIL on figures that pass by its own bounds (a misread)" $G1 t:tcl_b=FAIL
has b "misread"
checker "FAIL: k" daria "G1: the report script said (k) PASS with the pair's row at 6 / 1 (a misread)" $G1 t:krel=6.000,1.000 t:tcl_k=PASS
has k "misread"
checker "FAIL: b" daria "G1, the pair's hold slack -0.010 at the slow 85C corner" $G1 t:ghs=-0.010
checker "FAIL: b" daria "G1, two hold paths pd_tog -> pd_rx at one corner" $G1 t:ghpaths=2
checker "FAIL: k" daria "G1, an ordinary crossing pair at 8.000 / 0.500 ns" $G1 t:kother=8.000,0.500
has k "1 not:"
checker "FAIL: k" daria "G1, an ordinary crossing pair with no hold path" $G1 t:khold=-
checker PASS daria "G1, the pair also as ~DUPLICATE registers in crossings.tsv: (k) holds them to the SDC's bounds ((c) is what fails a duplicate)" \
	$G1 t:kdup
has k "2 of them the guard pair"
checker PASS daria "G1, the copy's SDC asking the fitter for 7.500 on the pair" $G1 t:fitsdc=7.500
has e "fitter-only line: 7.500 ns (the pair's own)"
checker PASS daria "G1, the fitter still asked for 5.500 (information, not gated)" $G1 t:fitsdc=5.500
has e "NOT 7.500, the pair's own"
# The table decides: a copy of the scripts whose guard_pairs has no G1 row fails a G1 fit on (a), (b), (e), (k).
mkdir -p "$T/nog1"
cp "$HERE/step7_checks.py" "$HERE/f3_crossings.txt" "$T/nog1/"
grep -v '^\s*{8\.000 0\.500 7\.500 G1}$' "$HERE/step7_report.tcl" > "$T/nog1/step7_report.tcl"
case_n=$((case_n + 1))
python3 "$T/fixture.py" "$HERE/f3_crossings.txt" "$T/c/$case_n" daria $G1 t:tclb=old
python3 "$T/nog1/step7_checks.py" "$T/c/$case_n" > "$T/c/$case_n.out" 2>&1
got="$(sed -n 's/^verdict: //p' "$T/c/$case_n.out")"
if cmp -s "$HERE/step7_report.tcl" "$T/nog1/step7_report.tcl"; then bad "guard_pairs: could not remove the G1 row from a copy of step7_report.tcl"
elif [ "$(echo "${got#FAIL: }" | tr ' ' '\n' | sort | tr '\n' ' ')" = "a b e k " ] && grep -q "^  (a) .*is not one of the known pairs" "$T/c/$case_n.out"; then
	ok "checks: G1 judged with a table without G1's row -> $got"
else bad "checks: G1 judged with a table without G1's row -> '$got' (expected 'FAIL: a b e k'); $T/c/$case_n.out"; fi

# ---- 2b. the two copies of plan 2.7's table -------------------------------------------------------------------
echo "-- 2b. step7_report.tcl's ff_table and f3_crossings.txt: the same first flops, present in the same kinds"
cat > "$T/tables.py" <<'PY'
"""Compares step7_report.tcl's ff_table (pattern, in Build B, in Q5) with
f3_crossings.txt's first, reset and guard rows (the kinds each is expected
in): the same registers, each present in the same kinds. A register is named
by its entity and its own name, since the instance part of a pattern may be
'*' in one table and the instance in the other."""
import re, sys
tcl, f3 = open(sys.argv[1]).read(), open(sys.argv[2]).read()
def key(p):
    m = re.match(r"^\*\|(\w+):[^|]+\|(\S+)$", p)
    return (m.group(1), m.group(2)) if m else ("?", p)
m = re.search(r"(?ms)^set ff_table \{\n(.*?)^\}", tcl)
ff = {}
for line in (m.group(1) if m else "").splitlines():
    r = re.match(r"\s*\{([^}]+)\}\s+([01])\s+([01])\s*$", line)
    if r:
        ff[key(r.group(1))] = {"daria": r.group(2) == "1", "q5": r.group(3) == "1"}
tab = {}
for line in f3.splitlines():
    c = line.split("#", 1)[0].split()
    if len(c) == 5 and c[2] in ("first", "reset", "guard"):
        tab[key(c[3])] = {"daria": "daria" in c[1].split(","), "q5": "q5" in c[1].split(",")}
bad = []
if not ff or not tab:
    bad.append(f"a table not read: ff_table {len(ff)} rows, f3_crossings.txt {len(tab)} rows")
for k in sorted(set(ff) | set(tab)):
    if k not in ff or k not in tab:
        bad.append(f"{k[0]}|{k[1]} only in {'ff_table' if k in ff else 'f3_crossings.txt'}")
    elif ff[k] != tab[k]:
        bad.append(f"{k[0]}|{k[1]}: ff_table {ff[k]}, f3_crossings.txt {tab[k]}")
print(f"{len(ff)} ff_table rows, {len(tab)} f3_crossings.txt rows; " + ("; ".join(bad) if bad else "the same"))
sys.exit(1 if bad else 0)
PY
tables() { python3 "$T/tables.py" "$1" "$2" > "$T/tables.out" 2>&1; }
if tables "$HERE/step7_report.tcl" "$HERE/f3_crossings.txt"; then ok "tables: the tree's two tables agree: $(cat "$T/tables.out")"
else bad "tables: the tree's two tables differ: $(cat "$T/tables.out")"; fi
sed 's/^\(\t{\*|bupchip_pocket:bupchip|cap_err_a\[0\]}\) 0 0$/\1 0 1/' "$HERE/step7_report.tcl" > "$T/ff_q5.tcl"
if cmp -s "$HERE/step7_report.tcl" "$T/ff_q5.tcl"; then bad "tables: could not plant cap_err_a[0] present in Q5 in a copy of ff_table"
elif tables "$T/ff_q5.tcl" "$HERE/f3_crossings.txt"; then bad "tables: ff_table with cap_err_a[0] in Q5 passed: $(cat "$T/tables.out")"
else grep -q "cap_err_a\[0\]" "$T/tables.out" && ok "tables: ff_table with cap_err_a[0] in Q5 is caught: $(cut -c1-200 "$T/tables.out")" \
	|| bad "tables: caught, but not on cap_err_a[0]: $(cat "$T/tables.out")"; fi
grep -v 'ftog_s\[0\]' "$HERE/f3_crossings.txt" > "$T/f3_noftog.txt"
if tables "$HERE/step7_report.tcl" "$T/f3_noftog.txt"; then bad "tables: f3_crossings.txt without ftog_s[0] passed: $(cat "$T/tables.out")"
else grep -q "ftog_s\[0\] only in ff_table" "$T/tables.out" && ok "tables: f3_crossings.txt without ftog_s[0] is caught: $(cut -c1-200 "$T/tables.out")" \
	|| bad "tables: caught, but not as ftog_s[0] missing: $(cat "$T/tables.out")"; fi

# ---- 3. run_step7.sh's refusals ------------------------------------------------------------------------------
echo "-- 3. run_step7.sh: protected directories, existing run directories, the lock (a stand-in docker)"
DRV="$HERE/run_step7.sh"
# run_step7.sh's free-space check reads a stand-in df (the figure in $T/df_mb), so that its 2,048 MB floor is
# tested as such and the machine's free space does not decide the result. What the tests that pass that check
# really write is a copy of src/fpga (3.3 MB) each, three of them: they need 100 MB free, or are skipped.
avail=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
roomy=1
[ "$avail" -ge 100 ] || roomy=0
{
	mkdir -p "$T/bin" "$T/c/sim/work/step7/ref/runs" "$T/c/sim/work/bupchip/fullprobe/base_s2" "$T/w"
	printf '#!/bin/sh\necho "stand-in docker: $*" >&2\nexit 1\n' > "$T/bin/docker"
	chmod +x "$T/bin/docker"
	printf '#!/bin/sh\n# stand-in df: run_step7.sh asks "df -BM --output=avail /"\necho Avail\necho "$(cat %s)M"\n' "$T/df_mb" > "$T/bin/df"
	chmod +x "$T/bin/df"
	echo 2048 > "$T/df_mb"
	echo "   (free on /: $avail MB; run_step7.sh reads a stand-in df: 2048 MB, its floor)"
	echo canary > "$T/c/sim/work/step7/ref/runs/canary"
	echo canary > "$T/c/sim/work/bupchip/fullprobe/base_s2/canary"
	LOCKF="$T/lock"
	: > "$LOCKF"
	canaries() { [ -f "$T/c/sim/work/step7/ref/runs/canary" ] && [ -f "$T/c/sim/work/bupchip/fullprobe/base_s2/canary" ]; }
	drv() {	# EXPECTED_EXIT DESCRIPTION ENV...: run_step7.sh under this test's lock
		local want="$1" what="$2" rc
		shift 2
		PATH="$T/bin:$PATH" flock "$LOCKF" env QUARTUS_LOCK="$LOCKF" TREE="$ROOT" SEED=1 "$@" "$DRV" > "$T/drv.out" 2>&1
		rc=$?
		if [ "$rc" = "$want" ] && canaries; then ok "driver: $what -> exit $rc$([ "$rc" = 2 ] && echo ": $(grep -m1 'run_step7.sh:' "$T/drv.out" | cut -c1-150)")"
		else bad "driver: $what -> exit $rc (expected $want), canaries $(canaries && echo intact || echo GONE): $(tail -2 "$T/drv.out")"; fi
	}
	drv 2 "WORK=.../sim/work/step7 TAG=ref (the review's case)" WORK="$T/c/sim/work/step7" TAG=ref
	drv 2 "WORK=.../sim/work/bupchip TAG=fullprobe (the review's case)" WORK="$T/c/sim/work/bupchip" TAG=fullprobe
	drv 2 "WORK=.../sim/work TAG=bupchip (holds fullprobe)" WORK="$T/c/sim/work" TAG=bupchip
	drv 2 "the same with FORCE=1" WORK="$T/c/sim/work" TAG=bupchip FORCE=1
	drv 2 "WORK=.../c TAG=sim FORCE=1" WORK="$T/c" TAG=sim FORCE=1
	drv 2 "WORK inside step7/ref" WORK="$T/c/sim/work/step7/ref/runs"
	ln -s "$T/c/sim/work/step7/ref" "$T/w/link"
	drv 2 "TAG a symbolic link to step7/ref, FORCE=1" WORK="$T/w" TAG=link FORCE=1
	echo 2047 > "$T/df_mb"
	drv 2 "2,047 MB free (the stand-in df), one under the floor" WORK="$T/w" TAG=floor
	grep -q "only 2047 MB free on /" "$T/drv.out" && [ ! -e "$T/w/floor" ] && ok "driver: refused on the free space, no run directory made" \
		|| bad "driver: 2,047 MB not refused on the free space, or a run directory made: $(tail -1 "$T/drv.out")"
	echo 2048 > "$T/df_mb"
	if [ "$roomy" = 1 ]; then
		drv 1 "a new run directory (the stand-in compile fails)" WORK="$T/w" TAG=fresh
		[ -f "$T/w/fresh/.step7_run" ] && ok "driver: the new run directory is marked .step7_run" || bad "driver: no .step7_run in a new run directory"
		echo keep > "$T/w/fresh/keep.rbf"
		drv 2 "the same TAG again, without FORCE" WORK="$T/w" TAG=fresh
		[ -f "$T/w/fresh/keep.rbf" ] && ok "driver: its files kept" || bad "driver: its files lost without FORCE"
		drv 1 "the same TAG with FORCE=1 (made by run_step7.sh)" WORK="$T/w" TAG=fresh FORCE=1
		[ ! -f "$T/w/fresh/keep.rbf" ] && [ -f "$T/w/fresh/.step7_run" ] && ok "driver: replaced with FORCE=1" || bad "driver: not replaced with FORCE=1"
	else
		skip "driver: a new run directory, the same TAG without and with FORCE=1 (each copies src/fpga): only $avail MB free, 100 needed"
	fi
	mkdir -p "$T/w/odd/sim/work/step7/ref"
	echo canary > "$T/w/odd/sim/work/step7/ref/canary"
	echo "run_step7.sh run directory" > "$T/w/odd/.step7_run"
	drv 2 "FORCE=1 on a marked directory that holds a step7/ref" WORK="$T/w" TAG=odd FORCE=1
	[ -f "$T/w/odd/sim/work/step7/ref/canary" ] && ok "driver: its step7/ref kept" || bad "driver: its step7/ref deleted"
	mkdir -p "$T/w/notours"
	drv 2 "FORCE=1 on a directory run_step7.sh did not make" WORK="$T/w" TAG=notours FORCE=1
	# the lock
	PATH="$T/bin:$PATH" env QUARTUS_LOCK="$LOCKF" TREE="$ROOT" WORK="$T/w" TAG=free "$DRV" > "$T/drv.out" 2>&1
	rc=$?
	[ "$rc" = 2 ] && grep -q "lock is free" "$T/drv.out" && ok "driver: the lock free -> exit 2" || bad "driver: the lock free -> exit $rc: $(tail -1 "$T/drv.out")"
	# another job holding the lock: a process that takes it itself and lives on
	python3 -c 'import fcntl, sys, time; f = open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(60)' "$LOCKF" &
	SLEEPER=$!
	for _ in $(seq 50); do flock -n "$LOCKF" true || break; sleep 0.1; done
	PATH="$T/bin:$PATH" env QUARTUS_LOCK="$LOCKF" TREE="$ROOT" WORK="$T/w" TAG=other "$DRV" > "$T/drv.out" 2>&1
	rc=$?
	[ "$rc" = 2 ] && grep -q "held by PID" "$T/drv.out" && [ ! -e "$T/w/other" ] \
		&& ok "driver: the lock held by another job -> exit 2: $(grep -m1 'held by PID' "$T/drv.out" | cut -c1-110)" \
		|| bad "driver: the lock held by another job -> exit $rc: $(tail -1 "$T/drv.out")"
	kill "$SLEEPER" 2>/dev/null
	wait "$SLEEPER" 2>/dev/null
	SLEEPER=""
	if [ "$roomy" = 1 ]; then
		PATH="$T/bin:$PATH" QUARTUS_LOCK="$LOCKF" TREE="$ROOT" WORK="$T/w" TAG=viafd DRV="$DRV" LOCKF="$LOCKF" \
			bash -c 'exec 9>"$LOCKF"; flock 9; "$DRV"' > "$T/drv.out" 2>&1
		rc=$?
		[ "$rc" = 1 ] && [ -f "$T/w/viafd/.step7_run" ] && ok "driver: the lock taken on an inherited descriptor (exec 9>lock; flock 9) -> accepted" \
			|| bad "driver: exec 9>lock; flock 9 -> exit $rc: $(tail -1 "$T/drv.out")"
	else
		skip "driver: the lock taken on an inherited descriptor (copies src/fpga): only $avail MB free, 100 needed"
	fi
}

echo "selftest.sh: $npass passed, $nfail failed, $nskip skipped"
if [ "$nfail" != 0 ]; then echo "selftest.sh: FAIL"; exit 1; fi
if [ "$nskip" != 0 ]; then echo "PARTIAL: $nskip test(s) skipped for want of free space (the SKIPPED lines): not a pass"; exit 3; fi
echo "selftest.sh: PASS"
