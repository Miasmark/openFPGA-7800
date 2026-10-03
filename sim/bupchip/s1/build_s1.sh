#!/bin/bash
# Build tb_s1.sv with Verilator (5.040; set VERILATOR to override) and print
# the binary's path: $WORK/obj_s1_<PCM_DEPTH>/vtb, rebuilt when a source is
# newer.
#   ./build_s1.sh [PCM_DEPTH]      1024 (default, with the watermark remap) or 4096
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)"
CORE="$(cd "$HERE/../../../src/fpga/core/bupchip" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s1}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
DEPTH="${1:-1024}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OBJ="$WORK/obj_s1_$DEPTH"
SRCS=("$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/cache_ram.v" "$RTL/bupchip_peripheral.sv"
	"$CORE/bup_cpu.sv" "$HERE/tb_s1.sv")
if [ -x "$OBJ/vtb" ] && [ -z "$(find "${SRCS[@]}" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	echo "$OBJ/vtb"; exit 0
fi
rm -rf "$OBJ"
mkdir -p "$OBJ"
"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	--top-module tb_s1 -DROMHEX="\"$RTL/bupchip.hex\"" -DPCM_DEPTH="$DEPTH" \
	-Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
	|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
echo "$OBJ/vtb"
