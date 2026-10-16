#!/bin/bash
# bup_dbg_snap.sv (the BUP_DEBUG status word's snapshot, clk_arm -> clk_sys;
# open item 11, docs/daria_step7/plan.md P15 and 3.5 gate 3) on
# tb_dbg_snap.sv, with Verilator 5.040 (set VERILATOR to override).
#   ./run_dbgsnap.sh
# 1. Control, built with --x-initial fast (N = 79, the status word's clk_arm
#    bits; PERIOD = 1,024): clk_arm at VCO/18 on the lattice's three phases
#    (0, 8,730 and 17,460 ps) and at three random phases, and at VCO/19 at a
#    random phase; then PERIOD = 8 (requests back to back) on the three
#    phases and two random ones. Every run must end with errors=0 and every
#    word it asked for.
# 2. Power-up: built with --x-initial unique, run with
#    +verilator+rand+reset+2 and +rand_init (every DUT register random at
#    time 0), seeds 1-5, each on the three phases and a random one.
# 3. Mutations of a copy of bup_dbg_snap.sv, each of which must fail in at
#    least one of four runs (the three phases and a random one): raw (q_sys
#    takes d_arm instead of hold, the raw sampling of open item 11),
#    raw_every_clock, hold_every_clock (the held bus changes under clk_sys),
#    ack_one_flop and req_one_flop (one synchroniser flop), no_wait (q_sys
#    takes hold without waiting for the ack), half_rate (a request every
#    second PERIOD: the bench's rate check). A mutation is caught only by
#    runs that end with their result line and errors > 0. A run that ends
#    without it (a crash, a %Fatal, a timeout after 600 s), exits non-zero,
#    or reports errors=0 with fewer words than asked is an ERROR: the
#    mutation is not counted as caught and the run fails, as wire.py's
#    mutant verdict does.
# Environment: SNAPS (words per control run, 300), WORK (default
# sim/work/bupchip/dbgsnap), MUTATIONS (1; 0 skips them), DBGSNAP_MUTS (the
# mutations to run, default all seven; "fatal", which is not among them, is
# a planted infrastructure failure: a %Fatal at 1 ns, which must give ERROR),
# VERILATOR.
# The log starts with the tree's HEAD and status, the tool and the md5 of
# every binary run (plan P23).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DUT="$ROOT/src/fpga/core/bupchip/bup_dbg_snap.sv"
TB="$HERE/tb_dbg_snap.sv"
WORK="${WORK:-$ROOT/sim/work/bupchip/dbgsnap}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
SNAPS="${SNAPS:-300}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

echo "== run_dbgsnap.sh $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "HEAD $(git -C "$ROOT" rev-parse HEAD)"
echo "status: $(git -C "$ROOT" status --porcelain | wc -l) lines"
git -C "$ROOT" status --porcelain | sed 's/^/  /'
echo "verilator $VERILATOR: $("$VERILATOR" --version)"

build() {	# OBJ DUT_SOURCE XINIT [-G...]
	local obj="$1" src="$2" xi="$3"
	shift 3
	rm -rf "$obj"
	nice -n 10 "$VERILATOR" --binary --timing -j 2 -O3 --x-assign fast --x-initial "$xi" \
		-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD "$@" \
		--top-module tb_dbg_snap -Mdir "$obj" -o vtb "$src" "$TB" > "$obj.log" 2>&1 || return 1
	find "$obj" \( -name '*.gch' -o -name '*.o' \) -delete
	echo "built $obj/vtb md5 $(md5sum < "$obj/vtb" | cut -c1-32) ($xi $*)"
}

field() {	# NAME RESULT
	sed -n "s/.* $1=\([-0-9]*\).*/\1/p" <<< "$2"
}

ok=1
npass=0
nfail=0
run() {	# OBJ NAME SNAPS ARGS...: a run that must pass
	local obj="$1" name="$2" want="$3" res
	shift 3
	nice -n 10 "$obj/vtb" +snaps="$want" "$@" > "$WORK/$name.log" 2>&1 || true
	res="$(grep "^result:" "$WORK/$name.log" || echo "result: none")"
	if [ "$(field errors "$res")" = 0 ] && [ "$(field snaps "$res")" = "$want" ]; then
		echo "PASS $name: ${res#result: }"
		npass=$((npass + 1))
	else
		echo "FAIL $name: $WORK/$name.log"
		grep -m5 "^ERROR" "$WORK/$name.log" | sed 's/^/  /'
		nfail=$((nfail + 1))
		ok=0
	fi
}

PHASES="0 8730 17460"
build "$WORK/obj_fast" "$DUT" fast || { echo "build failed: $WORK/obj_fast.log" >&2; exit 1; }
build "$WORK/obj_p8" "$DUT" fast -GPERIOD=8 || { echo "build failed: $WORK/obj_p8.log" >&2; exit 1; }
build "$WORK/obj_unique" "$DUT" unique || { echo "build failed: $WORK/obj_unique.log" >&2; exit 1; }

echo "-- 1. control"
for p in $PHASES; do run "$WORK/obj_fast" "d18_p$p" "$SNAPS" +phase="$p"; done
for s in 1 2 3; do run "$WORK/obj_fast" "d18_rnd_s$s" "$SNAPS" +phase=-1 +seed="$s"; done
run "$WORK/obj_fast" "d19_rnd_s1" "$SNAPS" +div=19 +phase=-1 +seed=1
for p in $PHASES; do run "$WORK/obj_p8" "p8_d18_p$p" 3000 +phase="$p"; done
for s in 1 2; do run "$WORK/obj_p8" "p8_d18_rnd_s$s" 3000 +phase=-1 +seed="$s"; done

