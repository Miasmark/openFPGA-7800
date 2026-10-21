#!/bin/bash
# The DARIA status overlay's whole-core check (BUP_DEBUG builds; tb_load.sv's
# overlay block, run_sim.sh's DARIA section) and the faults it must catch.
#   ./run_ovl.sh [control] [MUTANT ...]     (default: control, every mutant)
# control  run_sim.sh's DARIA section alone (ONLY=daria) in a BUP_DEBUG=1
#          DARIA=1 build of this tree, checked by run_sim_check.py --only
#          daria: every run's DARIA result and overlay line pass, and so does
#          the section's "overlay cells:" line.
# MUTANT   the same on a scratch copy of the tree's tracked src/fpga with one
#          fault planted in the RTL (run_sim.sh's RTL_TREE):
#   nodaria    atari7800_pocket.sv: .daria(1'b0); the overlay never draws
#              DARIA's rows, so no cell is read back
#   dstat_lo0  atari7800_pocket.sv: .dstat({daria_dstat[48:12], 12'd0}); the
#              calls' low twelve bits miswired between u_dstat and the overlay
#   xc88       bup_status_osd.sv: the DARIA rows' window ends at x 88, not
#              96; column 11 is never drawn
#   g_locked0  atari7800_pocket.sv: u_dstat's .g_locked(1'b0); the guard bit
#              never set (seen in frame_cdfj_pattern, whose +ovl_guard
#              forces the guard's nets, at VCO/19 too)
#   g_unlock0  atari7800_pocket.sv: u_dstat's .g_unlock(1'b0); no unlock
#              counted (frame_cdfj_pattern's forced pulses)
#   rows9      bup_status_osd.sv: the DARIA rows are 72 lines tall whether
#              halted or not; rows 6-8 drawn while running
# A mutant is CAUGHT when every run's DARIA result still passes (the fault is
# the overlay's alone), the section ends "DARIA FAIL", at least one overlay
# line fails, every overlay line that fails names only terms the mutant can
# reach (TERMS below: cells, coverage and pattern for the first three; the
# guard, unlocks or rows term for the last three; never calls, riot-copy or
# timer, which every mutant leaves alone) and some line names the term the
# mutant is for (KEY below). A build that fails, a run without its lines or a
# DARIA result that fails is an ERROR, not a catch.
# Environment: ARM_DIV (run_sim.sh's; default the benches' 18), WORK
# (default sim/work/bupchip/dstat/ovl), VERILATOR (default
# /opt/verilator-5.040/bin/verilator), VL_JOBS (2). One simulation at a time.
# The log starts with the tree's HEAD and status and the tool (plan P23);
# run_sim.sh prints each binary's md5. Exit status 0 when the control passes
# and every mutant run is CAUGHT, 1 otherwise.
# SPDX-License-Identifier: MIT
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/dstat/ovl}"
export VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
export VL_JOBS="${VL_JOBS:-2}"
MUTANTS="nodaria dstat_lo0 xc88 g_locked0 g_unlock0 rows9"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
WHAT=("$@")
[ ${#WHAT[@]} -gt 0 ] || WHAT=(control $MUTANTS)
for w in "${WHAT[@]}"; do
	[[ " control $MUTANTS " == *" $w "* ]] || { echo "run_ovl.sh: $w: control or one of $MUTANTS" >&2; exit 2; }
done

echo "== run_ovl.sh $(date -u '+%Y-%m-%d %H:%M:%S UTC'): ${WHAT[*]}, ARM_DIV ${ARM_DIV:-18 (default)}"
echo "HEAD $(git -C "$ROOT" rev-parse HEAD)"
echo "status: $(git -C "$ROOT" status --porcelain | wc -l) lines"
git -C "$ROOT" status --porcelain | sed 's/^/  /'
echo "verilator $VERILATOR: $("$VERILATOR" --version)"

# section NAME [RTL_TREE]: the DARIA section alone into $WORK/NAME/run_sim.out
section() {
	local d="$WORK/$1"
	rm -rf "$d"; mkdir -p "$d"
	env WORK="$d" BUP_DEBUG=1 DARIA=1 ONLY=daria ${2:+RTL_TREE="$2"} \
		bash "$ROOT/sim/run_sim.sh" > "$d/run_sim.out" 2>&1
	echo "exit $?" >> "$d/run_sim.out"
	# the binary and the images stay; the build's objects go
	find "$d/obj_load" -type f ! -name vtb -delete 2>/dev/null
}

# mutate NAME DIR: DIR/src/fpga, the tree's tracked files with NAME planted
mutate() {
	rm -rf "$2"; mkdir -p "$2"
	(cd "$ROOT" && git ls-files -z src/fpga | xargs -0 cp -P --parents -t "$2") || return 1
	python3 - "$2/src/fpga/core" "$1" <<-'PY'
	import sys
	core, m = sys.argv[1:]
	M = {
	    "nodaria": ("atari7800_pocket.sv", "\t.daria   (daria_profile),", "\t.daria   (1'b0),"),
	    "dstat_lo0": ("atari7800_pocket.sv", "\t.dstat   (daria_dstat),", "\t.dstat   ({daria_dstat[48:12], 12'd0}),"),
	    "xc88": ("bupchip/bup_status_osd.sv",
	             "wire       in_osd = (dar ? yc < d_lines : en && yc < 7'd104) && !hblank && !vblank && xc < 7'd96;",
	             "wire       in_osd = (dar ? yc < d_lines && xc < 7'd88 : en && yc < 7'd104) && !hblank && !vblank && xc < 7'd96;"),
	    "g_locked0": ("atari7800_pocket.sv", "\t.g_locked  (daria_dbg_locked),", "\t.g_locked  (1'b0),"),
	    "g_unlock0": ("atari7800_pocket.sv", "\t.g_unlock  (daria_dbg_unlock),", "\t.g_unlock  (1'b0),"),
	    "rows9": ("bupchip/bup_status_osd.sv", "wire [6:0] d_lines = st[28] ? 7'd72 : 7'd48;", "wire [6:0] d_lines = 7'd72;"),
	}
	f, a, b = M[m]
	p = core + "/" + f
	s = open(p).read()
	assert s.count(a) == 1, (m, a)
	open(p, "w").write(s.replace(a, b))
	print("planted %s in %s" % (m, f))
	PY
}

ok=1
caught=0
nmut=0
for w in "${WHAT[@]}"; do
	if [ "$w" = control ]; then
		echo "-- control: the DARIA section, BUP_DEBUG build of this tree"
		section control
		grep -E "^(-- built|  [a-z_]+: |    overlay: |    FAIL|  overlay cells:|DARIA (pass|FAIL)|exit )" "$WORK/control/run_sim.out" | cut -c1-400
		if python3 "$ROOT/sim/check/run_sim_check.py" "$WORK/control/run_sim.out" --only daria > "$WORK/control/check.log"; then
			echo "PASS control: $(tail -1 "$WORK/control/check.log") ($WORK/control/run_sim.out)"
		else
			echo "FAIL control ($WORK/control/run_sim.out):"; sed 's/^/  /' "$WORK/control/check.log"; ok=0
		fi
		continue
	fi
	nmut=$((nmut + 1))
	echo "-- mutant $w"
	mt="$WORK/tree_$w"
	if ! mutate "$w" "$mt"; then echo "FAIL mutant $w: ERROR, the scratch tree was not made"; ok=0; continue; fi
	section "mut_$w" "$mt"
	out="$WORK/mut_$w/run_sim.out"
	grep -E "^(-- built|  [a-z_]+: |    overlay: |    FAIL|  overlay cells:|DARIA (pass|FAIL)|exit )" "$out" | cut -c1-400
	v="$(python3 - "$out" "$w" <<-'PY'
	import re, sys
	L = open(sys.argv[1], errors="replace").read().splitlines()
	mut = sys.argv[2]
	READ = {"cells", "coverage", "pattern"}
	TERMS = {"nodaria": READ, "dstat_lo0": READ, "xc88": READ,
	         "g_locked0": {"guard"}, "g_unlock0": {"unlocks"}, "rows9": {"rows"}}[mut]
	KEY = {"nodaria": "coverage", "dstat_lo0": "cells", "xc88": "coverage",
	       "g_locked0": "guard", "g_unlock0": "unlocks", "rows9": "rows"}[mut]
	runs, cur = {}, None
	for l in L:
	    m = re.match(r"^  ([a-z_]+): (.*)$", l)
	    if m and not l.startswith("  overlay cells:"):
	        cur = m.group(1)
	        runs[cur] = {"result": m.group(2), "fail": False, "ovl": None}
	    elif cur and l.startswith("    FAIL: ") and "status overlay" not in l:
	        runs[cur]["fail"] = True
	    elif cur and l.startswith("    overlay: "):
	        runs[cur]["ovl"] = l[13:]
	why = []
	if not any(l.startswith("-- built:") for l in L):
	    why.append("no build")
	if len(runs) != 6:
	    why.append("%d runs, not 6" % len(runs))
	for r, d in runs.items():
	    if d["fail"] or d["result"].startswith("none"):
	        why.append(r + ": its DARIA result fails")
	    if d["ovl"] is None or d["ovl"].startswith("none"):
	        why.append(r + ": no overlay line")
	if why:
	    print("ERROR " + "; ".join(why))
	    sys.exit()
	fails = {}
	for r, d in runs.items():
	    m = re.search(r"; FAIL \(([a-z -]+)\)$", d["ovl"])
	    if m:
	        fails[r] = m.group(1).split()
	named = {t for v in fails.values() for t in v}
	other = sorted(named - TERMS)
	if "DARIA FAIL" not in L:
	    print("NOT CAUGHT: the section does not say DARIA FAIL")
	elif not fails:
	    print("NOT CAUGHT: every overlay line passes")
	elif other:
	    print("ERROR: an overlay line fails on %s, which this mutant leaves alone" % ", ".join(other))
	elif KEY not in named:
	    print("NOT CAUGHT for its reason: no overlay line fails on %s (they fail on %s)" % (KEY, ", ".join(sorted(named))))
	else:
	    print("CAUGHT: " + "; ".join("%s fails on %s" % (r, " ".join(v)) for r, v in fails.items()))
	PY
	)"
	if [[ "$v" == CAUGHT* ]]; then
		echo "PASS mutant $w $v"
		caught=$((caught + 1))
	else
		echo "FAIL mutant $w: $v ($out)"
		ok=0
	fi
	rm -rf "$mt"
done
[ "$nmut" = 0 ] || echo "mutants caught: $caught of $nmut"
[ "$ok" = 1 ] && echo "run_ovl.sh: PASS" || echo "run_ovl.sh: FAIL"
[ "$ok" = 1 ]
