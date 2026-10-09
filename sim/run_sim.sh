#!/bin/bash
# Build and run the whole-core simulation (tested with Verilator 5.040;
# point VERILATOR at the binary if it is not the one on PATH).
#   ./run_sim.sh [AUDF...]     default: 0 7 14 31
# Environment (all optional; without them the runs are as they always were):
#   WORK=DIR       work directory (default sim/work)
#   VERILATOR=BIN  the Verilator to use (5.040; PATH's otherwise)
#   VL_JOBS=N      build parallelism (default 4)
#   DARIA=0|1      POCKET_DARIA off or on; default: as ap_core.qsf sets it
#   BUP_DEBUG=0|1, BUPCHIP=0, SRAM=0, POKEY=watson: as below
#   BIOS=FILE      the 7800 BIOS for the BIOS boot tests (below)
#   BUPFW=FILE     the BupChip firmware (default src/fpga/mister/rtl/bupchip.hex)
#   FP=1           every run also writes its per-frame fingerprint (tb_load's
#                  and tb_system's +fp) to $WORK/fp/<case>.csv, for comparing
#                  two builds frame by frame (sim/check/frame_gate.py --strict)
#   ARM_DIV=19     the DARIA build's clk_arm at VCO/19 instead of VCO/18
#   RTL_TREE=DIR   build the RTL of another checkout (DIR/src/fpga) with this
#                  checkout's benches, e.g. a lane's worktree
#   BUILD_TOP=TOP  only build the bench TOP (tb_system, tb_load or
#                  tb_cartram) into $WORK/obj_TOP and stop
# The checker sim/check/run_sim_check.py turns this script's output into one
# exit code.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="${RTL_TREE:-$HERE/..}/src/fpga"
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
# DARIA (docs/DARIA_CORE.md; POCKET_DARIA needs POCKET_BUPCHIP): read from the
# qsf as BUP_DEBUG is; DARIA=1 or 0 overrides it. The DARIA build adds the
# daria_* sources, the front end's package first. daria_smp.sv and
# bup_dbg_snap.sv join when they exist (step 7 adds them).
QSF_DARIA=0
grep -q '^set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"' "$FPGA/ap_core.qsf" && QSF_DARIA=1
DARIA_ON=0
if [ "${BUPCHIP:-1}" = 1 ] && [ "${DARIA:-$QSF_DARIA}" = 1 ]; then
	DARIA_ON=1
	BUP_DEFS="$BUP_DEFS -DPOCKET_DARIA"
	B="$FPGA/core/bupchip"
	SRCS+=("$B/daria_fe_pkg.sv" "$B/daria_mem.sv" "$B/daria_call.sv" "$B/daria_mmio.sv")
	for f in daria_smp bup_dbg_snap; do [ -f "$B/$f.sv" ] && SRCS+=("$B/$f.sv"); done
	SRCS+=($(ls "$B"/daria_fe_*.sv | grep -v daria_fe_pkg.sv) "$B/daria_fe.sv")
	# The DARIA section's taps need daria_fe in the wrapper as u_fe (plan P14)
	grep -qE '^\s*daria_fe\b[^;]*\bu_fe\b' "$FPGA/core/atari7800_pocket.sv" && BUP_DEFS="$BUP_DEFS -DSIM_DARIA_FE"
fi
# Fix B's P2 assertion in the benches (docs/daria_step7/plan.md P2): on when
# sram_ctrl.sv has Fix B's two requests, m_new and t_new.
SIM_DEFS=""
grep -qE '\bt_new\b' "$FPGA/core/sram_ctrl.sv" && grep -qE '\bm_new\b' "$FPGA/core/sram_ctrl.sv" && SIM_DEFS="-DSIM_FIXB"
ARMDIV_ARG=""
[ "$DARIA_ON" = 1 ] && [ -n "${ARM_DIV:-}" ] && ARMDIV_ARG="+arm_div=$ARM_DIV"
# fp CASE: the plusargs every run gets: its fingerprint file with FP=1, and
# the DARIA build's clk_arm divider with ARM_DIV.
fp() { [ "${FP:-0}" = 1 ] && printf '%s ' "+fp=$WORK/fp/$1.csv"; printf '%s' "$ARMDIV_ARG"; }
[ "${FP:-0}" = 1 ] && mkdir -p "$WORK/fp"

