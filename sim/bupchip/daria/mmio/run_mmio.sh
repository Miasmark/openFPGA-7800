#!/bin/bash
# daria_mmio.sv (MAMCR, timer 1's TCR and TC; docs/DARIA_CORE.md, "Timer 1 and
# MAMCR") on tb_mmio.sv, with Verilator (5.040; set VERILATOR to override).
#   ./run_mmio.sh
# 1. The bench in each clock variant: NTSC and PAL, clk_sys and clk_arm from
#    one VCO (sync) and clk_arm at another rate and phase (async, several
#    seeds). Each run must end with errors=0, the rate window exact, the TCR
#    start and stop latencies 3 and 2 edges, and every case it is there for
#    reached: writes landing on a counting edge, pauses with the counter on,
#    queued writes, resets during a write's flight (before clk_sys merged it
#    and before the snapshot acknowledged it), with a write queued, during a
#    snapshot's crossing, and with each side's reset first. The two Draconian
#    readings must be within 55 counts of the ideal.
# 2. Mutations of a copy of daria_mmio.sv: each must fail in at least one of
#    NTSC sync, NTSC async and PAL sync (with a shorter random phase), JOBS
#    (4) at a time.
# Environment: VARIANTS (default "sync:0:1 async:0:1 async:0:2 async:0:3
# sync:1:1 async:1:1 async:1:2", clock:pal:seed), LONG (clk_sys clocks of the
# random phase, 400,000), MUTATIONS (1; 0 skips them), MLONG (60,000), WORK
# (default sim/work/bupchip/daria/mmio), VERILATOR.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/daria/mmio}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

build() {	# OBJ DUT_SOURCE
	rm -rf "$1"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module tb_mmio -Mdir "$1" -o vtb "$2" "$HERE/tb_mmio.sv" > "$1.log" 2>&1 || return 1
	find "$1" \( -name '*.gch' -o -name '*.o' \) -delete
}

field() {	# NAME RESULT
	sed -n "s/.* $1=\([-0-9.]*\).*/\1/p" <<< "$2"
}

