#!/bin/bash
# The asset cache's directed scenarios and random load streams (tb_cache.sv),
# for WAYS = 1 (ARIA's 64 lines, direct-mapped) and WAYS = 2 (DARIA's 128
# sets of 2 ways), each in every configuration: pre-emption on and off,
# prefetch on and off, on psram.sv with psram_model.sv and on
# psram_standin.sv. Every run must pass every directed check (the boot's
# cold-line byte reads, word-load misses, a hit on the line under fill, a
# demand miss during a prefetch and during a demand fill, holds during a
# fill, the tag sweep with new PSRAM contents behind every valid line; with
# two ways also both lines of a set resident, FIFO replacement, the prefetch
# into the other way, pre-emption across the ways and every tag bit), load
# every byte right, never complete a load on a collided M10K read, never
# start a PSRAM read or write the data M10K while held, never hold a line in
# both ways, never wait 200 clocks, and reach each case it is there for in
# the random phase (misses, word-load misses, late hits, prefetches,
# pre-emptions and misses on pre-empted lines where they apply, holds during
# a fill). The WAYS = 1 runs also run the step 4 cache (git REF_COMMIT, the
# last commit before WAYS) on the same inputs, and every output must agree on
# every clock.
#   ./run_cache.sh [+loads=N] [+seed=S]
# Then mutations of a copy of bup_asset_cache.sv, each of which must fail.
# For each WAYS the 11 of step 4 (completion on the critical halfword alone,
# no data or tag read-during-write wait, no invalid tag at a fill's start, an
# LDR waiting for one halfword, a hold keeping the read in flight,
# pre-emption not waiting for it, the tag written valid a halfword early, no
# tag sweep, a sweep one tag short, reads issued while held); for WAYS = 2
# also 13 of the second way (the FIFO bit never flipping, or flipping when a
# fill starts; demand fills always into way 0; the fill's start invalidating
# the other way; the hit way's data not selected; the line under fill read
# from way 0; a tag compare ignoring its top bit in way 1 or its bottom bit
# in way 0; a fill writing both ways' data; the prefetch probing way 0 only;
# the read-during-write waits seeing way 0's writes only; the sweep clearing
# way 0 only).
# Environment: WAYS (default "1 2"), SEEDS (default "1 2 3"), CONFIGS
# (default all eight, PSRAM:PREEMPT:PREFETCH), MUTATIONS (1; 0 skips them),
# MLOADS (random loads per mutation, 50,000), REF_COMMIT (default 633faf4;
# empty skips the lockstep), WORK (default sim/work/bupchip/s4), VERILATOR.
# About 25 minutes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RTL="$ROOT/src/fpga/mister/rtl"
CORE="$ROOT/src/fpga/core/bupchip"
PU="$ROOT/src/fpga/pocket_utils"
WORK="${WORK:-$HERE/../../work/bupchip/s4}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
CONFIGS="${CONFIGS:-real:1:1 real:0:1 real:1:0 real:0:0 standin:1:1 standin:0:1 standin:1:0 standin:0:0}"
REF_COMMIT="${REF_COMMIT-633faf4}"
ok=1

# The step 4 cache, renamed, for the lockstep of the WAYS = 1 runs.
REF=
if [ -n "$REF_COMMIT" ]; then
	if git -C "$ROOT" show "$REF_COMMIT:src/fpga/core/bupchip/bup_asset_cache.sv" 2> /dev/null \
			| sed 's/^module bup_asset_cache /module bup_asset_cache_ref /' > "$WORK/bup_asset_cache_ref.sv.new" \
			&& grep -q "^module bup_asset_cache_ref " "$WORK/bup_asset_cache_ref.sv.new"; then
		cmp -s "$WORK/bup_asset_cache_ref.sv.new" "$WORK/bup_asset_cache_ref.sv" 2> /dev/null \
			|| mv "$WORK/bup_asset_cache_ref.sv.new" "$WORK/bup_asset_cache_ref.sv"
		rm -f "$WORK/bup_asset_cache_ref.sv.new"
		REF="$WORK/bup_asset_cache_ref.sv"
	else
		rm -f "$WORK/bup_asset_cache_ref.sv.new"
		echo "note: no $REF_COMMIT:src/fpga/core/bupchip/bup_asset_cache.sv in git; the WAYS = 1 runs skip the lockstep"
	fi
