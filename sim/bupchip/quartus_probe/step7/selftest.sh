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
W(os.path.join(fpga, "step7_prep.txt"), f"kind {kind}\ndaria {int(kind in ('daria', 'q5'))}\nbup_debug {int(kind == 'q5')}\n"
  f"fixb {int(kind != 'base')}\ndiv 18\nseed 2\npin_id 0\noldpad 0\n")
ids = ["l.clocks", "l", "gate.clk_sdram", "gate.clk_arm", "gate.hold", "a", "b", "d", "c.cells", "e.files", "f.files",
       "g", "g.legs", "h", "i", "j", "k", "k'.files", "k'.fanin", "sdram.files", "p", "o.files"]
info = {"d", "e.files", "f.files", "i", "k'.files", "k'.fanin", "sdram.files", "p", "o.files"}
checks = [f"CHECK {i} {'INFO' if i in info else 'PASS'}: made up" for i in ids]
if kind == "base":
    checks = [c.replace("CHECK g PASS", "CHECK g FAIL") for c in checks]
for c in changes:
    if c.startswith("drop="):
        gone = c[5:].split(",")
        checks = [x for x in checks if x.split()[1] not in gone]
    if c == "ab_error":
        checks = [x for x in checks if x.split()[1] not in ("a", "b", "d")] + ["CHECK ab FAIL: Tcl error in the report script: made up"]
end = "noend" not in changes
W(os.path.join(fpga, "checks.txt"), "# step7_report.tcl: kind made up\n" + "\n".join(checks) + "\n"
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