build() {   # build <top> <objdir> [more bench sources]
	local top="$1" obj="$2"; shift 2
	"${VERILATOR:-verilator}" --binary --timing -j "${VL_JOBS:-4}" -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD \
		-DNO_ARM_MAPPER -DNO_BUPCHIP -DNO_DDRAM -DEXTERNAL_FIRMWARE -DEEPROM_NACK_ENDS_READ -DPOCKET_SUPERCHARGER \
		$SRAM_DEFS $BUP_DEFS $SIM_DEFS \
		--top-module "$top" -Mdir "$WORK/$obj" -o vtb "${SRCS[@]}" "$@" "$HERE/$top.sv" > "$WORK/$obj.log" 2>&1 \
		|| { grep -m20 "%Error" "$WORK/$obj.log"; exit 1; }
}
echo "-- run_sim.sh: VERILATOR ${VERILATOR:-verilator} ($("${VERILATOR:-verilator}" --version)), RTL $(cd "$FPGA/../.." && pwd), POCKET_DARIA $DARIA_ON, defines:$SRAM_DEFS $BUP_DEFS $SIM_DEFS"
if [ -n "${BUILD_TOP:-}" ]; then
	case "$BUILD_TOP" in
		tb_cartram) o=obj_cartram; build tb_cartram $o "$HERE/tb_load.sv" ;;
		tb_system) o=obj; build tb_system $o ;;
		tb_load) o=obj_load; build tb_load $o ;;
		*) echo "run_sim.sh: BUILD_TOP=$BUILD_TOP: tb_system, tb_load or tb_cartram" >&2; exit 1 ;;
	esac
	echo "-- built $BUILD_TOP: $o/vtb md5 $(md5sum < "$WORK/$o/vtb" | cut -d' ' -f1)"
	exit 0
fi
build tb_system obj
build tb_load obj_load
echo "-- built: obj/vtb md5 $(md5sum < "$WORK/obj/vtb" | cut -d' ' -f1), obj_load/vtb md5 $(md5sum < "$WORK/obj_load/vtb" | cut -d' ' -f1)"

cd "$WORK"
for audf in ${@:-0 7 14 31}; do
	rm -f rtl/mem0.hex   # may be a link to the upstream file: never write through it
	python3 "$HERE/tone_test.py" "$audf" > rtl/mem0.hex
	out=$(./obj/vtb +audf="$audf" $(fp tone_$audf))
	echo "$out" | grep TONE; echo "$out" | grep FRAME | tail -1
done
echo "-- border hidden:"
./obj/vtb +audf=0 +hide_border $(fp border) | grep FRAME | tail -1
echo "-- 2600 mode (TIA video, stabilised):"
for audf in 0 14; do
	rm -f rtl/mem0.hex
	python3 "$HERE/tone_test.py" "$audf" 2600 > rtl/mem0.hex
	out=$(./obj/vtb +audf="$audf" +mode2600 $(fp mode2600_$audf))
	echo "$out" | grep TONE; echo "$out" | grep FRAME | tail -1
done

echo "-- PAL and overscan geometry (expect 274 / 242 / 274 lines: PAL ignores overscan; video PAL flag set for PAL):"
rm -f rtl/mem0.hex; python3 "$HERE/tone_test.py" 7 > rtl/mem0.hex
for opt in "+pal" "+overscan" "+overscan +pal"; do
	echo "  $opt: $(./obj/vtb +audf=7 $opt $(fp geom_$(echo $opt | tr -d '+ ')) | grep FRAME | tail -1 | sed 's/^FRAME [0-9]*: //')"
