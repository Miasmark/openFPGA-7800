#!/bin/bash
# tb_region: the wrapper's region logic (atari7800_pocket.sv's region_pll
# block and DARIA retune counter, cut out by sim/region_unit.py) with
# core/pll_region.v in RTL-1's and RTL-2's load sequences (tb_region.sv's
# scenarios A, B and C), on the DARIA and the plain build, and four planted
# variants of the DARIA build, each of which must be caught:
#   old     2.2.1's logic (RTL-1 and RTL-2 undone): A or B
#   rtl2    RTL-2 undone: A (3 retunes where 1 is wanted)
#   rtl1    RTL-1 undone: B (2 retunes after a PAL 2600 image)
#   sketch  RTL-1 as first sketched (through the whole A78 download): C,
#           by its hazard: daria_rgn not the PLL's region (rgn_bad > 0) or a
#           retune back to back (b2b > 0) in some trial. A C trial with 0
#           retunes instead of 2 does not count: that saves retunes, and the
#           plain build does it too
# run_sim.sh runs it after the PLL retune sequence; it also runs alone.
#   sim/run_region.sh
# Environment (all optional):
#   WORK=DIR       build and log directory (default sim/work/region)
#   VERILATOR=BIN  the Verilator to use (5.040; PATH's otherwise)
#   RTL_TREE=DIR   the RTL of another checkout (DIR/src/fpga), as run_sim.sh
# Prints each build's REGION lines, one verdict line per build and
# "REGION pass" or "REGION FAIL"; exit status 0 on pass, 1 otherwise.
# The checker is sim/check/run_sim_check.py (its region section).
# SPDX-License-Identifier: MIT
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="${RTL_TREE:-$HERE/..}/src/fpga"
WORK="${WORK:-$HERE/work/region}"
V="${VERILATOR:-verilator}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
ok=1

run() {   # run <name> <variant or -> <defines...>: build and run one; its lines in WORK/<name>.log
	local name="$1" var="$2"; shift 2
	[ "$var" = - ] && var=""
	python3 -I "$HERE/region_unit.py" "$FPGA/core/atari7800_pocket.sv" "$WORK/region_unit_$name.sv" $var \
		|| { echo "REGION $name: region_unit.py failed"; return 1; }
	"$V" --binary --timing -O2 -Wno-fatal -Wno-lint --top-module tb_region "$@" -Mdir "$WORK/obj_$name" -o vtb \
		"$FPGA/core/pll_region.v" "$WORK/region_unit_$name.sv" "$HERE/tb_region.sv" > "$WORK/obj_$name.log" 2>&1 \
		|| { echo "REGION $name: build failed:"; grep -m20 "%Error" "$WORK/obj_$name.log"; return 1; }
	"$WORK/obj_$name/vtb" > "$WORK/$name.log" 2>&1
	grep -q '^REGION done$' "$WORK/$name.log" || { echo "REGION $name: no 'REGION done' (see $WORK/$name.log)"; return 1; }
}

line() { grep -m1 "^REGION $2 trials" "$WORK/$1.log"; }
# all <name> <scenario> <retunes>: every trial made <retunes> retunes, rgn_bad 0 and b2b 0
all() { [[ "$(line "$1" "$2")" =~ ^REGION\ $2\ trials\ ([0-9]+)\ retunes\ $3:([0-9]+)\ rgn_bad\ 0\ b2b\ 0$ ]] \
	&& [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; }
# alls <name> <scenario> <retunes>: as all, rgn_bad not judged (the plain build has no daria_rgn); b2b must
# still be 0. The plain build is judged on A and B only. In C it retunes back to back in most trials (b2b 45 of
# 49 on afd8269: the second retune starts as the first ends), the behaviour of the build without DARIA, which
# keeps no region that a second retune could leave stale (docs/DARIA_CORE.md, open item 20)
alls() { [[ "$(line "$1" "$2")" =~ ^REGION\ $2\ trials\ ([0-9]+)\ retunes\ $3:([0-9]+)\ rgn_bad\ [0-9]+\ b2b\ 0$ ]] \
	&& [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; }
# hz <name> <scenario>: some trial had daria_rgn wrong or a retune back to back (rgn_bad or b2b > 0)
hz() { [[ "$(line "$1" "$2")" =~ \ rgn_bad\ ([0-9]+)\ b2b\ ([0-9]+)$ ]] \
	&& [ $(( BASH_REMATCH[1] + BASH_REMATCH[2] )) -gt 0 ]; }

for b in "daria - -DPOCKET_DARIA" "plain -" "old old -DPOCKET_DARIA" "rtl2 rtl2 -DPOCKET_DARIA" \
	"rtl1 rtl1 -DPOCKET_DARIA" "sketch sketch -DPOCKET_DARIA"; do
	set -- $b
	run "$@" || { ok=0; continue; }
	grep '^REGION [ABC]' "$WORK/$1.log" | sed "s/^REGION /REGION $1 /"
done

v() { echo "REGION verdict $1: $2"; [ "$3" = 1 ] || ok=0; }
if [ -f "$WORK/daria.log" ]; then
	all daria A 1 && all daria "B pal" 0 && all daria "B ntsc" 1 && all daria C 2 \
		&& v daria "pass (A 1 retune, B pal 0, B ntsc 1, C 2, in every trial; rgn_bad 0, b2b 0)" 1 \
		|| v daria "FAIL" 0
fi
if [ -f "$WORK/plain.log" ]; then
	alls plain A 1 && alls plain "B pal" 0 && alls plain "B ntsc" 1 \
		&& v plain "pass (A 1 retune, B pal 0, B ntsc 1, in every trial)" 1 || v plain "FAIL" 0
fi
caught() { [ -f "$WORK/$1.log" ] || { v "$1" "no result" 0; return; }
	hit=0; for s in "${@:2}"; do
		case "$s" in A) all "$1" A 1 || hit=1 ;; B) all "$1" "B pal" 0 || hit=1 ;; C) all "$1" C 2 || hit=1 ;;
			Chz) hz "$1" C && hit=1 ;; esac
	done
	[ $hit = 1 ] && v "$1" "planted, caught" 1 || v "$1" "planted, NOT caught" 0; }
caught old A B
caught rtl2 A
caught rtl1 B
caught sketch Chz
[ "$ok" = 1 ] && { echo "REGION pass"; exit 0; }
echo "REGION FAIL"; exit 1
