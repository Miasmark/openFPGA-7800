#!/bin/bash
# Every step 4 stress run (README.md here), one after another:
# run_cstress.sh (the asset cache), run_capstress.sh (the download path and
# its crossing), run_tick.sh (the 48 kHz tick's crossing), run_bounds.sh (the
# asset window's bounds through the whole wrapper), run_pophead.sh (the PCM
# FIFO's head race through the whole wrapper), run_xing.sh (the command,
# frame, tick and pause crossings through the whole wrapper, synchronous and
# asynchronous clk_arm) and run_reload.sh (reloads with different blocks;
# skipped without the firmware).
#   ./run_all.sh
# Environment: WORK (default sim/work/bupchip/s4stress), VERILATOR, NICE.
# About 27 minutes on one core.
HERE="$(cd "$(dirname "$0")" && pwd)"
ok=1
for s in run_cstress.sh run_capstress.sh run_tick.sh run_bounds.sh run_pophead.sh run_xing.sh run_reload.sh; do
	echo "=== $s"
	"$HERE/$s" || ok=0
done
echo
[ "$ok" = 1 ] && echo "stress: all passed" || echo "stress: FAILED"
[ "$ok" = 1 ]