fi

for ways in ${WAYS:-1 2}; do
	for c in $CONFIGS; do
		IFS=: read -r psram pre pf <<< "$c"
		OBJ="$WORK/obj_cache_w${ways}_${psram}_pre${pre}_pf${pf}"
		SRCS=("$RTL/cache_ram.v" "$CORE/bup_asset_wr.sv" "$CORE/bup_asset_cache.sv")
		DEFS=(-DPREEMPT="$pre" -DPREFETCH="$pf")
		[ "$ways" = 2 ] && DEFS+=(-DWAYS2)
		lock=0
		if [ "$ways" = 1 ] && [ -n "$REF" ]; then SRCS+=("$REF"); DEFS+=(-DREF_CACHE); lock=1; fi
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
			LOG="$WORK/cache_w${ways}_${psram}_pre${pre}_pf${pf}_s$seed.log"
			nice -n "${NICE:-5}" "$OBJ/vtb" +seed="$seed" "$@" | grep -v "^\[0\] -Info: psram.sv" > "$LOG"
			res="$(grep "^result:" "$LOG" || true)"
			r=1
			grep -Eq "^result: loads=[0-9]+ bad=0 rdw=0 stuck=0 heldwr=0 rdheld=0 dirfail=0 dir=[1-9][0-9]* .* dup=0 eqv=0$" <<< "$res" || r=0
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
			[ "$lock" = 1 ] && grep -q "^  lockstep with the step 4 cache: 0 clocks differ" "$LOG" || [ "$lock" = 0 ] || r=0
			lk=; [ "$lock" = 1 ] && lk=", in lockstep with $REF_COMMIT"
			[ "$r" = 1 ] && echo "PASS ways=$ways $psram pre=$pre pf=$pf seed=$seed$lk: ${res#result: }" \
				|| { echo "FAIL ways=$ways $psram pre=$pre pf=$pf seed=$seed: $LOG"; ok=0; }
		done
	done
done

# Mutations of a copy of bup_asset_cache.sv: each must fail (pre-emption and
# prefetch on, psram.sv on the model, seed 1, MLOADS random loads).
M1="crit_only no_dcol no_tcol no_invalidate ldr_one_hw hold_keeps_fl preempt_no_wait fill_end_early sweep_none sweep_short rdreq_ungated"
M2="fifo_never_flips flip_at_start victim_way0 invalidate_wrong_way wrong_way_hit infill_way0 tag_top_way1 tag_bottom_way0
	fill_both_ways probe_way0 tcol_way0 dcol_way0 sweep_way0"
