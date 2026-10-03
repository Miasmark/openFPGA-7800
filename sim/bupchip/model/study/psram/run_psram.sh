#!/bin/bash
# The PSRAM fact check of the design study (docs/BUPCHIP_CORE.md,
# "Controller"): agg23's psram.sv, which step 4 vendors to
# src/fpga/pocket_utils/, counted clock by clock in tb_psram.sv (iverilog).
#   ./run_psram.sh            PSRAM=FILE to use another copy of psram.sv
# Runs CLOCK_SPEED = 28.636364 on clocks of 28.636, 21.477 and 21.281 MHz,
# where every read and write must take 5 clocks with distinct state numbers;
# then, for the record, CLOCK_SPEED set to the real 21.477, 21.281 and
# 14.318 MHz, where the read and write totals collide with earlier states and
# nothing completes. Work files go to $WORK (default
# sim/work/bupchip/study/psram). Exits 0 when the 28.636364 setting passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
PSRAM="${PSRAM:-$HERE/../../../../../src/fpga/pocket_utils/psram.sv}"
WORK="${WORK:-$HERE/../../../../work/bupchip/study/psram}"
[ -f "$PSRAM" ] || { echo "run_psram.sh: no psram.sv at $PSRAM (step 4 vendors it; set PSRAM=FILE)" >&2; exit 2; }
mkdir -p "$WORK"
ok=1
one() {	# CLOCK_SPEED CLK_MHZ -> the result line
	local v="$WORK/psram_$1_$2.vvp"
	iverilog -g2012 -o "$v" -P tb_psram.CLOCK_SPEED="$1" -P tb_psram.CLK_MHZ="$2" "$PSRAM" "$HERE/tb_psram.sv"
	vvp -n "$v" | grep -E "^(CLOCK_SPEED|  reads|result)"
}
echo "=== CLOCK_SPEED = 28.636364, as the design sets it"
for mhz in 28.636364 21.477273 21.281; do
	out="$(one 28.636364 "$mhz")"
	echo "$out" | grep -v "^result"
	echo "$out" | grep -q "^result: reads=[1-9][0-9]* read_clocks=5.00 writes=[1-9][0-9]* write_clocks=5.00 distinct=1" || ok=0
done
echo "=== CLOCK_SPEED set to the clock it runs on (not used)"
for mhz in 21.477273 21.281 14.318181; do one "$mhz" "$mhz" | grep -v "^result"; done
[ $ok = 1 ] && echo "PASS: 5 clocks per read and per write at CLOCK_SPEED = 28.636364" || { echo "FAIL"; exit 1; }
