#!/bin/bash
# The step-7 report's smoke test on a small fitted design (smoke.sv; plan
# docs/daria_step7/plan.md 3.5, 5.4 (c), (f), (k), (k')): core/daria.qip's
# synchroniser marks (the instance assignments of core/daria_sync.tcl, which
# it sources), step7_report.tcl and step7_checks.py on a netlist whose names
# are the core's, four levels deep, without a 13-minute fit of the core.
# Five projects, each compiled (quartus_map, quartus_fit) and then
# reported (quartus_sta -t step7_report.tcl, step7_checks.py), and two
# reported again on one of them with its SDC edited (quartus_sta only):
#   allmarks_qip every register daria.qip marks is present (SMOKE_Q5: since
#                the marks without a chain in any build went, the design is
#                q5_clean's), with QIP_FILE daria.qip: each of the 13 must
#                head a chain whose "Method of Synchronizer Identification" is
#                "User Specified", no mark may be reported ignored, and the
#                compile may report no error or warning about them
#   allmarks_noqip the same without daria.qip: none of the 13 is "User
#                Specified" (each is "Automatic" or not a chain), so the marks
#                above come from the qip
#   q5_clean     a Q5 build (SMOKE_Q5) with daria.qip: (c.cells), (f), (k),
#                (k') and (report) PASS; ram32_a[0]'s fan-in has a logic level
#                (an explicit NOT) and still passes
#   q5_mut       SMOKE_MUT, with daria_sync.tcl less its ftog_s line: (k') FAILs
#                on exactly prof_a[0] (two registers), ready_s[0] (the ready_a
#                bypass) and run_s[0] (a register of its own clock), and on
#                the raw endpoint; (f) FAILs on exactly ftog_s[0]
#   q5_g1        q5_clean with the copy of daria_constraints.sdc set to G1
#                (the guard pair at [0.500, 8.000] ns, fitter 7.500; plan 5.4
#                as amended for G1, 2026-10-19, in docs/daria_step10/plan.md
#                section 10), whatever the tree's SDC says:
#                the report script reads G1's bounds from sdc.rpt, (a) and (b)
#                list one path at 8.000 / 0.500 ns at every corner, (k) PASSes
#                at G1's bounds, (e) lists G1's pair Complete and the fitter's
#                7.500, and step7_checks.py reads (a), (b), (k) as the report
#                script did (no misread)
#   q5_g1_nopair q5_g1's database, quartus_sta only, the two Timing Analyzer
#                lines of the guard pair removed from the SDC (Q-mut's "guard
#                pair removed", plan 7.2, under G1): no bounds in sdc.rpt, the
#                path at the +-20 ns clock bound; (a), (b), (k), (e) FAIL
#   q5_g1_odd    the same with the pair at [0.700, 7.300] ns, a pair the
#                report script's table does not hold: (a), (b), (k), (e) FAIL
# q5_clean must read a known pair from the tree's own SDC.
# Run it under the machine's Quartus lock, as run_step7.sh:
#   QUARTUS_LOCK=<the lock file> flock <the lock file> sim/bupchip/quartus_probe/step7/smoke/run_smoke.sh
# Environment: WORK (default sim/work/step7/smoke), IMAGE (raetro/quartus:21.1),
# ONLY="name ..." (some of the seven), CHECK_ONLY=1 (no Quartus: step7_checks.py
# and the assertions again on WORK's last results), REPORT_ONLY=1 (no compile:
# quartus_sta -t step7_report.tcl again on WORK's fitted projects, then the
# checks; under the lock), QUARTUS_LOCK.
# About 35 s a fitted project and 3 s a quartus_sta run, about 3 minutes for all seven [measured
# 2026-10-19 at b55b4b3]. The log starts with the tree's HEAD and status,
# the tool and the md5 of every script (plan P23). Exit 0 when every
# assertion holds.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
S7="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
CORE="$ROOT/src/fpga/core"
WORK="$(realpath -m "${WORK:-$ROOT/sim/work/step7/smoke}")"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
LOCK="${QUARTUS_LOCK:-}"
ALL="allmarks_qip allmarks_noqip q5_clean q5_mut q5_g1 q5_g1_nopair q5_g1_odd"
ONLY="${ONLY:-$ALL}"
die() { echo "run_smoke.sh: $*" >&2; exit 2; }
case "$WORK/" in
	*/sim/work/bupchip/fullprobe/*|*/sim/work/step7/ref/*) die "WORK=$WORK is protected (run_step7.sh)" ;;
esac

echo "== run_smoke.sh $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "HEAD $(git -C "$ROOT" rev-parse HEAD); status $(git -C "$ROOT" status --porcelain | wc -l) lines"
git -C "$ROOT" status --porcelain | sed 's/^/  /'
echo "image $IMAGE $(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)"
echo "md5: $( (cd "$S7" && md5sum smoke/smoke.sv smoke/run_smoke.sh step7_report.tcl step7_checks.py step7_lock.sh f3_crossings.txt;
	cd "$CORE" && md5sum daria.qip daria_sync.tcl daria_constraints.sdc bupchip/daria_fe_guard.sv bupchip/bup_dbg_snap.sv) | awk '{printf "%s %s; ", $2, substr($1,1,12)}')"

if [ "${CHECK_ONLY:-0}" = 0 ]; then
	[ -n "$LOCK" ] || die "QUARTUS_LOCK is not set"
	[ -f "$LOCK" ] || die "QUARTUS_LOCK=$LOCK does not exist"
	flock -n "$LOCK" true 2>/dev/null && die "the Quartus lock is free: run me under flock \"\$QUARTUS_LOCK\""
	. "$S7/step7_lock.sh"
	lock_by_ancestor || die "run me under the Quartus lock myself"
	avail=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
	[ "$avail" -ge 2048 ] || die "only ${avail} MB free on /"
fi

project() {	# NAME MACROS... : the project directory WORK/NAME/fpga
	local name="$1" d="$WORK/$1/fpga"
	shift
	rm -rf -- "${WORK:?}/$name"
	mkdir -p "$d"
	cp "$HERE/smoke.sv" "$CORE/bupchip/daria_fe_guard.sv" "$CORE/bupchip/bup_dbg_snap.sv" "$CORE/daria_constraints.sdc" "$d/"
	cp "$S7/step7_report.tcl" "$d/"
	cat > "$d/clocks.sdc" <<-'EOF'
	# The PLL's four clocks under core_constraints.sdc's names, on ports.
	create_clock -name {ic|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk} -period 69.841 [get_ports clk_sys]
	create_clock -name {ic|pll|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk} -period 17.460 [get_ports clk_sdram]
	create_clock -name {ic|pll|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk} -period 69.841 -waveform {17.460 52.380} [get_ports clk_sys_90]
	create_clock -name {ic|pll|altera_pll_i|cyclonev_pll|counter[3].output_counter|divclk} -period 26.190 [get_ports clk_arm]
	EOF
	{
		echo 'set_global_assignment -name FAMILY "Cyclone V"'
		echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
		echo 'set_global_assignment -name TOP_LEVEL_ENTITY ap_core'
		echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
		echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 2'
		for m in "$@"; do echo "set_global_assignment -name VERILOG_MACRO \"$m=1\""; done
		echo 'set_global_assignment -name SYSTEMVERILOG_FILE smoke.sv'
		echo 'set_global_assignment -name SYSTEMVERILOG_FILE daria_fe_guard.sv'
		echo 'set_global_assignment -name SYSTEMVERILOG_FILE bup_dbg_snap.sv'
		echo 'set_global_assignment -name SDC_FILE clocks.sdc'
		[ -z "$QIP" ] || echo 'set_global_assignment -name QIP_FILE daria.qip'
		echo 'set_global_assignment -name SDC_FILE daria_constraints.sdc'
	} > "$d/ap_core.qsf"
	echo "PROJECT_REVISION = \"ap_core\"" > "$d/ap_core.qpf"
	[ -z "$QIP" ] || cp "$CORE/daria.qip" "$d/daria.qip"
	[ -z "$QIP" ] || cp "$QIP" "$d/daria_sync.tcl"	# the marks daria.qip sources
	printf 'kind q5\ndaria 1\nbup_debug 1\nfixb 0\ndiv 18\nseed -\npin_id 0\noldpad 0\n' > "$d/step7_prep.txt"
}

guard_sdc() {	# FILE MODE: the guard pair in a copy of daria_constraints.sdc set to G1's bounds (g1), its two
	# Timing Analyzer lines removed (nopair), or set to a pair no table holds (odd)
	python3 - "$1" "$2" <<'PY'
import re, sys
p, mode = sys.argv[1], sys.argv[2]
t = open(p).read()
cmd = re.compile(r"(?m)^([ \t]*)set_(max|min)_delay -from \[get_registers -nowarn \{\*\|daria_fe_guard:u_guard\|pd_tog\}\] \\\n"
                 r"[ \t]+-to +\[get_registers -nowarn \{\*\|daria_fe_guard:u_guard\|pd_rx\}\] (\S+)\n")
val = {"g1": {"max": "8.000", "min": "0.500", "fit": "7.500"}, "odd": {"max": "7.300", "min": "0.700"}, "nopair": {}}[mode]
done = []
def sub(m):
    key = "fit" if m.group(1) else m.group(2)       # the quartus_fit block's line is indented
    if mode == "nopair" and key != "fit":
        done.append(key)
        return ""
    if key in val:
        done.append(key)
        return m.group(0)[:m.start(3) - m.start(0)] + val[key] + "\n"
    return m.group(0)
t = cmd.sub(sub, t)
need = {"g1": ["fit", "max", "min"], "odd": ["max", "min"], "nopair": ["max", "min"]}[mode]
if sorted(done) != need:
    sys.exit(f"guard_sdc {mode}: changed {sorted(done)}, expected {need} ({p})")
open(p, "w").write(t)
print(f"   {p.split('/')[-3]}: the guard pair in daria_constraints.sdc: {mode} ({', '.join(sorted(done))})")
PY
}

variant() {	# NAME MODE: q5_g1's fitted project again, quartus_sta only, with the guard pair of its SDC edited
	local d="$WORK/$1"
	[ -d "$WORK/q5_g1/fpga/db" ] || die "$1 needs q5_g1's fitted project (its database): run q5_g1 first"
	rm -rf -- "${WORK:?}/$1"
	mkdir -p "$d"
	cp -a "$WORK/q5_g1/fpga" "$d/fpga"
	cp "$WORK/q5_g1/quartus.log" "$d/quartus.log"
	rm -f "$d/fpga/checks.txt" "$d/fpga/crossings.tsv" "$d/fpga/fanin.tsv" "$d/fpga/report_rc.txt" "$d/fpga/sdc.rpt" "$d/fpga/exceptions.rpt"
	cp "$S7/step7_report.tcl" "$d/fpga/"
	guard_sdc "$d/fpga/daria_constraints.sdc" "$2" || die "cannot edit $1's copy of daria_constraints.sdc"
	echo "-- $1: quartus_sta -t step7_report.tcl on q5_g1's database ($(date -u '+%H:%M:%S UTC'))"
	set +e
	docker run --rm -v "$d:/w" -w /w/fpga "$IMAGE" quartus_sta -t step7_report.tcl > "$d/report.log" 2>&1
	echo $? > "$d/fpga/report_rc.txt"
	set -e
	echo "   quartus_sta exit $(cat "$d/fpga/report_rc.txt")"
}

compile() {	# NAME
	local d="$WORK/$1" rc=0
	echo "-- $1: quartus_map, quartus_fit, quartus_sta -t step7_report.tcl ($(date -u '+%H:%M:%S UTC'))"
	set +e
	if [ "${REPORT_ONLY:-0}" = 0 ]; then
		docker run --rm -v "$d:/w" -w /w/fpga "$IMAGE" bash -c "quartus_sh --version | head -2 && quartus_map ap_core && quartus_fit ap_core" > "$d/quartus.log" 2>&1
		rc=$?
	else
		cp "$S7/step7_report.tcl" "$d/fpga/"
		rm -f "$d/fpga/checks.txt" "$d/fpga/crossings.tsv" "$d/fpga/fanin.tsv" "$d/fpga/report_rc.txt"
	fi
	docker run --rm -v "$d:/w" -w /w/fpga "$IMAGE" quartus_sta -t step7_report.tcl > "$d/report.log" 2>&1
	echo $? > "$d/fpga/report_rc.txt"
	set -e
	echo "   compile exit $rc, quartus_sta exit $(cat "$d/fpga/report_rc.txt")"
	grep -m1 "Version" "$d/quartus.log" | sed 's/^ */   /'
	[ "$rc" = 0 ] || { echo "   compile FAILED: $d/quartus.log"; grep -m5 "^Error" "$d/quartus.log" | sed 's/^/   /'; }
}

