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

# The MiSTer sources load their ROM/palette images from "rtl/..." relative
# to the working directory.
for f in palettes Minnie ooo.hex; do
	ln -sfn "$RTL/$f" "$WORK/rtl/$f"
done

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

# The Pocket build uses Mark Watson's VHDL POKEY (rtl/PokeyWatson) behind
# core/pokey_adapter_watson.sv. Verilator reads no VHDL, so GHDL (4.x)
# converts it to Verilog first.
if [ ! -f "$WORK/pokey_watson.v" ] || [ -n "$(find "$RTL/PokeyWatson" -newer "$WORK/pokey_watson.v")" ]; then
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
	"$WORK/pokey_watson.v" "$FPGA/core/pokey_adapter_watson.sv"
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
	"$FPGA/core/virtual_axis.sv" "$FPGA/core/stick_dirs.sv" "$PATCHED/paddles.sv" "$RTL/lightgun.sv"
	"$FPGA/pocket_utils/data_loader.sv"
	"$FPGA/core/audio_filter.sv"
)

build() {   # build <top> <objdir>
	"${VERILATOR:-verilator}" --binary --timing -j 4 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
		-DNO_ARM_MAPPER -DNO_BUPCHIP -DNO_DDRAM -DEXTERNAL_FIRMWARE -DEEPROM_NACK_ENDS_READ \
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