done
echo "-- PAL 2600 frame, after region detection (expect 288 lines, video PAL 1):"
rm -f rtl/mem0.hex; python3 "$HERE/tone_test.py" 14 2600 pal > rtl/mem0.hex
./obj/vtb +audf=14 +mode2600 +long $(fp pal2600) | grep FRAME | tail -1
rm -f rtl/mem0.hex

echo "-- load an A78 through the APF data loader:"
ln -sfn "$RTL/mem0.hex" rtl/mem0.hex     # upstream's built-in image: no tone
python3 "$HERE/make_a78.py" 7 > load_test.a78
./obj_load/vtb +image=load_test.a78 +audf=7 $(fp load_a78) | grep -E "LOAD|TONE|HSC"

echo "-- load a headerless 2600 image (4 KiB):"
python3 "$HERE/tone_test.py" 14 2600 | head -4096 | python3 -c "import sys;sys.stdout.buffer.write(bytes(int(l,16) for l in sys.stdin))" > load_test.a26
./obj_load/vtb +image=load_test.a26 +audf=14 $(fp load_a26) | grep -E "LOAD|TONE"

# The BIOS boot rule (docs/DARIA_CORE.md, decision 11). With a BIOS loaded
# and Skip BIOS off, a 7800 image and an empty slot boot through the BIOS; a
# 2600 image starts directly, as with Skip BIOS on, whatever the load order.
# tb_load.sv's BOOT lines give, at each reset release, what the core was
# told (use_bios, bypass_bios, tia_mode, cart_present), where the 6502's
# reset vector and first opcode came from (the BIOS ROM or the cartridge
# slot), and its reads from the BIOS ROM over the next 50 ms. Needs a 7800
# BIOS image: BIOS=FILE, by default the 7800 OpenBIOS built locally at
# work/bupchip/bios/7800openbios.bin (docs/daria_fe/lanes/G_step7_resets.md,
# 8.1). The image is not in this repository and must never be committed.
# Skipped without it.
BIOS="${BIOS:-$HERE/work/bupchip/bios/7800openbios.bin}"
if [ -f "$BIOS" ]; then
	echo "-- 7800 BIOS loaded ($(basename "$BIOS")): 2600 images start directly, 7800 images and an empty slot boot through it:"
	BD="$WORK/bios_boot"
	mkdir -p "$BD"; ln -sfn "$WORK/rtl" "$BD/rtl"
	cp load_test.a78 load_test.a26 "$BD/"
	# The BIOS takes a cart as a 7800 one only if $FFF9's low nibble is 3 or 7
	# (its high nibble: where the ROM starts). load_test.a78 has $FF there, so
	# the BIOS would start it in 2600 mode; this copy has $C7.
	python3 -c "import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[-7] = 0xC7; open(sys.argv[2], 'wb').write(d)" \
		load_test.a78 "$BD/load_test_c7.a78"
	bios_ok=1
	# bios_case <log> <title> <plusargs...>; the regexes its log must match
	# come on stdin, one per line.
	bios_case() {
		local log="$1" title="$2" pat; shift 2
		echo "  $title:"
		(cd "$BD" && ./../obj_load/vtb "$@" $(fp bios_$log) < /dev/null > "$log.log")
		grep -E "^(BOOT|TONE|IMAGE2)" "$BD/$log.log" | sed 's/^/    /'
		while read -r pat; do
			grep -Eq "$pat" "$BD/$log.log" || { echo "    MISSING: $pat"; bios_ok=0; }
		done
	}
	TONE_OK='^TONE .* ratio (0\.99[0-9]|1\.00[0-9])$'
	bios_case a26 "2600 image, Skip BIOS off (expect bypass_bios 1, tia_mode 1, the cart's vector \$F000, no BIOS ROM read, its tone)" \
		+image=load_test.a26 +audf=14 +bios="$BIOS" +skipbios=0 <<-EOF
		^BOOT 1 at [0-9]+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1$
		^BOOT 1 vector: \\\$f000 from the cartridge slot, first opcode fetch at \\\$f000 from the cartridge slot$
		^BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1$
		$TONE_OK
		EOF
	bios_case a26_bioslast "the same, the BIOS loaded after the cartridge" \
		+image=load_test.a26 +audf=14 +bios="$BIOS" +bioslast +skipbios=0 <<-EOF
		^BOOT 1 at [0-9]+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1$
		^BOOT 1 vector: \\\$f000 from the cartridge slot, first opcode fetch at \\\$f000 from the cartridge slot$
		^BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1$
		$TONE_OK
		EOF
	bios_case a78 "7800 image, Skip BIOS off (expect bypass_bios 0, the vector and first opcode from the BIOS ROM)" \
		+image=load_test_c7.a78 +audf=7 +bios="$BIOS" +skipbios=0 <<-EOF
		^BOOT 1 at [0-9]+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 1$
		^BOOT 1 vector: \\\$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \\\$[0-9a-f]{4} from the BIOS ROM$
		^BOOT 1 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0$
		EOF
	bios_case nocart "no cartridge, Skip BIOS off (expect the BIOS alone: cart_present 0, the BIOS ROM)" \
		+nocart +bios="$BIOS" +skipbios=0 <<-EOF
		^BOOT 1 at [0-9]+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 0$
		^BOOT 1 vector: \\\$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \\\$[0-9a-f]{4} from the BIOS ROM$
		^BOOT 1 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0$
		EOF
	bios_case a78_then_a26 "7800 image, then a 2600 image at 150 ms (expect the BIOS, then the 2600 image directly)" \
		+image=load_test_c7.a78 +bios="$BIOS" +skipbios=0 +wav=300 +image2=load_test.a26 +image2at=150 <<-EOF
		^BOOT 1 at [0-9]+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 1$
		^BOOT 1 vector: \\\$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \\\$[0-9a-f]{4} from the BIOS ROM$
		^BOOT 1 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0$
		^BOOT 2 at [0-9]+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1$
		^BOOT 2 vector: \\\$f000 from the cartridge slot, first opcode fetch at \\\$f000 from the cartridge slot$
		^BOOT 2 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1$
		EOF
	bios_case a26_then_a78 "2600 image, then a 7800 image at 150 ms (expect the 2600 image directly, then the BIOS)" \
		+image=load_test.a26 +bios="$BIOS" +skipbios=0 +wav=300 +image2=load_test_c7.a78 +image2at=150 <<-EOF
		^BOOT 1 at [0-9]+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1$
		^BOOT 1 vector: \\\$f000 from the cartridge slot, first opcode fetch at \\\$f000 from the cartridge slot$
		^BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en 1$
		^BOOT 2 at [0-9]+ ms: use_bios 1, bypass_bios 0, tia_mode 0, cart_present 1$
		^BOOT 2 vector: \\\$[0-9a-f]{4} from the BIOS ROM, first opcode fetch at \\\$[0-9a-f]{4} from the BIOS ROM$
		^BOOT 2 after 50 ms: [1-9][0-9]* CPU reads from the BIOS ROM, tia_en 0$
		EOF
	for img in a26 a78; do
		[ $img = a26 ] && { what=2600; audf=14; tia=1; vec=f000; } || { what=7800; audf=7; tia=0; vec=c000; }
		bios_case skip_$img "$what image, Skip BIOS on (expect no BIOS: bypass_bios 1, the cart's vector \$$vec, its tone)" \
			+image=load_test.$img +audf=$audf +bios="$BIOS" +skipbios=1 <<-EOF
			^BOOT 1 at [0-9]+ ms: use_bios 0, bypass_bios 1, tia_mode $tia, cart_present 1$
			^BOOT 1 vector: \\\$$vec from the cartridge slot, first opcode fetch at \\\$$vec from the cartridge slot$
			^BOOT 1 after 50 ms: 0 CPU reads from the BIOS ROM, tia_en $tia$
			$TONE_OK
			EOF
	done
	[ "$bios_ok" = 1 ] && echo "BIOS_BOOT pass" || echo "BIOS_BOOT FAIL"
