#!/bin/bash
# Self-test of the step-7 fit driver's parts that need no Quartus
# (docs/daria_step7/plan.md 3.5 "Fit scripts", 5.4): step7_prep.py's DARIA
# lines, step7_checks.py's verdict and its (k') rule on made-up report files,
# and run_step7.sh's refusals, with a stand-in docker and a lock file of its
# own (never the machine's Quartus lock). Every directory it makes is under
# one mktemp -d, removed at the end; nothing in the tree is written.
#   sim/bupchip/quartus_probe/step7/selftest.sh
# Needs 2 GB free on / (run_step7.sh's own check). Exit 0 when every test
# passes. The quartus side (step7_report.tcl, daria.qip) is smoke/run_smoke.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
T="$(mktemp -d)"
SLEEPER=""
cleanup() { [ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null; rm -rf -- "$T"; }
trap cleanup EXIT
npass=0
nfail=0
ok() { echo "PASS $*"; npass=$((npass + 1)); }
bad() { echo "FAIL $*"; nfail=$((nfail + 1)); }

echo "== selftest.sh $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "HEAD $(git -C "$ROOT" rev-parse HEAD); status $(git -C "$ROOT" status --porcelain | wc -l) lines"
git -C "$ROOT" status --porcelain | sed 's/^/  /'
echo "bash $BASH_VERSION; $(python3 --version 2>&1); flock $(flock --version 2>&1 | head -1)"
echo "md5: $(cd "$HERE" && md5sum selftest.sh run_step7.sh step7_lock.sh step7_prep.py step7_checks.py f3_crossings.txt | awk '{printf "%s %s; ", $2, substr($1,1,12)}')"

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
# if from another analysis), t:tcl_a/l/h (the report script's verdict, forced)
tv = dict(div="18", gs="0.217", sys="1.000", syshold="0.291", gpaths="1", grel="6.000", h="6.697")
for c in changes:
    m = re.match(r"t:(\w+)(?:=(.*))?$", c)
    if m:
        tv[m.group(1)] = m.group(2) if m.group(2) is not None else "1"
W(os.path.join(fpga, "step7_prep.txt"), f"kind {kind}\ndaria {int(kind in ('daria', 'q5'))}\nbup_debug {int(kind == 'q5')}\n"
  f"fixb {int(kind != 'base')}\ndiv {tv['div']}\nseed 2\npin_id 0\noldpad 0\n")
CORNERS = [("8_slow_1100mv_85c", "Slow 1100mV 85C"), ("8_slow_1100mv_0c", "Slow 1100mV 0C"),
           ("MIN_fast_1100mv_85c", "Fast 1100mV 85C"), ("MIN_fast_1100mv_0c", "Fast 1100mV 0C")]
gs = {c: float(tv["gs"]) if n == 0 else 0.45 + n for n, (c, _) in enumerate(CORNERS)}
osys = {c: float(tv["sys"]) if n == 0 else 1.0 + n for n, (c, _) in enumerate(CORNERS)}
fig = [f"# corners: {' '.join(c for c, _ in CORNERS)}", "## (a) (b) (d) the guard pair pd_tog -> pd_rx (made up)"]
for n, (c, _) in enumerate(CORNERS):
    k = int(tv["gpaths"]) if n == 0 else 1
    fig.append(f"  {c} setup: {k} path(s);" + f" rel {float(tv['grel']):.3f} slack {gs[c]:.3f} skew -1.000 data 4.000;" * k)
    fig.append(f"  {c} hold: 1 path(s); rel 1.000 slack 2.000 skew 0.000 data 3.000;")
fig += ["## (h) Fix B checks 2-4: t_*_q (made up)",
        f"  t_*_q -> clk_sdram: worst setup {float(tv['h']):.3f} ns (6 levels, >= +4.5), worst hold over corners 0.300 ns (>= 0)",
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
first = dict(a=int(tv["gpaths"]) == 1 and abs(float(tv["grel"]) - 6.0) < 0.0005 and min(gs.values()) >= 0,
             l=all(not (l.split()[2] != "-" and float(l.split()[2]) < 0) and not (l.split()[4] != "-" and float(l.split()[4]) < 0)
                   for l in tim if not l.startswith("==")),
             h=float(tv["h"]) >= 4.5)
first = {k: tv.get("tcl_" + k, "PASS" if v else "FAIL") for k, v in first.items()}
ids = ["l.clocks", "l", "gate.clk_sdram", "gate.clk_arm", "gate.hold", "a", "b", "d", "c.cells", "e.files", "f.files",
       "g", "g.legs", "h", "i", "j", "k", "k'.files", "k'.fanin", "sdram.files", "p", "o.files"]
info = {"d", "e.files", "f.files", "i", "k'.files", "k'.fanin", "sdram.files", "p", "o.files"}
checks = [f"CHECK {i} {'INFO' if i in info else first.get(i, 'PASS')}: made up" for i in ids]
if kind == "base":
    checks = [c.replace("CHECK g PASS", "CHECK g FAIL") for c in checks]
for c in changes:
    if c.startswith("drop="):
        gone = c[5:].split(",")
        checks = [x for x in checks if x.split()[1] not in gone]
    if c == "ab_error":
        checks = [x for x in checks if x.split()[1] not in ("a", "b", "d")] + ["CHECK ab FAIL: Tcl error in the report script: made up"]
end = "noend" not in changes
W(os.path.join(fpga, "checks.txt"), "# step7_report.tcl: kind made up\n" + "\n".join(fig + checks) + "\n"
  + ("# step7_report.tcl: end\n" if end else ""))
W(os.path.join(fpga, "report_rc.txt"), "1\n" if "rc1" in changes else "0\n")
if "nofit" not in changes:
    W(os.path.join(out, "ap_core.fit.rpt"), "; Fitter Netlist Optimizations ;\n; Node ; Action ; Operation ;\n"
      "; core_top:ic|other|r[0] ; Duplicated ; Router Logic Cell Insertion ;\n\n\n"
      "; ALMs needed [=A-B+C] ; 13,000 / 18,480 ( 70 % ) ;\n; Peak interconnect usage (total/H/V) ; 40% / 42% / 38% ;\n")
W(os.path.join(out, "ap_core.fit.summary"), "Logic utilization (in ALMs) : 13,000 / 18,480 ( 70 % )\n")
cs = "50.0" if kind in ("daria", "q5") else "28.636364"
W(os.path.join(out, "ap_core.map.rpt"), "; Parameter Settings for User Entity Instance: core_top:ic|atari7800_pocket:atari|psram:bup_psram ;\n"
  f"; CLOCK_SPEED ; {cs} ; Signed Float ;\n")
W(os.path.join(d, "quartus.log"), "Info (332104): Reading SDC File: 'core/daria_constraints.sdc'\n" if kind in ("daria", "q5") else "")
W(os.path.join(d, "report.log"), "")
ex = []
for cmd, fr, to, v, st in (("set_max_delay", "counter[0]", "counter[3]", "20.000", "Complete"),
                           ("set_max_delay", "counter[3]", "counter[0]", "20.000", "Partially overridden"),
                           ("set_min_delay", "counter[0]", "counter[3]", "-20.000", "Complete"),
                           ("set_min_delay", "counter[3]", "counter[0]", "-20.000", "Partially overridden"),
                           ("set_max_delay", "pd_tog", "pd_rx", "6.000", "Complete"),
                           ("set_min_delay", "pd_tog", "pd_rx", "1.000", "Complete")):
    ex.append(f"; {st} ; {cmd} ; x ; x ; {{{fr}}} ; x ; x ; {{{to}}} ; {v} ;")
W(os.path.join(fpga, "exceptions.rpt"), "\n".join(ex) + "\n\n")
meta = []
for n, r in enumerate([r for r in firsts if r["cls"] != "guard"]):
    meta.append(f"Synchronizer Chain #{n + 1}: Typical MTBF is made up\n; Synchronization Node ; {name(r['ep'])} ;\n"
                f"; Method of Synchronizer Identification ; User Specified ;\n")
W(os.path.join(fpga, "metastability.rpt"), "\n".join(meta))
W(os.path.join(fpga, "datasheet.rpt"), "; cram0_a[0] ; clk ; 5.0 ; 5.0 ; Rise ; x ;\n")
# crossings.tsv: one path into every expected endpoint
cr = ["dir\tsetup_rel\tsetup_slack\thold_rel\thold_slack\tlevels\tfrom\tto"]
for r in here:
    src = name(r["src"]) if r["src"] != "-" else "core_top:ic|held_source[0]"
    rel, hrel = ("6.000", "1.000") if r["cls"] == "guard" else ("20.000", "-20.000")
    cr.append(f"{r['dir']}\t{rel}\t5.000\t{hrel}\t25.000\t0\t{src}\t{name(r['ep'])}")
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
            rel, hrel = ("6.000", "1.000") if e["r"]["cls"] == "guard" else ("20.000", "-20.000")
            cr.append(f"{e['r']['dir']}\t{rel}\t5.000\t{hrel}\t25.000\t{lv}\t{fr}\t{to}")
if "nofanin" not in changes:
    W(os.path.join(fpga, "fanin.tsv"), "\n".join(fa) + "\n")
W(os.path.join(fpga, "crossings.tsv"), "\n".join(cr) + "\n")
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
checker "FAIL: l" daria "VCO/19, the report script said (l) PASS on figures with a failing clock (a misread)" \
	t:div=19 t:sys=-0.080 t:tcl_l=PASS
grep -q "misread" "$T/c/$case_n.out" && ok "     the misread is named" || bad "     the misread is not named: $T/c/$case_n.out"

# ---- 3. run_step7.sh's refusals ------------------------------------------------------------------------------
echo "-- 3. run_step7.sh: protected directories, existing run directories, the lock (a stand-in docker)"
DRV="$HERE/run_step7.sh"
avail=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
if [ "$avail" -lt 2100 ]; then
	bad "only $avail MB free: run_step7.sh refuses to start below 2 GB, so its tests cannot run"
else
	mkdir -p "$T/bin" "$T/c/sim/work/step7/ref/runs" "$T/c/sim/work/bupchip/fullprobe/base_s2" "$T/w"
	printf '#!/bin/sh\necho "stand-in docker: $*" >&2\nexit 1\n' > "$T/bin/docker"
	chmod +x "$T/bin/docker"
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
	drv 1 "a new run directory (the stand-in compile fails)" WORK="$T/w" TAG=fresh
	[ -f "$T/w/fresh/.step7_run" ] && ok "driver: the new run directory is marked .step7_run" || bad "driver: no .step7_run in a new run directory"
	echo keep > "$T/w/fresh/keep.rbf"
	drv 2 "the same TAG again, without FORCE" WORK="$T/w" TAG=fresh
	[ -f "$T/w/fresh/keep.rbf" ] && ok "driver: its files kept" || bad "driver: its files lost without FORCE"
	drv 1 "the same TAG with FORCE=1 (made by run_step7.sh)" WORK="$T/w" TAG=fresh FORCE=1
	[ ! -f "$T/w/fresh/keep.rbf" ] && [ -f "$T/w/fresh/.step7_run" ] && ok "driver: replaced with FORCE=1" || bad "driver: not replaced with FORCE=1"
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
	PATH="$T/bin:$PATH" QUARTUS_LOCK="$LOCKF" TREE="$ROOT" WORK="$T/w" TAG=viafd DRV="$DRV" LOCKF="$LOCKF" \
		bash -c 'exec 9>"$LOCKF"; flock 9; "$DRV"' > "$T/drv.out" 2>&1
	rc=$?
	[ "$rc" = 1 ] && [ -f "$T/w/viafd/.step7_run" ] && ok "driver: the lock taken on an inherited descriptor (exec 9>lock; flock 9) -> accepted" \
		|| bad "driver: exec 9>lock; flock 9 -> exit $rc: $(tail -1 "$T/drv.out")"
fi

echo "selftest.sh: $npass passed, $nfail failed"
[ "$nfail" = 0 ] && echo "selftest.sh: PASS" || echo "selftest.sh: FAIL"
[ "$nfail" = 0 ]
