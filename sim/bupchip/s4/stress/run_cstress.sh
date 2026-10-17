#!/bin/bash
# Corner-case stress of the asset cache (tb_cstress.sv; step 4 of
# docs/BUPCHIP_CORE.md, and DARIA's 2-way cache): every pair of loads at
# every size, offset and distance on cold lines, lines under fill, the
# prefetch's line and conflicting lines; holds at every clock of a fill and
# of a prefetch with new PSRAM contents behind them; random streams with
# holds. On M10K models that poison a mixed-port read-during-write
# (cache_ram_poison.v), for WAYS = 1 and WAYS = 2, in four cache
# configurations each, on PSRAM latencies 1 to 20 (psram_var.sv) and on
# psram.sv with psram_model.sv. Then mutations of a copy of
# bup_asset_cache.sv that the stress must catch: for each WAYS the 10 of
# step 4, and for WAYS = 2 also 10 of the second way (the hit way's data not
# selected; the line under fill read from way 0; a tag compare ignoring its
# top bit in way 1 or its bottom bit in way 0; the fill's start
# invalidating the other way; a fill writing both ways' data; the prefetch
# probing way 0 only; the read-during-write waits seeing way 0's writes
# only; the sweep clearing way 0 only). The replacement order itself
# (FIFO) changes no data, so ../tb_cache.sv's directed checks cover it.
#   ./run_cstress.sh
# Environment: WAYS (default "1 2"), CONFIGS (default "1:1 0:1 1:0 0:0",
# PREEMPT:PREFETCH), LATS (default "5:5 1:1 1:3 1:12 4:9 5:20"), MUTATIONS
# (1; 0 skips them), WORK (default sim/work/bupchip/s4stress), VERILATOR.
# About 20 minutes on one core. Exits 0 when every run passes and every
# mutation is caught.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../../src/fpga/mister/rtl" && pwd)"
CORE="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
PU="$(cd "$HERE/../../../../src/fpga/pocket_utils" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
ok=1

build() {       # build OBJ CACHE_SRC PSRAM(var|real) PREEMPT PREFETCH WAYS
	local obj="$1" csrc="$2" ps="$3" pre="$4" pf="$5" ways="$6"
	local srcs=("$HERE/cache_ram_poison.v" "$CORE/bup_asset_wr.sv" "$csrc")
	local defs=(-DPREEMPT="$pre" -DPREFETCH="$pf")
	[ "$ways" = 2 ] && defs+=(-DWAYS2)
	if [ "$ps" = real ]; then srcs+=("$PU/psram.sv" "$HERE/../psram_model.sv"); defs+=(-DPSRAM_REAL)
	else srcs+=("$HERE/psram_var.sv"); fi
	srcs+=("$HERE/tb_cstress.sv")
	if [ -x "$obj/vtb" ] && [ -z "$(find "${srcs[@]}" "$0" -newer "$obj/vtb" 2>/dev/null)" ]; then return 0; fi
	rm -rf "$obj"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module tb_cstress "${defs[@]}" -Mdir "$obj" -o vtb "${srcs[@]}" > "$obj.log" 2>&1 \
		|| { grep -E "^%Error" "$obj.log" | head -20 >&2; echo "build failed: $obj.log" >&2; return 1; }
	find "$obj" \( -name '*.gch' -o -name '*.o' \) -delete
}

check() {       # check LOG: the result line is clean
	local res
	res="$(grep "^result:" "$1" || true)"
	grep -Eq "^result: loads=[1-9][0-9]* bad=0 rdw=0 stuck=0 wrvalid=0 heldwr=0 sweep=0 linebad=0 viol=0 fired=[1-9][0-9]* armed=[0-9]+ bank1=0 early=0 dup=0$" <<< "$res"
}

