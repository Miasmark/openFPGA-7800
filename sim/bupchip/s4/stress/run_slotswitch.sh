#!/bin/bash
# The Pocket's data slot sequence into the capture (tb_slotswitch.sv; README.md,
# "Slot switches"): the real data_loader, core_top's slot flags, every slot of
# data.json in order, and the host's next requestwrite or allcomplete
# reaching core_top 400 clk_74a down to 0 after a slot's last bridge write.
# Every run must load the cartridge's block and bupchip.bin exactly, with
# seq_err, lost and overrun low and no byte dropped; then the same with
# bytes taken by slot flag, as before the fix, which must raise seq_err at a
# 20-clock gap (the hardware test's red box).
#   ./run_slotswitch.sh
# Environment: WORK (default sim/work/bupchip/s4stress), VERILATOR. About a
# minute.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
PU="$(cd "$HERE/../../../../src/fpga/pocket_utils" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OBJ="$WORK/obj_slotsw"
SRCS=("$CORE/bup_capture.sv" "$CORE/bup_asset_wr.sv" "$CORE/bup_load_probe.sv" "$PU/psram.sv"
	"$PU/data_loader.sv" "$HERE/../psram_model.sv" "$HERE/tb_slotswitch.sv")
if ! [ -x "$OBJ/vtb" ] || [ -n "$(find "${SRCS[@]}" "$0" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	rm -rf "$OBJ"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module tb_slotswitch -Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
		|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
	find "$OBJ" \( -name '*.gch' -o -name '*.o' \) -delete
fi
ok=1 n=0
run() {         # run NAME EXPECT(pass|seq) plusargs...
	local name="$1" exp="$2" log res r=0
	shift 2
	log="$WORK/slotsw_$name.log"
	nice -n "${NICE:-5}" "$OBJ/vtb" "$@" | grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " > "$log"
	res="$(grep "^result:" "$log" || echo "result: none")"
	case "$exp" in
		pass) grep -Eq "^result: seq_err=0 lost=0 overrun=0 rom_bad=0 ps_bad=0 asset_size=($([ "$1" = +nomusic ] && echo 0 || echo 1500)) asset_ready=[01] fw_loaded=1 " <<< "$res" \
			&& grep -q " dropped=0 " "$log" && r=1 ;;
		seq)  grep -Eq "^result: seq_err=1 " <<< "$res" && r=1 ;;
	esac
	n=$((n + 1))
	if [ $r = 1 ]; then echo "PASS $name"; else ok=0; echo "FAIL $name ($exp): $res"; fi
}
for g in 400 60 40 30 20 10 0; do
	run "gap$g" pass +gap=$g
	run "nomusic_gap$g" pass +nomusic +gap=$g
done
for g in 30 10 0; do
	run "fwfirst_gap$g" pass +fwfirst +gap=$g
	run "noslots_gap$g" pass +slots=0 +gap=$g		# the cartridge, then bupchip.bin straight away
	run "pre20_gap$g" pass +pre=20 +gap=$g			# the next slot's first word close behind its request
	run "word60_gap$g" pass +word=60 +gap=$g
	run "sync5_gap$g" pass +sync=5 +gap=$g
done
run flags_gap20 seq +flags +gap=20
run flags_nomusic_gap20 seq +flags +nomusic +gap=20
echo "$n runs; logs in $WORK/slotsw_*.log"
[ $ok = 1 ] && echo "run_slotswitch: all as expected" || { echo "run_slotswitch: FAILED"; exit 1; }
