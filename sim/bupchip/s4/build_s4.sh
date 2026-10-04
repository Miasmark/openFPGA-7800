#!/bin/bash
# Build tb_s4.sv (the Pocket BupChip wrapper, step 4 of docs/BUPCHIP_CORE.md)
# with Verilator (5.040; set VERILATOR to override) and print the binary's
# path, $WORK/obj_s4_<variant>/vtb, rebuilt when a source is newer.
#   ./build_s4.sh
# Environment:
#   PSRAM=real     agg23's psram.sv (src/fpga/pocket_utils/) on psram_model.sv
#                  (the default when both exist)
#   PSRAM=standin  psram_standin.sv: psram.sv's port timing, no pins
#   PREEMPT=0|1    the cache's pre-emption of a fill by a demand miss (1)
#   PREFETCH=0|1   the cache's next-line prefetch (1)
#   PCM_DEPTH      1024 (default) or 4096
#   THROTTLE       BUP_THROTTLE: clocks of every 16 that may start an
#                  instruction (16, no throttle)
#   WORK           build products (default sim/work/bupchip/s4)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)"
CORE="$(cd "$HERE/../../../src/fpga/core/bupchip" && pwd)"
PU="$(cd "$HERE/../../../src/fpga/pocket_utils" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s4}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
if [ -z "$PSRAM" ]; then
	[ -f "$PU/psram.sv" ] && [ -f "$HERE/psram_model.sv" ] && PSRAM=real || PSRAM=standin
fi
DEPTH="${PCM_DEPTH:-1024}"
PRE="${PREEMPT:-1}"
PF="${PREFETCH:-1}"
THR="${THROTTLE:-16}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OBJ="$WORK/obj_s4_${PSRAM}_d${DEPTH}_pre${PRE}_pf${PF}"
[ "$THR" = 16 ] || OBJ="${OBJ}_thr$THR"
DEFS=(-DBUP_DEBUG -DPCM_DEPTH="$DEPTH" -DPREEMPT="$PRE" -DPREFETCH="$PF" -DBUP_THROTTLE="$THR")
SRCS=("$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/cache_ram.v" "$RTL/bupchip_peripheral.sv"
	"$CORE/bup_cpu.sv" "$CORE/bup_tick48k.sv" "$CORE/bup_capture.sv" "$CORE/bup_asset_wr.sv" "$CORE/bup_load_probe.sv"
	"$CORE/bup_asset_cache.sv" "$CORE/bupchip_pocket.sv")
case "$PSRAM" in
	real)    SRCS+=("$PU/psram.sv" "$HERE/psram_model.sv") ;;
	standin) SRCS+=("$HERE/psram_standin.sv"); DEFS+=(-DPSRAM_STANDIN) ;;
	*) echo "build_s4.sh: PSRAM must be real or standin" >&2; exit 2 ;;
esac
SRCS+=("$HERE/tb_s4.sv")
if [ -x "$OBJ/vtb" ] && [ -z "$(find "${SRCS[@]}" "$0" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	echo "$OBJ/vtb"; exit 0
fi
rm -rf "$OBJ"
mkdir -p "$OBJ"
"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	--top-module tb_s4 "${DEFS[@]}" -Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
	|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
find "$OBJ" -name '*.gch' -delete
find "$OBJ" -name '*.o' ! -name 'vtb' -delete 2>/dev/null || true
echo "$OBJ/vtb"
