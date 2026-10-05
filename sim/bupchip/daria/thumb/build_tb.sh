#!/bin/bash
# Build tb_thumb.sv (DARIA's core alone, THUMB 1) with Verilator (5.040; set
# VERILATOR to override) and print the binary's path: $WORK/obj_thumb/vtb, or
# $WORK/obj_thumb_laterf/vtb with LATE_RF=1 (BUP_SIM_LATE_RF), rebuilt when a
# source is newer. WORK defaults to sim/work/bupchip/daria/thumb.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../../src/fpga/mister/rtl" && pwd)"
CORE="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/daria/thumb}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OBJ="$WORK/obj_thumb"
DEFS=()
[ "${LATE_RF:-0}" = 0 ] || { OBJ="${OBJ}_laterf"; DEFS+=(-DBUP_SIM_LATE_RF); }
SRCS=("$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/cache_ram.v" "$RTL/bupchip_peripheral.sv"
	"$CORE/bup_cpu.sv" "$HERE/tb_thumb.sv")
if [ -x "$OBJ/vtb" ] && [ -z "$(find "${SRCS[@]}" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	echo "$OBJ/vtb"; exit 0
fi
mkdir -p "$OBJ"
"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	--top-module tb_thumb -DROMHEX="\"$RTL/bupchip.hex\"" "${DEFS[@]}" \
	-Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
	|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
find "$OBJ" -name '*.gch' -delete		# only vtb is used again
echo "$OBJ/vtb"
