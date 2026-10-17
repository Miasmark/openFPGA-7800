#!/bin/bash
# Exhaustive Thumb decode check (docs/DARIA_CORE.md, "Verification",
# "Exhaustive decode"): all 65,536 halfwords through DARIA's decoder in
# bup_cpu.sv (THUMB 1, MODES 1), held in Thumb state by tb_tdec.sv, against
# the table of ../thumb_expand.py --table. Four probe runs: the halfword in
# the low half of rom_q (pc_h 0) and in the high half (pc_h 1), each with C
# known and with C unknown (after a Thumb MULS), so the FLAGS decision is
# checked as well. tdec_check.py compares field by field and prints the
# differences grouped by format.
#   ./run_decode.sh
# Work files go to $WORK (default sim/work/bupchip/daria/thumb/decode).
# BUP_CPU=FILE checks another bup_cpu.sv (a mutant, say). VERILATOR as for
# ../../verif/build.sh. About 15 seconds. Exits 0 when there are no
# differences.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/thumb/decode}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
BUP_CPU="${BUP_CPU:-$ROOT/src/fpga/core/bupchip/bup_cpu.sv}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

python3 "$HERE/../thumb_expand.py" --table "$WORK/table.txt"

SRCS=("$ROOT/src/fpga/mister/rtl/arm7tdmi/arm7tdmi_pkg.sv" "$BUP_CPU" "$HERE/tb_tdec.sv")
OBJ="$WORK/obj_tdec"
if ! { [ -x "$OBJ/vtb" ] && [ "$(cat "$OBJ/args" 2>/dev/null)" = "${SRCS[*]}" ] &&
	[ -z "$(find "${SRCS[@]}" -newer "$OBJ/vtb" 2>/dev/null)" ]; }; then
	rm -rf "$OBJ"
	mkdir -p "$OBJ"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style --top-module tb_tdec \
		-Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
		|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
	find "$OBJ" -name '*.gch' -delete
	echo "${SRCS[*]}" > "$OBJ/args"
fi

DUMPS=()
for odd in 0 1; do
	for mul in 0 1; do
		"$OBJ/vtb" +odd=$odd +mul=$mul +out="$WORK/dump_$odd$mul.txt" | grep "^tb_tdec"
		DUMPS+=("$WORK/dump_$odd$mul.txt")
	done
done
python3 "$HERE/tdec_check.py" "$WORK/table.txt" "${DUMPS[@]}"