else
	echo "-- 7800 BIOS boot rule: skipped (no BIOS image at $BIOS; set BIOS=FILE)"
fi

# The BupChip end to end in the whole core: its firmware through the
# bupchip.bin data slot (after the cartridge, in data.json's order, as the
# Pocket loads them), a Souper cartridge (souper_test.py: a 6502 program
# that sends command $80 through $8007 after 30 ms) with the synthetic ARSC
# block appended, the PSRAM model on cram0. The song's PCM, as the firmware
# pushes it and as it returns to clk_sys, must equal the Python model's
# (sim/bupchip/model/armemu.py), and its audio must reach top.sv's mixer.
# Without the firmware, the same cartridge must leave the BupChip held and
# silent. Needs the user's firmware, src/fpga/mister/rtl/bupchip.hex or
# BUPFW=FILE (docs/BUPCHIP.md); skipped without it. BUPMS sets the run (ms
# after reset).
BUPFW="${BUPFW:-$RTL/bupchip.hex}"
if [ "${BUPCHIP:-1}" = 1 ]; then
	if [ -f "$BUPFW" ]; then
		echo "-- BupChip end to end: firmware slot, Souper cartridge with an ARSC block, \$8007 command, PSRAM:"
		B="$WORK/bupchip_e2e"
		mkdir -p "$B"; ln -sfn "$WORK/rtl" "$B/rtl"
		python3 "$HERE/../tools/hex2bin.py" "$BUPFW" > "$B/bupchip.bin"
		python3 "$HERE/bupchip/verif/make_synth_arsc.py" "$B/synth.a78" --arsc "$B/synth.arsc" > /dev/null
		python3 "$HERE/souper_test.py" "$B/souper.a78" --arsc "$B/synth.arsc" > /dev/null
		# The model reads the firmware from armdec.HEX, the tree's own
		# bupchip.hex; point it at BUPFW, so that a tree without the firmware
		# (a clean clone, another worktree) runs this section too.
		[ -s "$B/song0_model.pcm" ] && [ "$B/song0_model.pcm" -nt "$B/synth.arsc" ] || \
			(cd "$HERE/bupchip/model" && BUPFW="$BUPFW" python3 -c 'import os, runpy, sys, armdec
armdec.HEX = os.environ["BUPFW"]
sys.argv = ["armemu.py"] + sys.argv[1:]
runpy.run_path("armemu.py", run_name="__main__")' "$B/synth.arsc" --song 0 --secs 1 --pcm "$B/song0_model.pcm" > "$B/armemu.log")
		(cd "$B" && ./../obj_load/vtb +image=souper.a78 +bupfw=bupchip.bin +bupfwlast +bupms="${BUPMS:-250}" +bupout=e2e $(fp bupchip_e2e) > e2e.log)
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
		(cd "$B" && ./../obj_load/vtb +image=souper.a78 +bupms=40 $(fp bupchip_nofw) > nofw.log)
		grep "^BUPCHIP result" "$B/nofw.log" | sed 's/^/    /'
		grep -Eq "^BUPCHIP result: fw_loaded=0 asset_ready=1 cpu_run=0 halted=0 .* pushed=0 pops=0 under=0 over=0 .* out_nz=0 mix_nz=0 arsc_bad=0 psram_viol=0$" "$B/nofw.log" || e2e_ok=0
		[ "$e2e_ok" = 1 ] && echo "BUPCHIP_E2E pass" || echo "BUPCHIP_E2E FAIL"
	else
		echo "-- BupChip end to end: skipped (no firmware at $BUPFW; set BUPFW=FILE; see docs/BUPCHIP.md)"
	fi
fi

# DARIA in the whole core (docs/daria_step7/plan.md 3.6), game-free: tb_load
# runs fe_dir's synthetic ARM images (sim/bupchip/daria/fe_dir/mkimg.py: a
# DPC+, a CDFJ and the 64 KB "digital" CDFJ image, which also reads ROM above
# 32 KB) through the real loader and wrapper. Each must boot and finish its
# test bodies (RIOT $FF at least the count its .meta needs, $FE 0: no failed
# self-check), every call daria_fe posts must return, with 0 PSRAM model
# violations, no CPU halt, and the guard locked with 0 unlocks (at VCO/19
# the guard does not lock, so ARM_DIV=19 expects it unlocked). Only in the
# DARIA build; without POCKET_DARIA the section is inactive, which is not a
# pass (run_sim_check.py).
if [ "$DARIA_ON" = 1 ]; then
	echo "-- DARIA: synthetic ARM images in the whole core (fe_dir/mkimg.py):"
	DR="$WORK/daria"
	mkdir -p "$DR"; ln -sfn "$WORK/rtl" "$DR/rtl"
	python3 "$HERE/bupchip/daria/fe_dir/mkimg.py" "$DR/img" smoke_dpc smoke_cdf digital_cdfj > "$DR/mkimg.log"
	daria_ok=1
	guard=locked; [ "${ARM_DIV:-18}" = 19 ] && guard=unlocked
	for t in smoke_dpc smoke_cdf digital_cdfj; do
		(cd "$DR" && ./../obj_load/vtb +image="img/$t.bin" +daria="${DARIA_MS:-300}" $(fp daria_$t) < /dev/null > "$t.log" 2>&1) || true
		line="$(grep -m1 "^DARIA result:" "$DR/$t.log" || echo "DARIA result: none (the run did not finish; see $DR/$t.log)")"
		echo "  $t: ${line#DARIA result: }"
		python3 - "$DR/img/$t.meta" "$line" "$guard" <<-'PY' || daria_ok=0
		import re, sys
		meta, line, guard = sys.argv[1], sys.argv[2], sys.argv[3]
		need = {"dir_marker": 1, "call_accept": 1}
		for l in open(meta):
		    m = re.match(r"need (dir_marker|call_accept) >= (\d+)$", l.strip())
		    if m:
		        need[m.group(1)] = int(m.group(2))
		m = re.match(r"DARIA result: marker (\d+), self-check errors (\d+), calls (\d+), returns (\d+), "
		             r"psram_viol (\d+), halted (\d+), guard (\w+), unlocks (\d+)$", line)
		bad = []
		if not m:
		    bad.append("no result line")
		else:
		    mk, err, calls, rets, viol, halt, g, unl = m.groups()
		    if int(mk) < need["dir_marker"]: bad.append("marker %s < %d" % (mk, need["dir_marker"]))
		    if int(err): bad.append("self-check errors %s" % err)
		    if int(calls) < need["call_accept"]: bad.append("calls %s < %d" % (calls, need["call_accept"]))
		    if rets != calls: bad.append("returns %s != calls %s" % (rets, calls))
		    if int(viol): bad.append("psram_viol %s" % viol)
		    if int(halt): bad.append("halted")
		    if g != guard: bad.append("guard %s, expected %s" % (g, guard))
		    if int(unl): bad.append("unlocks %s" % unl)
		if bad:
		    print("    FAIL: " + "; ".join(bad))
		sys.exit(1 if bad else 0)
		PY
	done
	[ "$daria_ok" = 1 ] && echo "DARIA pass" || echo "DARIA FAIL"
else
	echo "-- DARIA: inactive (POCKET_DARIA is not in the qsf; DARIA=1 builds it): not run, and not a pass"
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
