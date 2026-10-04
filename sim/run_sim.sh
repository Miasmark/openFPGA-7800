#!/bin/bash
# Build and run the whole-core simulation (tested with Verilator 5.040;
# point VERILATOR at the binary if it is not the one on PATH).
#   ./run_sim.sh [AUDF...]     default: 0 7 14 31
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="$HERE/../src/fpga"
RTL="$FPGA/mister/rtl"
WORK="${WORK:-$HERE/work}"
mkdir -p "$WORK/rtl"

# Quartus 21.1 ignores an initializer on an output port declaration
# (`output logic x = 1'b0`, `output reg x = 0`) and, with Power-Up Don't
# Care, picks the power-up level itself: a sticky flag became a constant 1
# (docs/DEVELOPING.md, "Power-up values"). Simulation honours the
# initializer, so it cannot see this; refuse such declarations in the
# Pocket's own RTL.
if grep -nE '^\s*output\s+(logic|reg)\b[^;/]*=' "$FPGA"/core/*.v "$FPGA"/core/*.sv "$FPGA"/core/bupchip/*.sv; then
	echo "run_sim.sh: an output port above has an initializer, which Quartus ignores; use an initial block" >&2
	exit 1
fi

# The MiSTer sources load their ROM/palette images from "rtl/..." relative
# to the working directory.
for f in palettes Minnie ooo.hex; do
	ln -sfn "$RTL/$f" "$WORK/rtl/$f"
done
ln -sfn "$FPGA/core/ar_stub.hex" "$WORK/rtl/ar_stub.hex"

# Verilator (5.040) rejects initialised unpacked `wire` arrays, which
# upstream uses for constant tables and Quartus accepts. Simulate copies with
# those declarations as `logic`; the sources themselves are not touched.
PATCHED="$WORK/patched"
mkdir -p "$PATCHED"
for f in Maria/control.sv banks2600.sv video_mux.sv RIOT/M6532.sv; do
	mkdir -p "$PATCHED/$(dirname "$f")"
	sed -E 's/^(\s*)wire(\s+\[[^]]+\]\s+\w+\s*\[[0-9]+\]\s*=)/\1logic\2/' "$RTL/$f" > "$PATCHED/$f"
done
# paddles.sv assigns its `output charged` (a wire) from an always block,
# which Quartus allows and Verilator does not.
sed -E 's/^(\s*)output(\s+)charged,/\1output logic\2charged,/' "$RTL/paddles.sv" > "$PATCHED/paddles.sv"

# The Pocket build uses upstream's POKEY (rtl/Pokey). POKEY=watson builds
# Mark Watson's VHDL one (rtl/PokeyWatson, behind core/pokey_adapter_watson.sv)
# instead, as releases up to 2.0.20 did. Verilator reads no VHDL, so GHDL
# (4.x) converts it to Verilog first. run_pokey_shadow.sh needs that file.
if [ "${POKEY:-new}" = watson ]; then
	POKEY_SRCS=("$WORK/pokey_watson.v" "$FPGA/core/pokey_adapter_watson.sv")
else
	POKEY_SRCS=($(ls "$RTL"/Pokey/*.sv))
fi
if [ "${POKEY:-new}" = watson ] && { [ ! -f "$WORK/pokey_watson.v" ] || [ -n "$(find "$RTL/PokeyWatson" -newer "$WORK/pokey_watson.v")" ]; }; then
	command -v ghdl >/dev/null || { echo "needs ghdl (apt install ghdl)"; exit 1; }
	mkdir -p "$WORK/ghdl"
	(cd "$WORK/ghdl" && rm -f ./*.cf && ghdl -a --std=08 -fsynopsys "$RTL"/PokeyWatson/*.vhd* 2>/dev/null \
		&& ghdl --synth --std=08 -fsynopsys --out=verilog pokey_watson > "$WORK/pokey_watson.v" 2>/dev/null) \
		|| { echo "ghdl conversion of PokeyWatson failed"; exit 1; }
fi

SRCS=(
	"$HERE/sim_stubs.sv"
	"$RTL/arm7tdmi/arm7tdmi_pkg.sv"
	"$RTL/6502/mos6502_pkg.sv"
	$(ls "$RTL"/6502/*.sv | grep -v pkg)
	$(ls "$RTL"/Maria/*.sv | grep -v control.sv) "$PATCHED/Maria/control.sv"
	"${POKEY_SRCS[@]}"
	$(sed -n 's/.*qip_path) \(.*\.sv\) *\].*/\1/p' "$RTL/Minnie/Minnie.qip" | sed "s#^#$RTL/Minnie/#")
	"$RTL/SN76489/sn76489.sv"
	"$RTL"/jt51/*.v
	"$RTL/cache_ram.v" "$RTL/bram.v"
	"$RTL/composite_out.sv" "$RTL/cart_ram_tdp.sv" "$RTL/cdf_fastjump_table.sv"
	"$RTL"/arm_mapper_{memory,controller,subsystem,tables,ram_init,writeback,audio}.sv
	"$RTL"/mapper_{dpcplus,cdf,bus,fa2}.sv "$RTL/fa2_nvram_bridge.sv"
	"$RTL/ps2_to_pokey.v" "$RTL/souper.v" "$RTL/TIA.sv" "$RTL/cart.sv"
	"$RTL/cart2600.sv" "$PATCHED/banks2600.sv" "$PATCHED/video_mux.sv"
	"$RTL/detect2600.sv" "$RTL/a78_cart_extent.sv" "$PATCHED/RIOT/M6532.sv"
	"$RTL/top.sv"
	"$RTL/EEPROM_24LC256.sv" "$FPGA/core/atari7800_pocket.sv"
	"$FPGA/core/virtual_axis.sv" "$FPGA/core/stick_dirs.sv" "$FPGA/core/sram_ctrl.sv" "$PATCHED/paddles.sv" "$RTL/lightgun.sv"
	"$FPGA/pocket_utils/data_loader.sv"
	"$FPGA/core/audio_filter.sv"
	"$RTL/bupchip_peripheral.sv" "$FPGA/pocket_utils/psram.sv"
	"$FPGA"/core/bupchip/{bup_cpu,bup_capture,bup_asset_wr,bup_asset_cache,bup_tick48k,bup_load_probe,bup_status_osd,bupchip_pocket}.sv
	"$HERE/bupchip/s4/psram_model.sv"
)

# The POCKET_SRAM build (cartridge RAM, Flicker Blend frame, SaveKey and BIOS
# in the Pocket's SRAM; no memory editor), as the qsf defines it. SRAM=0
# builds the block RAM version instead.
SRAM_DEFS=""
# KEEP_NOCART_ROM keeps the built-in cartridge image tb_system runs from.
[ "${SRAM:-1}" = 1 ] && SRAM_DEFS="-DPOCKET_SRAM -DEXTERNAL_CARTRAM -DNO_MEM_EDITOR -DKEEP_NOCART_ROM"
# The Pocket's BupChip (ARIA, docs/BUPCHIP_CORE.md), and BUP_DEBUG when the
# qsf sets it (hardware test builds); the testbenches put the PSRAM model on
# cram0. BUP_DEBUG=1 or 0 overrides the qsf; BUPCHIP=0 leaves out the whole
# BupChip.
QSF_BUP_DEBUG=0
grep -q '^set_global_assignment -name VERILOG_MACRO "BUP_DEBUG=1"' "$FPGA/ap_core.qsf" && QSF_BUP_DEBUG=1
BUP_DEFS=""
if [ "${BUPCHIP:-1}" = 1 ]; then
	BUP_DEFS="-DPOCKET_BUPCHIP"
	[ "${BUP_DEBUG:-$QSF_BUP_DEBUG}" = 1 ] && BUP_DEFS="$BUP_DEFS -DBUP_DEBUG"
fi

build() {   # build <top> <objdir>
	"${VERILATOR:-verilator}" --binary --timing -j 4 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD \
		-DNO_ARM_MAPPER -DNO_BUPCHIP -DNO_DDRAM -DEXTERNAL_FIRMWARE -DEEPROM_NACK_ENDS_READ -DPOCKET_SUPERCHARGER \
		$SRAM_DEFS $BUP_DEFS \
		--top-module "$1" -Mdir "$WORK/$2" -o vtb "${SRCS[@]}" "$HERE/$1.sv" > "$WORK/$2.log" 2>&1 \
		|| { grep -m20 "%Error" "$WORK/$2.log"; exit 1; }
}
build tb_system obj
build tb_load obj_load

cd "$WORK"
for audf in ${@:-0 7 14 31}; do
	rm -f rtl/mem0.hex   # may be a link to the upstream file: never write through it
	python3 "$HERE/tone_test.py" "$audf" > rtl/mem0.hex
	out=$(./obj/vtb +audf="$audf")
	echo "$out" | grep TONE; echo "$out" | grep FRAME | tail -1
done
echo "-- border hidden:"
./obj/vtb +audf=0 +hide_border | grep FRAME | tail -1
echo "-- 2600 mode (TIA video, stabilised):"
for audf in 0 14; do
	rm -f rtl/mem0.hex
	python3 "$HERE/tone_test.py" "$audf" 2600 > rtl/mem0.hex
	out=$(./obj/vtb +audf="$audf" +mode2600)
	echo "$out" | grep TONE; echo "$out" | grep FRAME | tail -1
done

echo "-- PAL and overscan geometry (expect 274 / 242 / 274 lines: PAL ignores overscan; video PAL flag set for PAL):"
rm -f rtl/mem0.hex; python3 "$HERE/tone_test.py" 7 > rtl/mem0.hex
for opt in "+pal" "+overscan" "+overscan +pal"; do
	echo "  $opt: $(./obj/vtb +audf=7 $opt | grep FRAME | tail -1 | sed 's/^FRAME [0-9]*: //')"
done
echo "-- PAL 2600 frame, after region detection (expect 288 lines, video PAL 1):"
rm -f rtl/mem0.hex; python3 "$HERE/tone_test.py" 14 2600 pal > rtl/mem0.hex
./obj/vtb +audf=14 +mode2600 +long | grep FRAME | tail -1
rm -f rtl/mem0.hex

echo "-- load an A78 through the APF data loader:"
ln -sfn "$RTL/mem0.hex" rtl/mem0.hex     # upstream's built-in image: no tone
python3 "$HERE/make_a78.py" 7 > load_test.a78
./obj_load/vtb +image=load_test.a78 +audf=7 | grep -E "LOAD|TONE|HSC"

echo "-- load a headerless 2600 image (4 KiB):"
python3 "$HERE/tone_test.py" 14 2600 | head -4096 | python3 -c "import sys;sys.stdout.buffer.write(bytes(int(l,16) for l in sys.stdin))" > load_test.a26
./obj_load/vtb +image=load_test.a26 +audf=14 | grep -E "LOAD|TONE"

# The BupChip end to end in the whole core: its firmware through the
# bupchip.bin data slot (after the cartridge, in data.json's order, as the
# Pocket loads them), a Souper cartridge (souper_test.py: a 6502 program
# that sends command $80 through $8007 after 30 ms) with the synthetic ARSC
# block appended, the PSRAM model on cram0. The song's PCM, as the firmware
# pushes it and as it returns to clk_sys, must equal the Python model's
# (sim/bupchip/model/armemu.py), and its audio must reach top.sv's mixer.
# Without the firmware, the same cartridge must leave the BupChip held and
# silent. Needs the user's firmware at src/fpga/mister/rtl/bupchip.hex
# (docs/BUPCHIP.md); skipped without it. BUPMS sets the run (ms after reset).
if [ "${BUPCHIP:-1}" = 1 ]; then
	if [ -f "$RTL/bupchip.hex" ]; then
		echo "-- BupChip end to end: firmware slot, Souper cartridge with an ARSC block, \$8007 command, PSRAM:"
		B="$WORK/bupchip_e2e"
		mkdir -p "$B"; ln -sfn "$WORK/rtl" "$B/rtl"
		python3 "$HERE/../tools/hex2bin.py" "$RTL/bupchip.hex" > "$B/bupchip.bin"
		python3 "$HERE/bupchip/verif/make_synth_arsc.py" "$B/synth.a78" --arsc "$B/synth.arsc" > /dev/null
		python3 "$HERE/souper_test.py" "$B/souper.a78" --arsc "$B/synth.arsc" > /dev/null
		[ -s "$B/song0_model.pcm" ] && [ "$B/song0_model.pcm" -nt "$B/synth.arsc" ] || \
			(cd "$HERE/bupchip/model" && python3 armemu.py "$B/synth.arsc" --song 0 --secs 1 --pcm "$B/song0_model.pcm" > "$B/armemu.log")
		(cd "$B" && ./../obj_load/vtb +image=souper.a78 +bupfw=bupchip.bin +bupfwlast +bupms="${BUPMS:-250}" +bupout=e2e > e2e.log)
		grep -E "^(LOAD|BUPCHIP)" "$B/e2e.log"
		PS="$(sed -n 's/^BUPCHIP song start: pushed \([0-9-]*\), output \([0-9-]*\)$/\1/p' "$B/e2e.log")"
		OS="$(sed -n 's/^BUPCHIP song start: pushed \([0-9-]*\), output \([0-9-]*\)$/\2/p' "$B/e2e.log")"
		e2e_ok=1
		grep -Eq "^BUPCHIP firmware slot: [0-9]+ byte file, 0 of 4096 ROM words differ from it, fw_loaded=1$" "$B/e2e.log" || e2e_ok=0
		grep -Eq "^BUPCHIP ARSC: [0-9]+ bytes in the PSRAM, 0 differ from the file; asset_size [0-9]+, asset_ready 1$" "$B/e2e.log" || e2e_ok=0
		grep -Eq "^BUPCHIP result: fw_loaded=1 asset_ready=1 cpu_run=1 halted=0 halt_code=0 halt_pc=[0-9a-f]+ fault=00 muted=0 pushed=[0-9]+ pops=[0-9]+ under=0 over=0 minlev=[0-9]+ out=[0-9]+ out_nz=[1-9][0-9]* mix_nz=[1-9][0-9]* arsc_bad=0 psram_viol=0$" "$B/e2e.log" || e2e_ok=0
		for k in pcm out.pcm; do
			[ "$k" = pcm ] && { st="$PS"; echo "  pushed frames against the model:"; } \
				|| { st="$OS"; echo "  frames returned to clk_sys against the model:"; }
			python3 "$HERE/bupchip/s1/pcm_check.py" "$B/e2e.$k" "$B/song0_model.pcm" --song-start "${st:--1}" \
				> "$B/check_$k.log" 2>&1 || e2e_ok=0
			sed 's/^/    /' "$B/check_$k.log"
			grep -q "^PCM IDENTICAL" "$B/check_$k.log" || e2e_ok=0
		done
		echo "  the same cartridge without the firmware (expect fw_loaded=0 cpu_run=0 pushed=0 out_nz=0 mix_nz=0):"
		(cd "$B" && ./../obj_load/vtb +image=souper.a78 +bupms=40 > nofw.log)
		grep "^BUPCHIP result" "$B/nofw.log" | sed 's/^/    /'
		grep -Eq "^BUPCHIP result: fw_loaded=0 asset_ready=1 cpu_run=0 halted=0 .* pushed=0 pops=0 under=0 over=0 .* out_nz=0 mix_nz=0 arsc_bad=0 psram_viol=0$" "$B/nofw.log" || e2e_ok=0
		[ "$e2e_ok" = 1 ] && echo "BUPCHIP_E2E pass" || echo "BUPCHIP_E2E FAIL"
	else
		echo "-- BupChip end to end: skipped (no firmware at src/fpga/mister/rtl/bupchip.hex; see docs/BUPCHIP.md)"
	fi
fi

echo "-- PAL/NTSC PLL retune sequence:"
"${VERILATOR:-verilator}" --binary --timing -Wno-fatal -Wno-lint --top-module tb_pll_region \
	-Mdir "$WORK/obj_pllr" -o vtb "$FPGA/core/pll_region.v" "$HERE/tb_pll_region.sv" > "$WORK/obj_pllr.log" 2>&1 \
	|| { grep -m20 "%Error" "$WORK/obj_pllr.log"; exit 1; }
./obj_pllr/vtb | grep -E "fraction|PLL_REGION|FAIL"

echo "-- audio filter:"
"${VERILATOR:-verilator}" --binary --timing -O2 -Wno-fatal -Wno-lint --top-module tb_audio_filter \
	-Mdir "$WORK/obj_af" -o vtb "$FPGA/core/audio_filter.sv" "$HERE/tb_audio_filter.sv" > "$WORK/obj_af.log" 2>&1 \
	|| { grep -m20 "%Error" "$WORK/obj_af.log"; exit 1; }
./obj_af/vtb | grep AUDIO

echo "-- virtual paddle / driving / light-gun axis:"
"${VERILATOR:-verilator}" --binary --timing -Wno-fatal -Wno-lint --top-module tb_virtual_axis \
	-Mdir "$WORK/obj_va" -o vtb "$FPGA/core/virtual_axis.sv" "$HERE/tb_virtual_axis.sv" > "$WORK/obj_va.log" 2>&1 \
	|| { grep -m20 "%Error" "$WORK/obj_va.log"; exit 1; }
./obj_va/vtb | grep AXIS
