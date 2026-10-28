#!/bin/bash
# daria_dbg_status (the DARIA status overlay's counts; bup_status_osd.sv,
# BUP_DEBUG and POCKET_DARIA) on tb_dstat.sv, against upstream's RIOT
# (M6532.sv) and tb_frames' late-call rule, with Verilator 5.040 (set
# VERILATOR to override).
#   ./run_dstat.sh
# 1. Control: seeds 1-4, CYCLES bus cycles each (1,500,000). Each run must end
#    with errors=0, and with every coverage bin of its "coverage:" line above
#    0: calls, late and on-time polls, timer writes on the old timer's wrap,
#    INTIM reads in a rollover, polls on the wrap's own clock, and resets (a
#    seed that misses one has not exercised that rule).
# 2. Mutations of a copy of bup_status_osd.sv, each of which must give
#    errors > 0 on seed 1: intim_keeps_rollover (an INTIM read leaves the
#    rollover), late_at_call_end (the timer judged when the call ends, not at
#    the 6507's next timer read: plan 6.2 question 5's warning), no_armed (a
#    timer written after the call still counts), write_clears_wrap (a write
#    on the old timer's wrap clears the expiry), no_a12 (A12 = 1 selects the
#    RIOT), prescale64 (the /64 prescaler a bit short). A run that ends
#    without its result line or exits non-zero is an ERROR, not a catch.
# Environment: CYCLES, WORK (default sim/work/bupchip/dstat), MUTATIONS (1;
# 0 skips them), VERILATOR. The log starts with the tree's HEAD and status,
# the tool and the md5 of every binary run (plan P23).
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RTL="$ROOT/src/fpga/mister/rtl"
DUT="$ROOT/src/fpga/core/bupchip/bup_status_osd.sv"
TB="$HERE/tb_dstat.sv"
WORK="${WORK:-$ROOT/sim/work/bupchip/dstat}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
CYCLES="${CYCLES:-1500000}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

echo "== run_dstat.sh $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "HEAD $(git -C "$ROOT" rev-parse HEAD)"
echo "status: $(git -C "$ROOT" status --porcelain | wc -l) lines"
git -C "$ROOT" status --porcelain | sed 's/^/  /'
echo "verilator $VERILATOR: $("$VERILATOR" --version)"

# Verilator 5.040 rejects M6532.sv's initialised unpacked wire; a copy with
# it as logic, as run_sim.sh simulates it
sed -E 's/^(\s*)wire(\s+\[[^]]+\]\s+\w+\s*\[[0-9]+\]\s*=)/\1logic\2/' "$RTL/RIOT/M6532.sv" > "$WORK/M6532.sv"

build() {	# OBJ DUT_SOURCE
	local obj="$1" src="$2"
	rm -rf "$obj"
	nice -n 10 "$VERILATOR" --binary --timing --verilate-jobs 1 --build-jobs 2 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		-DBUP_DEBUG -DPOCKET_DARIA --top-module tb_dstat -Mdir "$obj" -o vtb \
		"$RTL/cache_ram.v" "$WORK/M6532.sv" "$src" "$TB" > "$obj.log" 2>&1 || return 1
	find "$obj" -type f ! -name vtb -delete
	echo "built $obj/vtb md5 $(md5sum < "$obj/vtb" | cut -c1-32)"
}

field() {	# NAME RESULT
	sed -n "s/.* $1=\([-0-9]*\).*/\1/p" <<< "$2"
}