echo "-- 2. power-up: --x-initial unique, +verilator+rand+reset+2, +rand_init"
for s in 1 2 3 4 5; do
	for p in $PHASES -1; do
		run "$WORK/obj_unique" "pu_s${s}_p$p" 100 +phase="$p" +seed="$s" +rand_init \
			+verilator+rand+reset+2 +verilator+seed+"$s"
	done
done

if [ "${MUTATIONS:-1}" = 1 ]; then
	echo "-- 3. mutations (each must fail in at least one run)"
	MW="$WORK/mut"
	mkdir -p "$MW"
	MUTS="${DBGSNAP_MUTS:-raw raw_every_clock hold_every_clock ack_one_flop req_one_flop no_wait half_rate}"
	caught=0
	total=0
	for m in $MUTS; do
		total=$((total + 1))
		python3 - "$DUT" "$MW/$m.sv" "$m" <<'PY'
import sys
src, dst, m = sys.argv[1:]
s = open(src).read()
M = {
	# q_sys samples the clk_arm word itself: open item 11's raw crossing.
	"raw": [("\t\t\tq_sys <= hold;\n", "\t\t\tq_sys <= d_arm;\n")],
	# q_sys samples the clk_arm word on every clk_sys edge.
	"raw_every_clock": [("\t\tif (take) begin\n\t\t\tq_sys <= hold;\n", "\t\tq_sys <= d_arm;\n\t\tif (take) begin\n")],
	# hold follows d_arm on every clk_arm edge: the held bus moves under clk_sys.
	"hold_every_clock": [("\t\tif (rq_s1 != ack) begin\n\t\t\thold <= d_arm;\n", "\t\thold <= d_arm;\n\t\tif (rq_s1 != ack) begin\n")],
	# The ack is used from the first synchroniser flop.
	"ack_one_flop": [("wire take    = waiting && ak_s1 == req;", "wire take    = waiting && ak_s0 == req;")],
	# The request is used from the first synchroniser flop.
	"req_one_flop": [("\t\tif (rq_s1 != ack) begin\n\t\t\thold <= d_arm;\n\t\t\tack <= rq_s1;\n",
	"\t\tif (rq_s0 != ack) begin\n\t\t\thold <= d_arm;\n\t\t\tack <= rq_s0;\n")],
	# q_sys takes hold as soon as it has asked, before the copy.
	"no_wait": [("wire take    = waiting && ak_s1 == req;", "wire take    = waiting;")],
	# A request every second PERIOD: every word still whole, but half as often.
	"half_rate": [("\tlogic          seen = 1'b0;", "\tlogic          half = 1'b0;\n\tlogic          seen = 1'b0;"),
	              ("\t\tif (!waiting && cnt == CW'(PERIOD - 1))\n\t\t\treq <= ~req;\n",
	               "\t\tif (cnt == CW'(PERIOD - 1)) half <= ~half;\n\t\tif (!waiting && cnt == CW'(PERIOD - 1) && half)\n\t\t\treq <= ~req;\n")],
	# Not a mutation of the design: a planted infrastructure failure (a %Fatal at 1 ns, no result line),
	# which the verdict must report as an ERROR, never as caught (DBGSNAP_MUTS=fatal).
	"fatal": [("\nendmodule", "\n\tinitial #1000 $fatal(1, \"planted: run_dbgsnap.sh's fatal\");\nendmodule")],
}
for a, b in M[m]:
	assert s.count(a) == 1, (m, a)
	s = s.replace(a, b)
open(dst, "w").write(s)
PY
		if ! build "$MW/obj_$m" "$MW/$m.sv" fast > /dev/null; then
			echo "FAIL mutation $m: build failed ($MW/obj_$m.log)"
			ok=0
			continue
		fi
		why=""
		err=""
		for p in $PHASES -1; do
			rc=0
			timeout 600 nice -n 10 "$MW/obj_$m/vtb" +snaps=60 +phase="$p" +seed=1 > "$MW/${m}_p$p.log" 2>&1 || rc=$?
			res="$(grep "^result:" "$MW/${m}_p$p.log" || true)"
			e="$(field errors "$res")"
			if [ -z "$res" ] || [ -z "$e" ]; then
				err="$err p$p: no result line (exit $rc)"
			elif [ "$rc" != 0 ] || grep -q '%Fatal\|%Error' "$MW/${m}_p$p.log"; then
				err="$err p$p: exit $rc$(grep -m1 -o '%Fatal.*\|%Error.*' "$MW/${m}_p$p.log" | cut -c1-60 | sed 's/^/, /')"
			elif [ "$e" != 0 ]; then
				why="$why p$p:errors=$e"
			elif [ "$(field snaps "$res")" != 60 ]; then
				err="$err p$p: errors=0 with snaps=$(field snaps "$res") (60 asked)"
			fi
		done
		if [ -n "$err" ]; then
			echo "FAIL mutation $m: ERROR, not counted as caught:$err ($MW/${m}_p*.log)"
			ok=0
		elif [ -n "$why" ]; then
			echo "PASS mutation $m caught:$why; first: $(grep -h -m1 '^ERROR' "$MW/${m}"_p*.log | head -1 | cut -c1-110)"
			caught=$((caught + 1))
		else
			echo "FAIL mutation $m not caught"
			ok=0
		fi
		rm -rf "$MW/obj_$m"
	done
	echo "mutations caught: $caught of $total"
fi
echo "runs: $npass passed, $nfail failed"
[ "$ok" = 1 ] && echo "run_dbgsnap.sh: PASS" || echo "run_dbgsnap.sh: FAIL"
[ "$ok" = 1 ]