mkdir -p "$WORK"
if [ "${CHECK_ONLY:-0}" = 0 ]; then
	QIPMUT="$WORK/daria_sync_minus_ftog.tcl"
	grep -v 'ftog_s' "$CORE/daria_sync.tcl" > "$QIPMUT"
	[ "$(diff "$CORE/daria_sync.tcl" "$QIPMUT" | grep -c '^<')" = 1 ] || die "daria_sync.tcl has no single ftog_s line to remove"
	for n in $ONLY; do
		case "$n" in q5_g1_nopair|q5_g1_odd) variant "$n" "${n#q5_g1_}"; continue ;; esac
		[ "${REPORT_ONLY:-0}" = 0 ] || { [ -d "$WORK/$n/fpga/db" ] || die "REPORT_ONLY: $WORK/$n has no database"; compile "$n"; continue; }
		case "$n" in
			allmarks_qip)   QIP="$CORE/daria_sync.tcl" project "$n" SMOKE_Q5 ;;
			allmarks_noqip) QIP=""                project "$n" SMOKE_Q5 ;;
			q5_clean)    QIP="$CORE/daria_sync.tcl" project "$n" SMOKE_Q5 ;;
			q5_mut)      QIP="$QIPMUT"         project "$n" SMOKE_Q5 SMOKE_MUT ;;
			q5_g1)       QIP="$CORE/daria_sync.tcl" project "$n" SMOKE_Q5
			             guard_sdc "$WORK/$n/fpga/daria_constraints.sdc" g1 || die "cannot set G1 in $n's copy of daria_constraints.sdc" ;;
			*) die "unknown project $n" ;;
		esac
		compile "$n"
	done
