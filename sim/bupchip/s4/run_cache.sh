#!/bin/bash
# The asset cache's directed and random load streams (tb_cache.sv), in each
# configuration: pre-emption on and off, prefetch on and off, on psram.sv with
# psram_model.sv and on psram_standin.sv. Every run must load every byte
# right, never complete a load on a collided M10K read, never wait 200 clocks,
# and reach each case it is there for (misses, word-load misses, late hits,
# prefetches, pre-emptions and misses on pre-empted lines where they apply,
# holds during a fill).
#   ./run_cache.sh [+loads=N] [+seed=S]
# Environment: SEEDS (default "1 2 3"), CONFIGS (default all eight), WORK
# (default sim/work/bupchip/s4), VERILATOR. About 2 minutes.
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
		grep -Eq "^result: loads=[0-9]+ bad=0 rdw=0 stuck=0 " <<< "$res" || r=0
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
[ "$ok" = 1 ]
