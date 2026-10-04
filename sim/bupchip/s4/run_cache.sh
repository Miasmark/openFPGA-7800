#!/bin/bash
# The asset cache's directed scenarios and random load streams (tb_cache.sv),
# in each configuration: pre-emption on and off, prefetch on and off, on
# psram.sv with psram_model.sv and on psram_standin.sv. Every run must pass
# every directed check (the boot's cold-line byte reads, word-load misses, a
# hit on the line under fill, a demand miss during a prefetch and during a
# demand fill, holds during a fill, the tag sweep with new PSRAM contents
# behind every valid line), load every byte right, never complete a load on a
# collided M10K read, never start a PSRAM read or write the data M10K while
# held, never wait 200 clocks, and reach each case it is there for in the
# random phase (misses, word-load misses, late hits, prefetches, pre-emptions
# and misses on pre-empted lines where they apply, holds during a fill).
#   ./run_cache.sh [+loads=N] [+seed=S]
# Then 11 mutations of a copy of bup_asset_cache.sv (completion on the
# critical halfword alone, no data or tag read-during-write wait, no invalid
# tag at a fill's start, an LDR waiting for one halfword, a hold keeping the
# read in flight, pre-emption not waiting for it, the tag written valid a
# halfword early, no tag sweep, a sweep one tag short, reads issued while
# held): each must fail.
# Environment: SEEDS (default "1 2 3"), CONFIGS (default all eight),
# MUTATIONS (1; 0 skips them), MLOADS (random loads per mutation, 50,000),
# WORK (default sim/work/bupchip/s4), VERILATOR. About 4 minutes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)"
CORE="$(cd "$HERE/../../../src/fpga/core/bupchip" && pwd)"
PU="$(cd "$HERE/../../../src/fpga/pocket_utils" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s4}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
CONFIGS="${CONFIGS:-real:1:1 real:0:1 real:1:0 real:0:0 standin:1:1 standin:0:1 standin:1:0 standin:0:0}"
ok=1
for c in $CONFIGS; do
	IFS=: read -r psram pre pf <<< "$c"
	OBJ="$WORK/obj_cache_${psram}_pre${pre}_pf${pf}"
	SRCS=("$RTL/cache_ram.v" "$CORE/bup_asset_wr.sv" "$CORE/bup_asset_cache.sv")
	DEFS=(-DPREEMPT="$pre" -DPREFETCH="$pf")
	if [ "$psram" = real ]; then SRCS+=("$PU/psram.sv" "$HERE/psram_model.sv")
	else SRCS+=("$HERE/psram_standin.sv"); DEFS+=(-DPSRAM_STANDIN); fi
	SRCS+=("$HERE/tb_cache.sv")
	if ! [ -x "$OBJ/vtb" ] || [ -n "$(find "${SRCS[@]}" "$0" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
		rm -rf "$OBJ"
		"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
			--top-module tb_cache "${DEFS[@]}" -Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
			|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
		find "$OBJ" \( -name '*.gch' -o -name '*.o' \) -delete
	fi
	for seed in ${SEEDS:-1 2 3}; do
		LOG="$WORK/cache_${psram}_pre${pre}_pf${pf}_s$seed.log"
		nice -n "${NICE:-5}" "$OBJ/vtb" +seed="$seed" "$@" | grep -v "^\[0\] -Info: psram.sv" > "$LOG"
		res="$(grep "^result:" "$LOG" || true)"
		r=1
		grep -Eq "^result: loads=[0-9]+ bad=0 rdw=0 stuck=0 heldwr=0 rdheld=0 dirfail=0 dir=[1-9][0-9]* " <<< "$res" || r=0
		for k in miss wmiss late holdfill; do
			[ "$(sed -n "s/.* $k=\([0-9]*\).*/\1/p" <<< "$res")" -gt 0 ] || r=0
		done
		[ "$pf" = 0 ] || [ "$(sed -n 's/.* pf=\([0-9]*\).*/\1/p' <<< "$res")" -gt 0 ] || r=0
		if [ "$pre" = 1 ]; then
			for k in pre remiss; do
				[ "$(sed -n "s/.* $k=\([0-9]*\).*/\1/p" <<< "$res")" -gt 0 ] || r=0
			done
		else
			[ "$(sed -n 's/.* pre=\([0-9]*\).*/\1/p' <<< "$res")" = 0 ] || r=0
		fi
		if [ "$psram" = real ]; then
			grep -q " 0 violations, 0 late reads (stress), 0 reads of unwritten bytes" "$LOG" || r=0
		fi
		[ "$r" = 1 ] && echo "PASS $psram pre=$pre pf=$pf seed=$seed: ${res#result: }" \
			|| { echo "FAIL $psram pre=$pre pf=$pf seed=$seed: $LOG"; ok=0; }
	done
done

# Mutations of a copy of bup_asset_cache.sv: each must fail (pre-emption and
# prefetch on, psram.sv on the model, seed 1, MLOADS random loads).
if [ "${MUTATIONS:-1}" = 1 ]; then
	MW="$WORK/cache_mut"
	mkdir -p "$MW"
	for m in crit_only no_dcol no_tcol no_invalidate ldr_one_hw hold_keeps_fl preempt_no_wait fill_end_early \
			sweep_none sweep_short rdreq_ungated; do
		python3 - "$CORE/bup_asset_cache.sv" "$MW/$m.sv" "$m" <<'PY'
import sys
src, dst, m = sys.argv[1:]
s = open(src).read()
M = {
	"crit_only": [("wire have    = in_fill ? (f_arr & need) == need : thit;", "wire have    = in_fill ? f_arr[crit] != 1'b0 : thit;")],
	"no_dcol": [("assign w_wait = w_asset && !(have && !tcol && !dcol);", "assign w_wait = w_asset && !(have && !tcol);")],
	"no_tcol": [("assign w_wait = w_asset && !(have && !tcol && !dcol);", "assign w_wait = w_asset && !(have && !dcol);")],
	"no_invalidate": [("\t\tend else if (start_dem) begin\n\t\t\ttb_we = 1'b1;", "\t\tend else if (start_dem) begin\n\t\t\ttb_we = 1'b0;"),
		("\t\tend else if (start_pf) begin\n\t\t\ttb_we = 1'b1;", "\t\tend else if (start_pf) begin\n\t\t\ttb_we = 1'b0;")],
	"ldr_one_hw": [("8'b11 << {w_addr[3:2], 1'b0}", "8'b01 << {w_addr[3:2], 1'b0}")],
	"hold_keeps_fl": [("\t\t\tf_act <= 1'b0;\n\t\t\tf_fl <= 1'b0;\n\t\t\tstop <= 1'b0;", "\t\t\tf_act <= 1'b0;\n\t\t\tstop <= 1'b0;")],
	"preempt_no_wait": [("(PREEMPT && !f_fl && !rd_ack)", "(PREEMPT && !rd_ack)")],
	"fill_end_early": [("wire fill_end = rx && f_rx_n == 4'd1;", "wire fill_end = rx && f_rx_n == 4'd2;")],
	"sweep_none": [("\t\t\ttb_we = pre_run;\n", "\t\t\ttb_we = 1'b0;\n")],
	"sweep_short": [("if (sw_cnt == 6'd63) sweep_done <= 1'b1;", "if (sw_cnt == 6'd62) sweep_done <= 1'b1;")],
	"rdreq_ungated": [("assign rd_req  = run && f_act", "assign rd_req  = f_act")],
}
for a, b in M[m]:
	assert s.count(a) == 1, (m, a)
	s = s.replace(a, b)
open(dst, "w").write(s)
PY
		OBJ="$MW/obj_$m"
		rm -rf "$OBJ"
		"$VERILATOR" --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD --top-module tb_cache \
			-DPREEMPT=1 -DPREFETCH=1 -Mdir "$OBJ" -o vtb "$RTL/cache_ram.v" "$CORE/bup_asset_wr.sv" "$MW/$m.sv" \
			"$PU/psram.sv" "$HERE/psram_model.sv" "$HERE/tb_cache.sv" > "$OBJ.log" 2>&1 \
			|| { echo "FAIL mutation $m: build failed ($OBJ.log)"; ok=0; continue; }
		LOG="$MW/$m.log"
		nice -n "${NICE:-5}" timeout 600 "$OBJ/vtb" +seed=1 +loads="${MLOADS:-50000}" > "$LOG" 2>&1 || true
		rm -rf "$OBJ"
		res="$(grep "^result:" "$LOG" || echo "result: none")"
		df="$(sed -n 's/.* dirfail=\([0-9]*\).*/\1/p' <<< "$res")"
		if grep -Eq "^result: loads=[0-9]+ bad=0 rdw=0 stuck=0 heldwr=0 rdheld=0 dirfail=0 " <<< "$res"; then
			echo "FAIL mutation $m not caught: ${res#result: }"; ok=0
		else
			echo "PASS mutation $m caught (directed checks failing: ${df:-?}): ${res#result: }"
		fi
	done
fi
[ "$ok" = 1 ]