fi

# ---- the checks and the assertions -----------------------------------------------------------------------
for n in $ONLY; do
	python3 "$S7/step7_checks.py" "$WORK/$n" > "$WORK/$n/summary.txt" 2>&1 || true
done
python3 - "$WORK" "$CORE/daria_sync.tcl" "$ONLY" <<'PY'
import os, re, sys
work, qip, only = sys.argv[1], sys.argv[2], sys.argv[3].split()
ok = True

def say(good, text):
    global ok
    ok &= good
    print(("PASS " if good else "FAIL ") + text)

def rd(p):
    try:
        return open(p, encoding="latin-1").read()
    except FileNotFoundError:
        return ""

def glob_re(pat):
    return re.compile("^" + ".*".join(re.escape(p) for p in pat.split("*")) + "$")

marks = [m.replace("\\[", "[").replace("\\]", "]") for m in
         re.findall(r'(?m)^set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "([^"]+)"', rd(qip))]
say(len(marks) == 13, f"daria_sync.tcl marks {len(marks)} registers (13 expected)")

def chains(n):
    out = {}
    for b in re.split(r"(?m)^Synchronizer Chain #\d+:", rd(os.path.join(work, n, "fpga", "metastability.rpt")))[1:]:
        m = re.search(r";\s*Synchronization Node\s*;\s*([^;]+?)\s*;", b)
        k = re.search(r";\s*Method of Synchronizer Identification\s*;\s*([^;]+?)\s*;", b)
        if m:
            out[m.group(1)] = k.group(1) if k else "?"
    return out

