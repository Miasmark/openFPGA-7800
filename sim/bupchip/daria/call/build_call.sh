#!/bin/bash
# Build tb_call.sv (DARIA's core alone in the 2600 profile) with Verilator
# (5.040; set VERILATOR to override) and print the binary's path,
# $WORK/obj_call/vtb, rebuilt when a source is newer or the sources change.
# WORK defaults to sim/work/bupchip/daria/call. CORE_SV builds another copy of
# bup_cpu.sv (a mutated one, for checking that the tests catch a fault).
# WIN_KB (default 128) builds the core with another window size.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../../src/fpga/mister/rtl" && pwd)"
CORE="$(cd "$HERE/../../../../src/fpga/core/bupchip" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/daria/call}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OBJ="${OBJ:-$WORK/obj_call}"
DEFS=()
[ "${LATE_RF:-0}" = 0 ] || { OBJ="${OBJ}_laterf"; DEFS+=(-DBUP_SIM_LATE_RF); }
[ "${WIN_KB:-128}" = 128 ] || { OBJ="${OBJ}_w${WIN_KB}"; DEFS+=(-DWIN_KB="$WIN_KB"); }
SRCS=("$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/cache_ram.v" "${CORE_SV:-$CORE/bup_cpu.sv}" "$HERE/tb_call.sv")
ARGS="${SRCS[*]} ${DEFS[*]}"
if [ -x "$OBJ/vtb" ] && [ "$(cat "$OBJ/args" 2>/dev/null)" = "$ARGS" ] && \
	[ -z "$(find "${SRCS[@]}" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	echo "$OBJ/vtb"; exit 0
fi
mkdir -p "$OBJ"
"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	--top-module tb_call "${DEFS[@]}" -Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
	|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
find "$OBJ" -name '*.gch' -delete
echo "$ARGS" > "$OBJ/args"
echo "$OBJ/vtb"
