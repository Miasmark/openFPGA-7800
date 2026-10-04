#!/bin/bash
# The step 4 wrapper's other crossings under stress (tb_xing.sv; docs/
# BUPCHIP_CORE.md, "Crossings"): the $8007 command into clk_arm, the audio
# frame back to clk_sys, the 48 kHz tick from clk_74a and pause, through
# bupchip_pocket.sv with the CPU running fw_xing.S, which echoes each command
# with an asset byte and a sequence number as a PCM frame. Commands come in
# bursts at 2-4 clk_sys apart with noise on cmd_data between them; clk_arm
# is 2 x or 1.5 x clk_sys (NTSC and PAL) or asynchronous at 16-29 MHz with
# jitter; clk_74a is off by up to +-200 ppm with jitter. Every command must
# come back once and in order, the tick count must match clk_74a's rate,
# and nothing may pop or sound while paused.
# Then wrappers that must fail:
#   cmd_nohold   the command byte taken from cmd_data at the clk_arm detect
#                instead of the clk_sys register held with the toggle
#   tick_nohold  without tick_hold (pushes into the empty FIFO, one per tick)
#   pause_nogate pops not gated by pause
# Game-free and firmware-free (the program is the firmware).
#   ./run_xing.sh
# Environment: N (commands per run, default 3000), WORK (default
# sim/work/bupchip/s4stress), VERILATOR. Needs arm-none-eabi-gcc. About 5
# minutes.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
RTL="$ROOT/src/fpga/mister/rtl"
CORE="$ROOT/src/fpga/core/bupchip"
LINK="$ROOT/sim/bupchip/verif/isa/link.ld"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK/xing"
WORK="$(cd "$WORK" && pwd)"
X="$WORK/xing"
N="${N:-3000}"

arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -Wl,-T,"$LINK" -Wl,--no-warn-rwx-segments \
	-o "$X/fw.elf" "$HERE/fw_xing.S"
arm-none-eabi-objcopy -O binary -j .vectors -j .text "$X/fw.elf" "$X/fw.bin"

# The mutants.
mutate() {      # mutate NAME SED-EXPRESSION
	sed "$2" "$CORE/bupchip_pocket.sv" > "$X/bupchip_pocket_$1.sv"
	! cmp -s "$CORE/bupchip_pocket.sv" "$X/bupchip_pocket_$1.sv" || { echo "run_xing.sh: mutation $1 did not apply" >&2; exit 1; }
}
mutate cmd_nohold   's|cmd_data_arm <= cmd_byte;|cmd_data_arm <= cmd_data;|'
mutate tick_nohold  's#^\twire         head_ok = !pcm_available || avail_q;#\twire         head_ok = 1'"'"'b1;#'
mutate pause_nogate 's#assign pcm_pop = do_tick && cpu_run && pcm_enabled && !paused;#assign pcm_pop = do_tick \&\& cpu_run \&\& pcm_enabled;#'

build() {       # build NAME POCKET_SRC
	local obj="$X/obj_$1"
	local srcs=("$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/cache_ram.v" "$RTL/bupchip_peripheral.sv"
		"$CORE/bup_cpu.sv" "$CORE/bup_tick48k.sv" "$CORE/bup_capture.sv" "$CORE/bup_asset_wr.sv"
		"$CORE/bup_asset_cache.sv" "$2" "$HERE/../psram_standin.sv" "$HERE/tb_xing.sv")
	if ! [ -x "$obj/vtb" ] || [ -n "$(find "${srcs[@]}" "$0" -newer "$obj/vtb" 2>/dev/null)" ]; then
		rm -rf "$obj"
		nice -n "${NICE:-5}" "$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
			--top-module tb_xing -DBUP_DEBUG -Mdir "$obj" -o vtb "${srcs[@]}" > "$obj.log" 2>&1 \
			|| { grep -E "^%Error" "$obj.log" | head -20 >&2; echo "build failed: $obj.log" >&2; exit 1; }
		find "$obj" \( -name '*.gch' -o -name '*.o' \) -delete
	fi
}
build real "$CORE/bupchip_pocket.sv"
for m in cmd_nohold tick_nohold pause_nogate; do build "$m" "$X/bupchip_pocket_$m.sv"; done

ok=1
run() {         # run NAME BUILD EXPECT(pass|fail) plusargs...
	local name="$1" b="$2" exp="$3" log res
	shift 3
	log="$X/$name.log"
	nice -n "${NICE:-5}" "$X/obj_$b/vtb" +fw="$X/fw.bin" "$@" > "$log" 2>&1 || true
	res="$(grep "^result:" "$log" || echo "result: none")"
	local r=0
	case "$exp" in
		pass) grep -Eq "^result: PASS cmds=$N back=$N bad=0 paused_bad=0 pause_pops=0 " <<< "$res" && r=1 ;;
		fail) grep -Eq "^result: FAIL " <<< "$res" && r=1 ;;
	esac
	# a pause run must have had captures inside its windows
	case "$*" in *+pause*) [ "$exp" = fail ] || grep -Eq "^pause [1-9][0-9]* windows, [1-9][0-9]* captures inside" "$log" || r=0 ;; esac
	if [ "$r" = 1 ]; then echo "PASS $name ($exp): ${res#result: }"
	else echo "FAIL $name ($exp): ${res#result: } ($log)"; ok=0; fi
	grep -E "^(frames|pause|ticks) " "$log" | sed 's/^/  /'
}
run sync2x          real pass +n="$N" +smin=2
run sync15x         real pass +n="$N" +smin=2 +ratio=15 +ppm74=-100 +jit74=1500
run sync2x_pal      real pass +n="$N" +smin=2 +pal +ppm74=200
run sync15x_pal     real pass +n="$N" +smin=2 +ratio=15 +pal +ppm74=-200 +jit74=3000
run async_28m9      real pass +n="$N" +smin=3 +async +arm_ps=17300 +armjit=500 +ppm74=50 +jit74=1000
run async_21m25     real pass +n="$N" +smin=4 +async +arm_ps=23529 +armjit=3000 +ppm74=-50 +jit74=2000
run async_16m       real pass +n="$N" +smin=4 +async +arm_ps=31250 +armjit=4000 +ppm74=150 +jit74=500
run pause_sync2x    real pass +n="$N" +smin=2 +pause
run pause_async     real pass +n="$N" +smin=4 +async +arm_ps=23529 +armjit=3000 +pause +ppm74=-150
run single_sync15x  real pass +n="$N" +smin=2 +ratio=15 +maxburst=1
run single_sync2x_pal real pass +n="$N" +smin=2 +pal +maxburst=1
# must fail
run m_cmd_nohold    cmd_nohold   fail +n="$N" +smin=2
run m_tick_nohold   tick_nohold  fail +n=$((2 * N)) +smin=2 +maxburst=1
run m_pause_nogate  pause_nogate fail +n="$N" +smin=2 +pause
[ "$ok" = 1 ] && echo "run_xing.sh: all passed" || echo "run_xing.sh: FAILED"
[ "$ok" = 1 ]
