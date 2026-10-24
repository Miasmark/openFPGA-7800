#!/bin/bash
# tb_vaxis5: virtual_axis5.sv (the five virtual axes as one time-shared
# engine) against five virtual_axis.sv instances whose ticks are delayed
# 0-4 clocks, on every clock of four random-stimulus seeds (4 x 10^7 clocks
# by default), and a planted fault the bench must catch (axis 4 reads axis
# 3's "slow"). run_sim.sh runs it after tb_virtual_axis; it also runs alone.
#   sim/run_vaxis5.sh
# Environment (all optional):
#   WORK=DIR       build and log directory (default sim/work/vaxis5)
#   VERILATOR=BIN  the Verilator to use (5.040; PATH's otherwise)
#   RTL_TREE=DIR   the RTL of another checkout (DIR/src/fpga), as run_sim.sh
#   SEEDS="1 2 3 4"  CYCLES=10000000  per seed
# Prints one "VAXIS5 seed ..." line per seed, the planted fault's line and
# "VAXIS5 pass" or "VAXIS5 FAIL"; exit status 0 on pass, 1 otherwise.
# The checker is sim/check/run_sim_check.py (its virtual-axis section).
# SPDX-License-Identifier: MIT
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="${RTL_TREE:-$HERE/..}/src/fpga"
WORK="${WORK:-$HERE/work/vaxis5}"
V="${VERILATOR:-verilator}"
SEEDS="${SEEDS:-1 2 3 4}"
CYCLES="${CYCLES:-10000000}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
SRC="$FPGA/core/virtual_axis5.sv"
BUG="$WORK/virtual_axis5_planted.sv"

build() {   # build <objdir> <virtual_axis5 source>
	"$V" --binary --timing -O2 -Wno-fatal -Wno-lint --top-module tb_vaxis5 -Mdir "$WORK/$1" -o vtb \
		"$FPGA/core/virtual_axis.sv" "$2" "$HERE/tb_vaxis5.sv" > "$WORK/$1.log" 2>&1 \
		|| { echo "VAXIS5 build of $1 failed:"; grep -m20 "%Error" "$WORK/$1.log"; echo "VAXIS5 FAIL"; exit 1; }
}

# The planted fault: one line changed, axis 4 (slot 4) reads axis 3's slow.
sed 's/^\(\twire        d_slow   = \)slow\[slot\];/\1(slot == 3'"'"'d4) ? slow[3] : slow[slot];/' "$SRC" > "$BUG"
if [ "$(diff "$SRC" "$BUG" | grep -c '^>')" != 1 ]; then
	echo "VAXIS5 the planted fault did not apply to $SRC (one changed line expected)"; echo "VAXIS5 FAIL"; exit 1
fi
build obj_good "$SRC"
build obj_planted "$BUG"

ok=1
for s in $SEEDS; do
	"$WORK/obj_good/vtb" +seed="$s" +cycles="$CYCLES" > "$WORK/seed_$s.log" 2>&1 || ok=0
	grep -m10 '^MISMATCH' "$WORK/seed_$s.log"
	line="$(grep -m1 '^VAXIS5 seed' "$WORK/seed_$s.log")"
	echo "${line:-VAXIS5 seed $s: no result line (see $WORK/seed_$s.log)}"
	grep '^VAXIS5 axis' "$WORK/seed_$s.log"
	[[ "$line" =~ \ mismatches\ 0$ ]] || ok=0
done
"$WORK/obj_planted/vtb" +seed=1 +cycles="$CYCLES" > "$WORK/planted.log" 2>&1
pm="$(sed -n 's/^VAXIS5 seed .* mismatches \([0-9]*\)$/\1/p' "$WORK/planted.log")"
if [ -n "$pm" ] && [ "$pm" -gt 0 ]; then
	echo "VAXIS5 planted fault (axis 4 reads axis 3's slow), seed 1: caught, $pm mismatches"
else
	echo "VAXIS5 planted fault (axis 4 reads axis 3's slow), seed 1: NOT caught (${pm:-no result line})"; ok=0
fi
[ "$ok" = 1 ] && { echo "VAXIS5 pass"; exit 0; }
echo "VAXIS5 FAIL"; exit 1