for ways in ${WAYS:-1 2}; do
# ---- the stress, per configuration and latency ----------------------------------------------------
for c in ${CONFIGS:-1:1 0:1 1:0 0:0}; do
	IFS=: read -r pre pf <<< "$c"
	OBJ="$WORK/obj_cs_w${ways}_var_pre${pre}_pf${pf}"
	build "$OBJ" "$CORE/bup_asset_cache.sv" var "$pre" "$pf" "$ways" || { ok=0; continue; }
	for l in ${LATS:-5:5 1:1 1:3 1:12 4:9 5:20}; do
		IFS=: read -r lmin lmax <<< "$l"
		# the full pair sweep at psram.sv's 5 clocks, every third pair otherwise
		step=3; [ "$l" = 5:5 ] && step=1
		LOG="$WORK/cs_w${ways}_pre${pre}_pf${pf}_l${lmin}_${lmax}.log"
		nice -n "${NICE:-5}" "$OBJ/vtb" +mode=all +seed="$lmin$lmax$pre$pf" +plmin="$lmin" +plmax="$lmax" +pstep="$step" \
			| grep -v "^- " > "$LOG"
		if check "$LOG"; then echo "PASS ways=$ways pre=$pre pf=$pf latency $lmin..$lmax: $(sed -n 's/^cache stress, //p' "$LOG")"
		else echo "FAIL ways=$ways pre=$pre pf=$pf latency $lmin..$lmax: $LOG"; ok=0; fi
		grep -E "^  (excess|holds|data M10K|ways)" "$LOG"
	done
done

# ---- psram.sv on psram_model.sv (1 MiB of asset space) ------------------------------------------------
OBJ="$WORK/obj_cs_w${ways}_real_pre1_pf1"
if build "$OBJ" "$CORE/bup_asset_cache.sv" real 1 1 "$ways"; then
	for j in 0 14900; do
		LOG="$WORK/cs_w${ways}_real_j$j.log"
		nice -n "${NICE:-5}" "$OBJ/vtb" +mode=all +seed=7 +size=1048576 +pstep=7 +loads=100000 \
			+psram_jitter_ps="$j" +psram_seed=5 | grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " > "$LOG"
		if check "$LOG" && grep -q " 0 violations, 0 late reads (stress), " "$LOG"; then
			echo "PASS ways=$ways psram.sv on the model, read data up to $j ps late: $(sed -n 's/^cache stress, //p' "$LOG")"
		else echo "FAIL ways=$ways psram.sv on the model, jitter $j ps: $LOG"; ok=0; fi
	done
else ok=0; fi
done

# ---- mutations: each must fail ---------------------------------------------------------------------
M1="sweep_short sweep_none infill_idx_only no_dcol no_tcol dcol_line_hw keep_fl crit_only odd_ldrh_next no_invalidate"
M2="wrong_way_hit infill_way0 tag_top_way1 tag_bottom_way0 invalidate_wrong_way fill_both_ways probe_way0 tcol_way0 dcol_way0
	sweep_way0"
if [ "${MUTATIONS:-1}" = 1 ]; then
	MW="$WORK/mut"
	mkdir -p "$MW"
	for ways in ${WAYS:-1 2}; do
	muts="$M1"
	[ "$ways" = 2 ] && muts="$M1 $M2"
	for m in $muts; do
		python3 - "$CORE/bup_asset_cache.sv" "$MW/w${ways}_$m.sv" "$m" <<'PY'