if [ "${MUTATIONS:-1}" = 1 ]; then
	MW="$WORK/cache_mut"
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
	"crit_only": [("wire have    = in_fill ? (f_arr & need) == need : thit;", "wire have    = in_fill ? f_arr[crit] != 1'b0 : thit;")],
	"no_dcol": [("assign w_wait = w_asset && !(have && !tcol && !dcol);", "assign w_wait = w_asset && !(have && !tcol);")],
	"no_tcol": [("assign w_wait = w_asset && !(have && !tcol && !dcol);", "assign w_wait = w_asset && !(have && !dcol);")],
	"no_invalidate": [("\t\t\ttb_we = vic_a ? 2'b10 : 2'b01;", "\t\t\ttb_we = 2'b00;"),
		("\t\t\ttb_we = vic_b ? 2'b10 : 2'b01;", "\t\t\ttb_we = 2'b00;")],
	"ldr_one_hw": [("8'b11 << {w_addr[3:2], 1'b0}", "8'b01 << {w_addr[3:2], 1'b0}")],
	"hold_keeps_fl": [("\t\t\tf_act <= 1'b0;\n\t\t\tf_fl <= 1'b0;\n\t\t\tstop <= 1'b0;", "\t\t\tf_act <= 1'b0;\n\t\t\tstop <= 1'b0;")],
	"preempt_no_wait": [("(PREEMPT && !f_fl && !rd_ack)", "(PREEMPT && !rd_ack)")],
	"fill_end_early": [("wire fill_end = rx && f_rx_n == 4'd1;", "wire fill_end = rx && f_rx_n == 4'd2;")],
	"sweep_none": [("\t\t\ttb_we = {2{pre_run}};\n", "\t\t\ttb_we = 2'b00;\n")],
	"sweep_short": [("if (sw_cnt == SW_LAST) sweep_done <= 1'b1;", "if (sw_cnt == SW_LAST - 1'b1) sweep_done <= 1'b1;")],
	"rdreq_ungated": [("assign rd_req  = run && f_act", "assign rd_req  = f_act")],
	# two ways
	"fifo_never_flips": [("tb_wd = tword(1'b1, !f_p, f_tag);", "tb_wd = tword(1'b1, f_p, f_tag);")],
	"flip_at_start": [("tb_wd = tword(1'b0, p_a, '0);", "tb_wd = tword(1'b0, !p_a, '0);"),
		("tb_wd = tword(1'b0, p_b, '0);", "tb_wd = tword(1'b0, !p_b, '0);")],
	"victim_way0": [("wire vic_a   = TWO && (tq_a0[12] ^ tq_a1[12]);", "wire vic_a   = 1'b0;")],
	"invalidate_wrong_way": [("\t\t\ttb_we = vic_a ? 2'b10 : 2'b01;", "\t\t\ttb_we = vic_a ? 2'b01 : 2'b10;"),
		("\t\t\ttb_we = vic_b ? 2'b10 : 2'b01;", "\t\t\ttb_we = vic_b ? 2'b01 : 2'b10;")],
	"wrong_way_hit": [("assign asset_q = (in_fill ? f_way : thit1) ? dq_a1 : dq_a0;", "assign asset_q = (in_fill ? f_way : thit0) ? dq_a1 : dq_a0;")],
	"infill_way0": [("assign asset_q = (in_fill ? f_way : thit1) ? dq_a1 : dq_a0;", "assign asset_q = (in_fill ? 1'b0 : thit1) ? dq_a1 : dq_a0;")],
	"tag_top_way1": [("wire thit1   = TWO && tq_a1[13] && tq_a1[TW-1:0] == tag;", "wire thit1   = TWO && tq_a1[13] && tq_a1[TW-2:0] == tag[TW-2:0];")],
	"tag_bottom_way0": [("wire thit0   = tq_a0[13] && tq_a0[TW-1:0] == tag;", "wire thit0   = tq_a0[13] && tq_a0[TW-1:1] == tag[TW-1:1];")],
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
			DEFS=(-DPREEMPT=1 -DPREFETCH=1)
			[ "$ways" = 2 ] && DEFS+=(-DWAYS2)
			rm -rf "$OBJ"
			"$VERILATOR" --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD --top-module tb_cache \
				"${DEFS[@]}" -Mdir "$OBJ" -o vtb "$RTL/cache_ram.v" "$CORE/bup_asset_wr.sv" "$MW/w${ways}_$m.sv" \
				"$PU/psram.sv" "$HERE/psram_model.sv" "$HERE/tb_cache.sv" > "$OBJ.log" 2>&1 \
				|| { echo "FAIL mutation ways=$ways $m: build failed ($OBJ.log)"; ok=0; continue; }
			LOG="$MW/w${ways}_$m.log"
			nice -n "${NICE:-5}" timeout 600 "$OBJ/vtb" +seed=1 +loads="${MLOADS:-50000}" > "$LOG" 2>&1 || true
			rm -rf "$OBJ"
			res="$(grep "^result:" "$LOG" || echo "result: none")"
			df="$(sed -n 's/.* dirfail=\([0-9]*\).*/\1/p' <<< "$res")"
			if grep -Eq "^result: loads=[0-9]+ bad=0 rdw=0 stuck=0 heldwr=0 rdheld=0 dirfail=0 .* dup=0 eqv=0$" <<< "$res"; then
				echo "FAIL mutation ways=$ways $m not caught: ${res#result: }"; ok=0
			else
				echo "PASS mutation ways=$ways $m caught (directed checks failing: ${df:-?}): ${res#result: }"
			fi
		done
	done
fi
[ "$ok" = 1 ]