ok=1
OBJ="$WORK/obj_mmio"
if ! [ -x "$OBJ/vtb" ] || [ -n "$(find "$CORE/daria_mmio.sv" "$HERE/tb_mmio.sv" "$0" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	build "$OBJ" "$CORE/daria_mmio.sv" || { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
fi

for v in ${VARIANTS:-sync:0:1 async:0:1 async:0:2 async:0:3 sync:1:1 async:1:1 async:1:2}; do
	IFS=: read -r clk pal seed <<< "$v"
	name="${clk}_$( [ "$pal" = 1 ] && echo pal || echo ntsc )_s$seed"
	LOG="$WORK/$name.log"
	args=(+clk="$clk" +seed="$seed" +long="${LONG:-400000}")
	[ "$pal" = 1 ] && args+=(+pal)
	nice -n "${NICE:-5}" "$OBJ/vtb" "${args[@]}" > "$LOG" 2>&1 || true
	res="$(grep "^result:" "$LOG" || echo "result: none")"
	r=1
	[ "$(field errors "$res")" = 0 ] || r=0
	[ "$(field lat_start "$res")" = 3 ] || r=0
	[ "$(field lat_stop "$res")" = 2 ] || r=0
	[ "$(field rate "$res")" = "$( [ "$pal" = 1 ] && echo 337500 || echo 334400 )" ] || r=0
	for k in merge_inc pause_en queued qlaunch rst_wfl rst_busy rst_q rst_sfl sys_first arm_first partreads never; do
		[ "${k}" != "" ] && [ "$(field "$k" "$res")" -gt 0 ] 2>/dev/null || { echo "  $name: $k not reached"; r=0; }
	done
	for d in drac0_diff drac1_diff; do
		awk -v x="$(field "$d" "$res")" 'BEGIN { exit !(x != "" && x <= 55 && x >= -55) }' || r=0
	done
	if [ "$r" = 1 ]; then
		echo "PASS $name: ${res#result: }"
	else
		echo "FAIL $name: $LOG"
		grep "^ERROR" "$LOG" | head -5
		ok=0
	fi
	grep "^draconian\|^age histogram" "$LOG" | sed "s/^/  /"
done

# Mutations of a copy of daria_mmio.sv: each must fail.
mutate() {	# NAME: writes $MW/NAME.res
	local m="$1" OBJM="$MW/obj_$1" why="" v clk pal seed args LOG res e
	python3 - "$CORE/daria_mmio.sv" "$MW/$m.sv" "$m" <<'PY'
import sys
src, dst, m = sys.argv[1:]
s = open(src).read()
M = {
	# The mirror takes every snapshot, whatever its token.
	"no_token": [("wire        snap_ok  = snap_new && hold_tok == w_tog;", "wire        snap_ok  = snap_new;")],
	# The increment wins over a write landing in the same clock.
	"inc_wins": [("\t\tend else if (run && en_s[1])\n", "\t\tend\n\t\tif (run && en_s[1])\n")],
	# The write lands and the clock's increment is added to it.
	"inc_added": [("tc <= lanes(tc, w_data, w_strb);",
	"tc <= lanes(tc, w_data, w_strb) + (run && en_s[1] ? (four ? 32'd4 : 32'd5) : 32'd0);")],
	# NTSC: 49 per 10 clocks.
	"ntsc_period": [("wire [6:0] ph_last = pal ? 7'd75 : 7'd8;", "wire [6:0] ph_last = pal ? 7'd75 : 7'd9;")],
	# NTSC: two fours, 43 per 9.
	"ntsc_four_twice": [(": ph == 7'd0;", ": ph == 7'd0 || ph == 7'd4;")],
	# PAL: four fours, 376 per 76.
	"pal_four_short": [(" || ph == 7'd60", "")],
	# PAL: 77 clocks a period.
	"pal_period": [("wire [6:0] ph_last = pal ? 7'd75 : 7'd8;", "wire [6:0] ph_last = pal ? 7'd76 : 7'd8;")],
	# The decode ignores addr[1:0].
	"decode_lowbits": [("sel && addr == A_MAMCR", "sel && addr[31:2] == A_MAMCR[31:2]"),
	("sel && addr == A_T1TCR", "sel && addr[31:2] == A_T1TCR[31:2]"),
	("sel && addr == A_T1TC;", "sel && addr[31:2] == A_T1TC[31:2];")],
	# The counter runs on through a pause.
	"no_run_gate": [("end else if (run && en_s[1])", "end else if (en_s[1])")],
	# The phase runs on through a pause.
	"phase_ungated": [("if (run) ph <= ph >= ph_last", "ph <= ph >= ph_last")],
	# A halfword writes all four lanes.
	"hw_strobe": [("size == 2'd1 ? 4'b0011", "size == 2'd1 ? 4'b1111")],
	# A byte writes all four lanes.
	"byte_strobe": [("size == 2'd0 ? 4'b0001", "size == 2'd0 ? 4'b1111")],
	# The mirror waits for a snapshot instead of taking the written bytes.
	"no_overlay": [("\t\tmirror <= mir_next;\n", "\t\tmirror <= mir_base;\n")],
	# A write during a flight is dropped.
	"drop_queued": [("\t\t\tq_strb <= pend;\n", "\t\t\tq_strb <= q_strb;\n")],
	# A write launches during a flight: the held bus changes under clk_sys.
	"launch_busy": [("wire        launch   = pend != 4'd0 && (!busy || snap_ok);",
	"wire        launch   = pend != 4'd0;")],
	# A snapshot every clk_sys: the held bus changes under clk_arm.
	"snap_every_clock": [("if (sn_div == 2'd3) begin", "if (1'b1) begin")],
	# The merge on the first synchroniser flop.
	"write_one_flop": [("wire       merge_now = w_s[1] != w_seen;", "wire       merge_now = w_s[0] != w_seen;"),
	("\t\t\tw_seen <= w_s[1];\n", "\t\t\tw_seen <= w_s[0];\n")],
	# A snapshot replaces the queued lanes too.
	"snap_full_lanes": [("wire [31:0] mir_base = snap_ok ? lanes(hold, mirror, q_strb) : mirror;",
	"wire [31:0] mir_base = snap_ok ? hold : mirror;")],
	# rst_arm keeps the write toggle: clk_sys merges the held write again.
	"rst_keeps_tog": [("\t\t\tw_tog <= 1'b0;\n", "")],
	# rst_sys keeps the counter.
	"rst_sys_keeps_tc": [("\t\t\ttc <= 32'd0;\n", "")],
	# rst_arm keeps MAMCR.
	"rst_arm_keeps_mamcr": [("\t\t\tmamcr <= 32'd0;\n", "")],
	# TCR reads as its bit 0 alone.
	"tcr_not_read_back": [("({32{hit_tcr}} & tcr)", "({32{hit_tcr}} & {31'd0, tcr[0]})")],
}
for a, b in M[m]:
	assert s.count(a) == 1, (m, a)
	s = s.replace(a, b)
open(dst, "w").write(s)
PY
	if ! build "$OBJM" "$MW/$m.sv"; then
		echo "FAIL mutation $m: build failed ($OBJM.log)" > "$MW/$m.res"; return
	fi
	for v in sync:0:1 async:0:1 sync:1:1; do
		IFS=: read -r clk pal seed <<< "$v"
		args=(+clk="$clk" +seed="$seed" +long="${MLONG:-60000}")
		[ "$pal" = 1 ] && args+=(+pal)
		LOG="$MW/${m}_${clk}_p${pal}.log"
		timeout 900 "$OBJM/vtb" "${args[@]}" > "$LOG" 2>&1 || true
		res="$(grep "^result:" "$LOG" || echo "result: none")"
		e="$(field errors "$res")"
		if [ "$e" != 0 ]; then
			why="$why ${clk}/$( [ "$pal" = 1 ] && echo pal || echo ntsc ) errors=${e:-none}"
			[ -z "$first" ] && first="$(grep -m1 '^ERROR' "$LOG" | cut -c1-120)"
		fi
	done
	rm -rf "$OBJM"
	if [ -n "$why" ]; then echo "PASS mutation $m caught:$why; first: $first" > "$MW/$m.res"
	else echo "FAIL mutation $m not caught" > "$MW/$m.res"; fi
}

if [ "${MUTATIONS:-1}" = 1 ]; then
	MW="$WORK/mut"
	mkdir -p "$MW"
	MUTS="no_token inc_wins inc_added ntsc_period ntsc_four_twice pal_four_short pal_period
		decode_lowbits no_run_gate phase_ungated hw_strobe byte_strobe no_overlay drop_queued
		launch_busy snap_every_clock write_one_flop snap_full_lanes rst_keeps_tog rst_sys_keeps_tc
		rst_arm_keeps_mamcr tcr_not_read_back"
	# The control: the DUT unchanged, under the same runs, must not fail.
	for v in sync:0:1 async:0:1 sync:1:1; do
		IFS=: read -r clk pal seed <<< "$v"
		args=(+clk="$clk" +seed="$seed" +long="${MLONG:-60000}")
		[ "$pal" = 1 ] && args+=(+pal)
		"$OBJ/vtb" "${args[@]}" > "$MW/control_${clk}_p${pal}.log" 2>&1 || true
		res="$(grep "^result:" "$MW/control_${clk}_p${pal}.log" || echo "result: none")"
		if [ "$(field errors "$res")" = 0 ]; then echo "PASS control $clk pal=$pal: errors=0"
		else echo "FAIL control $clk pal=$pal: $MW/control_${clk}_p${pal}.log"; ok=0; fi
	done
	for m in $MUTS; do
		rm -f "$MW/$m.res"
		while [ "$(jobs -rp | wc -l)" -ge "${JOBS:-4}" ]; do wait -n; done
		first="" mutate "$m" &
	done
	wait
	caught=0
	total=0
	for m in $MUTS; do
		total=$((total + 1))
		cat "$MW/$m.res" 2>/dev/null || echo "FAIL mutation $m: no result"
		grep -q "^PASS" "$MW/$m.res" 2>/dev/null && caught=$((caught + 1))
	done
	echo "mutations caught: $caught of $total"
	[ "$caught" = "$total" ] || ok=0
fi
[ "$ok" = 1 ]