import sys
src, dst, m = sys.argv[1:]
s = open(src).read()
M = {
	# the sweep leaves the last set alone / writes nothing
	"sweep_short": [("if (sw_cnt == SW_LAST) sweep_done <= 1'b1;", "if (sw_cnt == SW_LAST - 1'b1) sweep_done <= 1'b1;")],
	"sweep_none": [("\t\t\ttb_we = {2{pre_run}};\n", "\t\t\ttb_we = 2'b00;\n")],
	# the line under fill recognised by its index alone
	"infill_idx_only": [("wire in_fill = f_act && f_idx == idx && f_tag == tag;", "wire in_fill = f_act && f_idx == idx;")],
	"no_dcol": [("assign w_wait = w_asset && !(have && !tcol && !dcol);", "assign w_wait = w_asset && !(have && !tcol);")],
	"no_tcol": [("assign w_wait = w_asset && !(have && !tcol && !dcol);", "assign w_wait = w_asset && !(have && !dcol);")],
	# the data collision compared on the halfword written, not the word
	"dcol_line_hw": [("wire dcol    = dw_q && dw_a_q == w_addr[IW+3:2];", "wire dcol    = dw_q && dw_a_q == w_addr[IW+3:2] && f_fl_hw[0] == w_addr[1];")],
	# a hold leaves the read in flight marked
	"keep_fl": [("\t\t\tf_act <= 1'b0;\n\t\t\tf_fl <= 1'b0;\n\t\t\tstop <= 1'b0;", "\t\t\tf_act <= 1'b0;\n\t\t\tstop <= 1'b0;")],
	"crit_only": [("wire have    = in_fill ? (f_arr & need) == need : thit;", "wire have    = in_fill ? f_arr[crit] != 1'b0 : thit;")],
	# an odd LDRH waits for the halfword after its own
	"odd_ldrh_next": [("8'b1 << w_addr[3:1];", "8'b1 << (w_addr[3:1] + {2'b00, w_addr[0] & w_size[0]});")],
	"no_invalidate": [("\t\t\ttb_we = vic_a ? 2'b10 : 2'b01;", "\t\t\ttb_we = 2'b00;"),
		("\t\t\ttb_we = vic_b ? 2'b10 : 2'b01;", "\t\t\ttb_we = 2'b00;")],
	# two ways
	"wrong_way_hit": [("assign asset_q = (in_fill ? f_way : thit1) ? dq_a1 : dq_a0;", "assign asset_q = (in_fill ? f_way : thit0) ? dq_a1 : dq_a0;")],
	"infill_way0": [("assign asset_q = (in_fill ? f_way : thit1) ? dq_a1 : dq_a0;", "assign asset_q = (in_fill ? 1'b0 : thit1) ? dq_a1 : dq_a0;")],
	"tag_top_way1": [("wire thit1   = TWO && tq_a1[13] && tq_a1[TW-1:0] == tag;", "wire thit1   = TWO && tq_a1[13] && tq_a1[TW-2:0] == tag[TW-2:0];")],
	"tag_bottom_way0": [("wire thit0   = tq_a0[13] && tq_a0[TW-1:0] == tag;", "wire thit0   = tq_a0[13] && tq_a0[TW-1:1] == tag[TW-1:1];")],
	"invalidate_wrong_way": [("\t\t\ttb_we = vic_a ? 2'b10 : 2'b01;", "\t\t\ttb_we = vic_a ? 2'b01 : 2'b10;"),
		("\t\t\ttb_we = vic_b ? 2'b10 : 2'b01;", "\t\t\ttb_we = vic_b ? 2'b01 : 2'b10;")],
	"fill_both_ways": [(".wren_b_i(rx && f_way),", ".wren_b_i(rx),")],
	"probe_way0": [("wire pf_have  = (tq_b0[13] && tq_b0[TW-1:0] == p_tag) || (TWO && tq_b1[13] && tq_b1[TW-1:0] == p_tag)",
		"wire pf_have  = (tq_b0[13] && tq_b0[TW-1:0] == p_tag)")],
	"tcol_way0": [("tw_q <= |tb_we;", "tw_q <= tb_we[0];")],
	"dcol_way0": [("dw_q <= rx;", "dw_q <= rx && !f_way;")],
	"sweep_way0": [("\t\t\ttb_we = {2{pre_run}};\n", "\t\t\ttb_we = {1'b0, pre_run};\n")],
}
for a, b in M[m]:
	assert s.count(a) == 1, (m, a)
	s = s.replace(a, b)
open(dst, "w").write(s)
PY
		OBJ="$MW/obj_w${ways}_$m"
		if ! build "$OBJ" "$MW/w${ways}_$m.sv" var 1 1 "$ways"; then echo "FAIL mutation ways=$ways $m: build failed"; ok=0; continue; fi
		LOG="$MW/w${ways}_$m.log"
		nice -n "${NICE:-5}" timeout 900 "$OBJ/vtb" +mode=all +seed=11 +pstep=5 +loads=100000 +plmin=1 +plmax=12 \
			| grep -v "^- " > "$LOG" 2>&1 || true
		rm -rf "$OBJ"
		if check "$LOG"; then echo "FAIL mutation ways=$ways $m not caught: $(grep '^result:' "$LOG")"; ok=0
		else echo "PASS mutation ways=$ways $m caught: $(grep '^result:' "$LOG" || echo 'no result line')"; fi
	done
	done
fi
[ "$ok" = 1 ] && echo "run_cstress.sh: all passed" || echo "run_cstress.sh: FAILED"
[ "$ok" = 1 ]
