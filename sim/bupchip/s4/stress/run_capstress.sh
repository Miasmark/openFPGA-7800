#!/bin/bash
# The download path of step 4 under stress (tb_capstress.sv; docs/
# BUPCHIP_CORE.md, "Capture"): bup_capture, the message crossing,
# bup_asset_wr and psram.sv on psram_model.sv, with random cartridge and
# firmware downloads at the loader's fastest legal rate and slower, back to
# back, odd and line-boundary block lengths, a reader standing in for the
# cache, and clk_arm at 2 x and 1.5 x clk_sys (NTSC and PAL) and
# asynchronous at 16-29 MHz with jitter. Then the runs that must fail: one
# byte every 2 clk_sys (lost must rise) and clk_arm at 12.2 MHz (overrun must
# rise). Then +b2bfw / +xstream: a firmware download starting in the clock
# after a cartridge's ends, while the cartridge's tail WRITE and END still
# wait (README.md, "Findings" 1: bup_capture sent FWWRITE at once and broke
# the 5-clock spacing; it now queues it). Last, +fwrise: the firmware's first
# byte in the clock fw_download rises (finding 4: that byte was dropped),
# and +fwfall: the last byte in the clock it falls (a tail FWWRITE used to
# rewrite that word with a zero byte).
#   ./run_capstress.sh
# Environment: N (downloads per run, default 300), CAPTURE (another
# bup_capture.sv to test, e.g. a fix), WORK (default
# sim/work/bupchip/s4stress), VERILATOR. About 3 minutes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
PU="$(cd "$HERE/../../../../src/fpga/pocket_utils" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
N="${N:-300}"
CAPTURE="$(realpath "${CAPTURE:-$CORE/bup_capture.sv}")"
OBJ="$WORK/obj_cap_real"
[ "$CAPTURE" = "$CORE/bup_capture.sv" ] || OBJ="$WORK/obj_cap_alt"
SRCS=("$CAPTURE" "$CORE/bup_asset_wr.sv" "$PU/psram.sv" "$HERE/../psram_model.sv" "$HERE/tb_capstress.sv")
if [ "$CAPTURE" != "$CORE/bup_capture.sv" ] || ! [ -x "$OBJ/vtb" ] || [ -n "$(find "${SRCS[@]}" "$0" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	rm -rf "$OBJ"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module tb_capstress -Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
		|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
	find "$OBJ" \( -name '*.gch' -o -name '*.o' \) -delete
fi
ok=1
run() {         # run NAME EXPECT(pass|lost|overrun|cross) plusargs...
	local name="$1" exp="$2" log res
	shift 2
	log="$WORK/cap_$name.log"
	[ "$CAPTURE" = "$CORE/bup_capture.sv" ] || log="$WORK/cap_alt_$name.log"
	nice -n "${NICE:-5}" "$OBJ/vtb" +n="$N" "$@" | grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " > "$log"
	res="$(grep "^result:" "$log" || echo "result: none")"
	local clean="^result: checks=[1-9][0-9]* bad=0 rdbad=0 nrd=[1-9][0-9]* seq=0 order=0 lost=0 lost_s=0 lost_x=0 overrun=0 viol=0$"
	local r=0
	case "$exp" in
		pass)    grep -Eq "$clean" <<< "$res" && r=1 ;;
		lost)    grep -Eq " lost=1 lost_s=[1-9]" <<< "$res" && r=1 ;;
		overrun) grep -Eq " overrun=1 " <<< "$res" && r=1 ;;
		cross)   grep -Eq "^result: checks=[1-9][0-9]* bad=0 rdbad=0 nrd=[0-9]+ seq=0 order=0 lost=[01] lost_s=0 lost_x=[0-9]+ overrun=0 viol=0$" <<< "$res" && r=1 ;;
		xhit)    grep -Eq "^result: checks=[1-9][0-9]* bad=0 rdbad=0 nrd=[0-9]+ seq=0 order=0 lost=1 lost_s=0 lost_x=[1-9][0-9]* overrun=0 viol=0$" <<< "$res" && r=1 ;;
	esac
	# +fwrise runs must have had downloads with byte 0 in the rising clock
	case "$*" in *+fwrise*) grep -Eq "; [1-9][0-9]* firmware downloads with byte 0" "$log" || r=0 ;; esac
	case "$*" in *+fwfall*) grep -Eq "; [1-9][0-9]* with the last byte in the clock it fell" "$log" || r=0 ;; esac
	if [ "$r" = 1 ]; then echo "PASS $name ($exp): ${res#result: }"
	else echo "FAIL $name ($exp): ${res#result: } ($log)"; ok=0; fi
	grep -E "^capture stress" "$log" | sed 's/^/  /'
}
run sync2x        pass +seed=1
run sync15x       pass +seed=2 +ratio=15
run sync15x_pal   pass +seed=3 +ratio=15 +pal
run sync2x_pal    pass +seed=4 +pal
run async_21m25   pass +seed=5 +async +arm_ps=23529 +armjit=3000
run async_28m9    pass +seed=6 +async +arm_ps=17300 +armjit=500
run async_16m     pass +seed=7 +async +arm_ps=31250 +armjit=4000
run async_21m28_p pass +seed=8 +async +arm_ps=23495 +armjit=200 +pal
run fast_loader   lost +seed=9 +fast
run async_12m2    overrun +seed=10 +async +arm_ps=41000
run b2bfw_sync15x pass +seed=11 +ratio=15 +b2bfw
run xstream_2x    pass +seed=12 +xstream
run xstream_15x   pass +seed=13 +ratio=15 +xstream
run xstream_async pass +seed=14 +async +arm_ps=23529 +armjit=3000 +xstream
run fwrise_2x     pass +seed=15 +fwrise
run fwrise_xstream pass +seed=16 +ratio=15 +xstream +fwrise
run fwfall_2x     pass +seed=17 +fwfall
run fwfall_15x_pal pass +seed=18 +ratio=15 +pal +fwfall
[ "$ok" = 1 ] && echo "run_capstress.sh: all passed" || echo "run_capstress.sh: FAILED"
[ "$ok" = 1 ]
