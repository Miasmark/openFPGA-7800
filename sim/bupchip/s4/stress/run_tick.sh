#!/bin/bash
# bup_tick48k across the clk_74a -> clk_arm crossing (tb_tick.sv; step 4 of
# docs/BUPCHIP_CORE.md): clk_arm at 28.636, 21.477 and 21.281 MHz against
# clk_74a at 74.25 MHz, +-100 ppm off, with random phases and edge jitter.
# Every toggle flip must give exactly one one-clock tick, 2-4 clk_arm edges
# later, and the flips must come every 1,546.875 clk_74a clocks (48 kHz).
#   ./run_tick.sh            (iverilog; about 1 minute)
# Environment: WORK (default sim/work/bupchip/s4stress).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
mkdir -p "$WORK"
iverilog -g2012 -o "$WORK/tick.vvp" "$CORE/bup_tick48k.sv" "$HERE/tb_tick.sv"
ok=1
s=1
for mhz in 28.636364 21.477273 21.281; do
	for ppm in 0 100 -100; do
		for j in "0 0" "1500 2500"; do
			set -- $j
			s=$((s + 1))
			res="$(nice -n "${NICE:-5}" vvp -n "$WORK/tick.vvp" +arm_mhz="$mhz" +ppm="$ppm" +jit74="$1" +jitarm="$2" +seed="$s" +ms=30 \
				| grep "^result:")"
			if python3 - "$res" <<'PY'
import re, sys
d = dict(re.findall(r"(\w+)=([-0-9.]+)", sys.argv[1]))
f, t, p, b, per = int(d["flips"]), int(d["ticks"]), int(d["pending"]), int(d["bad"]), float(d["per"])
sys.exit(0 if b == 0 and f == t + p and p <= 1 and f > 1000 and abs(per - 1546.875) < 0.002 else 1)
PY
			then echo "PASS clk_arm $mhz MHz, clk_74a $ppm ppm, jitter $1/$2 ps: ${res#result: }"
			else echo "FAIL clk_arm $mhz MHz, clk_74a $ppm ppm, jitter $1/$2 ps: ${res#result: }"; ok=0; fi
		done
	done
done
[ "$ok" = 1 ] && echo "run_tick.sh: all passed" || echo "run_tick.sh: FAILED"
[ "$ok" = 1 ]
