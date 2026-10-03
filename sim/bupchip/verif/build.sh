#!/bin/bash
# Build a verification testbench with Verilator (5.040; set VERILATOR to
# override) around the reference BupChip: MiSTer's arm_host/arm7tdmi_core and
# bupchip_subsystem. Prints the path of the binary.
#   ./build.sh NAME TOP [FILE.sv ...] [-DMACRO[=VALUE] ...]
# FILEs are taken relative to this directory unless absolute. The binary is
# $WORK/obj_NAME/vtb, rebuilt when a source is newer or the arguments change.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/verif}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
NAME="${1:?usage: build.sh NAME TOP [FILE.sv ...] [-DMACRO ...]}"
TOP="${2:?usage: build.sh NAME TOP [FILE.sv ...] [-DMACRO ...]}"
shift 2
SRCS=("$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/arm7tdmi/arm7tdmi_core.sv" "$RTL/arm_host.sv"
	"$RTL/cache_ram.v" "$RTL/bram.v" "$RTL/bupchip_memory.sv" "$RTL/bupchip_peripheral.sv"
	"$RTL/bupchip_asset_ddr.sv" "$RTL/bupchip_subsystem.sv")
DEFS=()
for a in "$@"; do
	case "$a" in
		-D*) DEFS+=("$a") ;;
		/*) SRCS+=("$a") ;;
		*) SRCS+=("$HERE/$a") ;;
	esac
done
SRCS+=("$HERE/$TOP.sv")
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OBJ="$WORK/obj_$NAME"
ARGS="$TOP ${SRCS[*]} ${DEFS[*]}"
if [ -x "$OBJ/vtb" ] && [ "$(cat "$OBJ/args" 2>/dev/null)" = "$ARGS" ] && \
	[ -z "$(find "${SRCS[@]}" "$HERE/ref_system.svh" -newer "$OBJ/vtb" 2>/dev/null)" ]; then
	echo "$OBJ/vtb"; exit 0
fi
rm -rf "$OBJ"
mkdir -p "$OBJ"
"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	--top-module "$TOP" -I"$HERE" -DROMHEX="\"$RTL/bupchip.hex\"" "${DEFS[@]}" \
	-Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
	|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
echo "$ARGS" > "$OBJ/args"
echo "$OBJ/vtb"