ok=1
build "$WORK/obj" "$DUT" || { echo "build failed: $WORK/obj.log" >&2; exit 1; }
echo "-- 1. control"
for s in 1 2 3 4; do
	nice -n 10 "$WORK/obj/vtb" +seed="$s" +cycles="$CYCLES" > "$WORK/s$s.log" 2>&1 || true
	res="$(grep "^result:" "$WORK/s$s.log" || echo "result: none")"
	cov="$(grep "^coverage:" "$WORK/s$s.log" || echo "coverage: none")"
	# every bin: the numbers of the coverage line, 7 of them, each above 0
	bins="$(sed -n 's/^coverage: calls \([0-9]*\), polls late \([0-9]*\), on time \([0-9]*\), timer writes on the old timer.s wrap \([0-9]*\), INTIM reads in a rollover \([0-9]*\), polls on the wrap.s clock \([0-9]*\), resets \([0-9]*\)$/\1 \2 \3 \4 \5 \6 \7/p' <<< "$cov")"
	zero=0
	[ "$(wc -w <<< "$bins")" = 7 ] || zero=1
	for b in $bins; do [ "$b" -gt 0 ] || zero=1; done
	if [ "$(field errors "$res")" = 0 ] && [ "$zero" = 0 ]; then
		echo "PASS seed $s: ${res#result: }"
	else
		echo "FAIL seed $s: ${res#result: }$([ "$zero" = 1 ] && echo "; a coverage bin is 0 or missing") ($WORK/s$s.log)"
		grep -m5 "^ERROR" "$WORK/s$s.log" | sed 's/^/  /'
		ok=0
	fi
	echo "  ${cov}"
done

if [ "${MUTATIONS:-1}" = 1 ]; then
	echo "-- 2. mutations (each must fail)"
	MW="$WORK/mut"
	mkdir -p "$MW"
	caught=0
	total=0
	for m in intim_keeps_rollover late_at_call_end no_armed write_clears_wrap no_a12 prescale64; do
		total=$((total + 1))
		python3 - "$DUT" "$MW/$m.sv" "$m" <<'PY'
import sys
src, dst, m = sys.argv[1:]
s = open(src).read()
M = {
	"intim_keeps_rollover": [("\t\t\tend else if (sel && rw && ~ab[0])\n\t\t\t\tt_roll <= 1'b0;", "\t\t\tend")],
	"late_at_call_end": [("wire poll  = sel && rw && await;", "wire poll  = stop;")],
	"no_armed": [("if (poll && wrote && armed && exp_n", "if (poll && wrote && exp_n")],
	"write_clears_wrap": [("wire exp_n = wr ? wrap :", "wire exp_n = wr ? 1'b0 :")],
	"no_a12": [("wire sel   = ce && ~ab[12] && ab[7]", "wire sel   = ce && ab[7]")],
	"prescale64": [("(~|t_pre[5:0] && t_incr == 2'd2)", "(~|t_pre[4:0] && t_incr == 2'd2)")],
}
for a, b in M[m]:
	assert s.count(a) == 1, (m, a)
	s = s.replace(a, b)
open(dst, "w").write(s)
PY
		if ! build "$MW/obj_$m" "$MW/$m.sv" > /dev/null; then
			echo "FAIL mutation $m: build failed ($MW/obj_$m.log)"
			ok=0
			continue
		fi
		rc=0
		timeout 600 nice -n 10 "$MW/obj_$m/vtb" +seed=1 +cycles="$CYCLES" > "$MW/$m.log" 2>&1 || rc=$?
		res="$(grep "^result:" "$MW/$m.log" || true)"
		e="$(field errors "$res")"
		if [ -z "$res" ] || [ -z "$e" ] || [ "$rc" != 0 ]; then
			echo "FAIL mutation $m: ERROR, not counted as caught (exit $rc, $MW/$m.log)"
			ok=0
		elif [ "$e" != 0 ]; then
			echo "PASS mutation $m caught: ${res#result: }; first: $(grep -m1 '^ERROR' "$MW/$m.log" | cut -c1-110)"
			caught=$((caught + 1))
		else
			echo "FAIL mutation $m not caught: ${res#result: }"
			ok=0
		fi
		rm -rf "$MW/obj_$m"
	done
	echo "mutations caught: $caught of $total"
fi
[ "$ok" = 1 ] && echo "run_dstat.sh: PASS" || echo "run_dstat.sh: FAIL"
[ "$ok" = 1 ]