def results(n):
    r = {}
    for line in rd(os.path.join(work, n, "summary.txt")).splitlines():
        m = re.match(r"\s*\((\S+)\) (PASS|FAIL|INFO) \[[^]]*\] (.*)", line)
        if m:
            r.setdefault(m.group(1), []).append((m.group(2), m.group(3)))
    return r

def verdict(r, cid):
    v = [x for x, _ in r.get(cid, [])]
    return "FAIL" if "FAIL" in v else (v[0] if v else "missing")

def text(r, cid):
    return " ".join(t for _, t in r.get(cid, []))

def ignored(n):
    """Lines that report a mark (daria.qip, daria_sync.tcl) ignored or matching nothing."""
    d = os.path.join(work, n)
    hits = []
    for p in (os.path.join(d, "quartus.log"), os.path.join(d, "fpga", "output_files", "ap_core.map.rpt"),
              os.path.join(d, "fpga", "output_files", "ap_core.fit.rpt")):
        for line in rd(p).splitlines():
            if re.search(r"SYNCHRONIZER|Synchronizer Identification", line, re.I) and re.search(r"ignor|not found|does not exist|invalid", line, re.I):
                hits.append(os.path.basename(p) + ": " + line.strip()[:160])
    # The "Ignored Assignments" tables of the map and fit reports
    for p in (os.path.join(d, "fpga", "output_files", "ap_core.map.rpt"), os.path.join(d, "fpga", "output_files", "ap_core.fit.rpt")):
        s = rd(p)
        for m in re.finditer(r"; Ignored Assignments[^\n]*\n(.*?)\n\n", s, re.S):
            for line in m.group(1).splitlines():
                if re.search(r"Synchroni", line, re.I):
                    hits.append(os.path.basename(p) + " Ignored Assignments: " + line.strip()[:160])
    return hits

