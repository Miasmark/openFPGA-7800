#!/bin/bash
# DARIA dynamic measurement (docs/BUPCHIP_CORE.md, "Later: 2600 ARM
# cartridges"): run one 2600 ARM cartridge on the MiSTer core's own 2600 path
# with upstream's ARM7TDMI and ARM mapper compiled in (tb_daria.sv), and
# summarise every ARM call (summarize.py).
#   ./run_daria.sh ROM.bin [+plusargs...]       (see tb_daria.sv for plusargs)
#   ./run_daria.sh --build-only
# Writes $WORK/runs/<rom name>/ (WORK defaults to sim/work/bupchip/daria):
# calls.csv.gz, slack.csv, frames.csv, summary.txt, pcs.txt.gz, dtrace.txt.gz
# (the ARM's ROM data reads; DTRACE=0 leaves it out), snapshots as PNG, run.log
# and report.txt. Everything there derives from the game: it stays in sim/work
# (gitignored). Tested with Verilator 5.040; about 1 minute of wall time per
# emulated second, on one CPU. Set NAME= to name the run directory.
# SHADOW=1 builds DARIA in beside upstream's ARM (daria_shadow.svh) and adds
# daria.csv, the call-by-call comparison, to the run; WIN_KB sets its window
# (default 128). Those builds go to obj_shadow<WIN_KB>.
# SPDX-License-Identifier: MIT
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="$(cd "$HERE/../../../src/fpga" && pwd)"
RTL="$FPGA/mister/rtl"
WORK="${WORK:-$HERE/../../work/bupchip/daria}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
BUILD_ONLY=""
if [ "$1" = --build-only ]; then BUILD_ONLY=1; else
	ROM="$(realpath "${1:?usage: run_daria.sh ROM.bin|--build-only [+plusargs...]}")"
fi
shift
mkdir -p "$WORK/rtl"
WORK="$(cd "$WORK" && pwd)"

# The MiSTer sources read their tables from rtl/... relative to the working
# directory (run_sim.sh does the same).
for f in palettes Minnie ooo.hex; do ln -sfn "$RTL/$f" "$WORK/rtl/$f"; done
# Verilator 5.040 rejects initialised unpacked `wire` arrays: simulate copies
# declared `logic`, as run_sim.sh does. The sources are not touched.
PATCHED="$WORK/patched"
for f in Maria/control.sv banks2600.sv video_mux.sv RIOT/M6532.sv; do
	mkdir -p "$PATCHED/$(dirname "$f")"
	sed -E 's/^(\s*)wire(\s+\[[^]]+\]\s+\w+\s*\[[0-9]+\]\s*=)/\1logic\2/' "$RTL/$f" > "$PATCHED/$f"
done

SRCS=(
	"$HERE/../../sim_stubs.sv"
	"$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/arm7tdmi/arm7tdmi_core.sv" "$RTL/arm_host.sv" "$RTL/ddram.sv"
	"$RTL/6502/mos6502_pkg.sv"
	$(ls "$RTL"/6502/*.sv | grep -v pkg)
	$(ls "$RTL"/Maria/*.sv | grep -v control.sv) "$PATCHED/Maria/control.sv"
	$(ls "$RTL"/Pokey/*.sv)
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
	"$RTL/top.sv" "$RTL/EEPROM_24LC256.sv" "$RTL/lightgun.sv"
	"$HERE/tb_daria.sv"
)
OBJ="$WORK/obj"
DEFS=()
if [ "${SHADOW:-0}" != 0 ]; then
	BUP="$FPGA/core/bupchip"
	SRCS+=("$BUP/bup_cpu.sv" "$BUP/daria_mem.sv" "$BUP/daria_call.sv" "$BUP/daria_mmio.sv")
	OBJ="$WORK/obj_shadow${WIN_KB:-128}"
	DEFS=(-DDARIA_SHADOW "-DDARIA_WIN_KB=${WIN_KB:-128}" "-I$HERE")
fi

BIN="$OBJ/vtb"
if [ ! -x "$BIN" ] || [ -n "$(find "$HERE/tb_daria.sv" "$HERE/daria_shadow.svh" "$RTL" "$FPGA/core/bupchip" \
		-newer "$BIN" \( -name '*.sv' -o -name '*.svh' \) 2>/dev/null | head -1)" ]; then
	echo "building $BIN ..." >&2
	nice -n 10 "$VERILATOR" --binary --timing -j 2 -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
		-DNO_BUPCHIP -DEXTERNAL_FIRMWARE -DEEPROM_NACK_ENDS_READ "${DEFS[@]}" \
		--top-module tb_daria -Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
		|| { grep -m20 "^%Error" "$OBJ.log" | cut -c1-300; exit 1; }
	find "$OBJ" -name '*.gch' -delete
fi

[ -n "$BUILD_ONLY" ] && exit 0
NAME="${NAME:-$(basename "$ROM" .bin)}"
OUT="$WORK/runs/$NAME"
mkdir -p "$OUT"
rm -f "$OUT"/snap_*.ppm "$OUT"/snap_*.png
cd "$WORK"
start=$(date +%s)
nice -n 10 "$BIN" +rom="$ROM" +out="$OUT/" +dtrace="${DTRACE:-1}" "$@" > "$OUT/run.log" 2>&1
echo "wall $(( $(date +%s) - start )) s" >> "$OUT/run.log"
python3 "$HERE/ppm2png.py" "$OUT"/snap_*.ppm 2>/dev/null && rm -f "$OUT"/snap_*.ppm || true
gzip -f "$OUT/calls.csv" "$OUT/pcs.txt"
[ ! -f "$OUT/dtrace.txt" ] || gzip -f "$OUT/dtrace.txt"
python3 "$HERE/summarize.py" "$OUT" > "$OUT/report.txt"
cat "$OUT/report.txt"