if "allmarks_qip" in only:
    c = chains("allmarks_qip")
    print(f"-- allmarks_qip: {len(c)} synchroniser chains")
    for m in marks:
        how = [h for node, h in c.items() if glob_re(m).match(node)]
        say(bool(how) and all(h.lower().startswith("user") for h in how), f"allmarks_qip: {m} -> {how or 'no chain'}")
    ig = ignored("allmarks_qip")
    err = [l.strip()[:200] for l in rd(os.path.join(work, "allmarks_qip", "quartus.log")).splitlines()
           if re.search(r"^(Error|Critical Warning|Warning)", l.strip()) and re.search(r"daria|qip|SYNCHRONIZER|125091", l, re.I)
           and "daria_fe_guard.sv" not in l]
    say(not ig and not err, f"allmarks_qip: no mark ignored and no error or warning about daria.qip, daria_sync.tcl or the marks "
        f"({(ig + err)[:4] or 'none'})")
if "allmarks_noqip" in only:
    c = chains("allmarks_noqip")
    print(f"-- allmarks_noqip: {len(c)} synchroniser chains")
    for m in marks:
        how = [h for node, h in c.items() if glob_re(m).match(node)]
        say(not any(h.lower().startswith("user") for h in how), f"allmarks_noqip: {m} -> {how or 'no chain'} (not User Specified)")
def checks_txt(n):
    return rd(os.path.join(work, n, "fpga", "checks.txt"))

def bounds_line(n):
    m = re.search(r"(?m)^# guard bounds: (.*)$", checks_txt(n))
    return m.group(1) if m else "(no line)"

def pair_rels(n, which):
    """the relationships, path counts and corners of the guard pair's per-corner lines in checks.txt"""
    rels, ks, cs, in_ab = set(), set(), 0, False
    for line in checks_txt(n).splitlines():
        if line.startswith("## "):
            in_ab = line.startswith("## (a) (b) (d)")
            continue
        m = re.match(r"  (\S+) (setup|hold): (\d+) path\(s\);(.*)$", line)
        if in_ab and m and m.group(2) == which:
            cs += 1
            ks.add(int(m.group(3)))
            rels |= set(re.findall(r" rel (\S+) slack", m.group(4)))
    return sorted(rels), sorted(ks), cs

if "q5_clean" in only:
    r = results("q5_clean")
    print("-- q5_clean")
    bl = bounds_line("q5_clean")
    say(re.match(r"setup \S+ hold \S+ \(\w+;", bl) is not None, f"q5_clean: the report script read a known pair from the tree's SDC: {bl[:200]}")
    for cid in ("report", "c.cells", "f", "k", "k'"):
        say(verdict(r, cid) == "PASS", f"q5_clean: ({cid}) {verdict(r, cid)}: {text(r, cid)[:600]}")
    lv = re.search(r"logic levels on a one-register fan-in \(not judged\): (.*?); sources named", text(r, "k'"))
    lv = lv.group(1) if lv else ""
    say("ram32_a[0]" in lv, f"q5_clean: (k') passed first flops with a logic level: {lv}")
if "q5_mut" in only:
    r = results("q5_mut")
    print("-- q5_mut")
    t = text(r, "k'")
    kv = verdict(r, "k'")
    say(kv == "FAIL", f"q5_mut: (k') {kv}")
    wrong = re.search(r"first flops wrong: (.*?); logic levels", t)
    wrong = wrong.group(1) if wrong else ""
    named = sorted(re.findall(r"\|(\w+(?:\[\d+\])?): fan-in", wrong))
    other = re.findall(r"no such cell|no clk_sys", wrong)
    say(named == ["prof_a[0]", "ready_s[0]", "run_s[0]"] and not other,
        f"q5_mut: (k') first flops wrong are exactly prof_a[0], ready_s[0], run_s[0]: {named}; {wrong[:900]}")
    ue = re.search(r"unexpected endpoints: (\d+) (\[.*?\])", t)
    say(ue is not None and ue.group(1) == "1" and "|raw <- " in ue.group(2),
        f"q5_mut: (k') the one unexpected endpoint is the raw crossing: {ue.group(0) if ue else t[:200]}")
    tf = text(r, "f")
    auto = re.search(r"identified automatically, not Forced: (.*?); other Forced", tf)
    miss = re.search(r"first flops with no chain: (.*?); identified", tf)
    flagged = (auto.group(1) if auto else "") + " " + (miss.group(1) if miss else "")
    # each entry is a pattern, "...|<register> (<how>)" or "...|<register>": its last component
    others = re.findall(r"\|(\w+(?:\[\d+\])?)(?= \(|'|\])", flagged)
    say(verdict(r, "f") == "FAIL" and others == ["ftog_s[0]"],
        f"q5_mut: (f) FAILs on exactly ftog_s[0] (its line removed from daria_sync.tcl): {flagged.strip()}")
if "q5_g1" in only:
    r = results("q5_g1")
    print("-- q5_g1 (the guard pair at G1's [0.500, 8.000] ns, fitter 7.500)")
    bl = bounds_line("q5_g1")
    say(bl.startswith("setup 8.000 hold 0.500 (G1;"), f"q5_g1: the report script read G1's bounds from sdc.rpt: {bl[:200]}")
    for which, want in (("setup", "8.000"), ("hold", "0.500")):
        rels, ks, cs = pair_rels("q5_g1", which)
        say(rels == [want] and ks == [1] and cs == 4,
            f"q5_g1: one {which} path pd_tog -> pd_rx at each of 4 corners, relationship {want}: {rels}, paths {ks}, {cs} corners")
    say(verdict(r, "k") == "PASS" and "8.000 / 0.500" in text(r, "k"), f"q5_g1: (k) {verdict(r, 'k')}: {text(r, 'k')[:400]}")
    te = text(r, "e")
    say(all(x in te for x in ("set_max_delay pd_tog->pd_rx 8.000: Complete", "set_min_delay pd_tog->pd_rx 0.500: Complete",
                              "fitter-only line: 7.500 ns (the pair's own)")),
        f"q5_g1: (e) lists G1's pair Complete and the fitter's 7.500 ((e) {verdict(r, 'e')}): {te[:600]}")
    say(not any(x in text(r, c) for c in ("a", "b", "k") for x in ("misread", "but sdc.rpt gives")),
        "q5_g1: step7_checks.py reads (a), (b) and (k) as the report script judged them")
    say(verdict(r, "report") == "PASS", f"q5_g1: (report) {verdict(r, 'report')}")
    for c in ("a", "b"):
        print(f"   q5_g1: ({c}) {verdict(r, c)} (information: the smoke design's slack): {text(r, c)[:300]}")
for n, why, want in (("q5_g1_nopair", "sdc.rpt has 0 set_max_delay and 0 set_min_delay", ("20.000", "-20.000")),
                     ("q5_g1_odd", "is not one of the known pairs", ("7.300", "0.700"))):
    if n not in only:
        continue
    r = results(n)
    print(f"-- {n}")
    bl = bounds_line(n)
    say(bl.startswith("none") and why in bl, f"{n}: the report script read no known bounds: {bl[:240]}")
    for which, w in zip(("setup", "hold"), want):
        rels, ks, cs = pair_rels(n, which)
        say(rels == [w] and ks == [1] and cs == 4, f"{n}: one {which} path pd_tog -> pd_rx at each corner, at {w} ns as the SDC now has it: "
            f"{rels}, paths {ks}, {cs} corners")
    for c in ("a", "b", "k", "e"):
        say(verdict(r, c) == "FAIL" and why in text(r, c), f"{n}: ({c}) {verdict(r, c)} on the bounds: {text(r, c)[:300]}")
    say(not any("misread" in text(r, c) for c in ("a", "b", "k")), f"{n}: no misread of (a), (b), (k)")
print("run_smoke.sh: " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
