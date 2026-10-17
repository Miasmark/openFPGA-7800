#!/bin/bash
# run_rand.sh: build and run tb_fe_rand, the random differential bench of
# docs/daria_fe/design.md 12.1 (lane E3; docs/daria_fe/lanes/E3_random.md).
#
#   ./run_rand.sh [SEED ...] [+plusarg ...]     one run per seed (default: 1)
#
#   SELF=1     the upstream-vs-upstream self-check build (-DSELF): must report 0
#   POISON=1   daria_mem's poisoned RAM model (-DDARIA_RAM_POISON)
#   JOBS=N     runs in parallel (default 1; the machine rule is at most 2)
#   TIMEOUT=S  seconds per run (default 1800)
#   TAG=name   the run directory's prefix (default fe, self, fe_poison, ...)
#   VFLAGS     more Verilator options (a separate object directory per set)
#   MUT_DIR    a directory whose daria_*.sv files replace the tree's (mut_rand.sh)
#   SKIP_DONE=1  skip a seed whose log already has a verdict on this build stamp
#   STAMP_ONLY=1 print the build's name and stamp, and exit (nothing is built or run)
#
# The build stamp is a hash of the Verilator version, the options other than
# paths (the defines, VFLAGS), the sources' file names and every source file's
# content (the bench, the RTL or MUT_DIR's copies, phase_gen.svh). No path goes
# into it, so the same sources give the same stamp in any checkout and WORK.
# Each log starts with "run_rand: build <name> stamp <stamp>" and ends with
# "run_rand: verdict PASS|FAIL (...) stamp <stamp> args <plusargs hash>", so a campaign never mixes
# builds and a restarted one skips what it already has (SKIP_DONE=1).
#
# Builds go to $WORK/obj_<build>, runs to $WORK/runs/<TAG>_s<seed>.log, where
# WORK defaults to sim/work/bupchip/daria/fe_rand. A run passes iff its binary
# exits 0. Prints PASS/FAIL per seed and the bench's summary lines, and exits 1
# if any run failed. Builds and runs are niced (nice -n 10).
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_rand}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK/runs"
WORK="$(cd "$WORK" && pwd)"

SEEDS=()
PLUS=()
for a in "$@"; do
	case "$a" in
		+*) PLUS+=("$a") ;;
		*) SEEDS+=("$a") ;;
	esac
done
[ ${#SEEDS[@]} -gt 0 ] || SEEDS=(1)

UP="$ROOT/src/fpga/mister/rtl"
BUP="$ROOT/src/fpga/core/bupchip"
SRCS=("$UP/cache_ram.v" "$UP/cart_ram_tdp.sv" "$UP/mapper_dpcplus.sv" "$UP/mapper_cdf.sv" "$UP/arm_mapper_tables.sv"
	"$UP/arm_mapper_ram_init.sv" "$UP/arm_mapper_writeback.sv" "$UP/arm_mapper_audio.sv" "$UP/cdf_fastjump_table.sv"
	"$BUP/daria_fe_pkg.sv" "$HERE/fe_rand_up.sv")
DEFS=()
BUILD=fe
if [ "${SELF:-0}" != 0 ]; then
	DEFS+=(-DSELF)
	BUILD=self
else
	for f in daria_mem daria_fe_{seq,dec,core,audio,call,copy,arb,guard} daria_fe; do
		# MUT_DIR: a directory of replacement RTL files (the mutation check, mut_rand.sh)
		if [ -n "$MUT_DIR" ] && [ -f "$MUT_DIR/$f.sv" ]; then SRCS+=("$MUT_DIR/$f.sv"); else SRCS+=("$BUP/$f.sv"); fi
	done
fi
if [ "${POISON:-0}" != 0 ]; then
	DEFS+=(-DDARIA_RAM_POISON)
	BUILD="${BUILD}_poison"
fi
[ -z "$VFLAGS" ] || BUILD="${BUILD}_$(echo "$VFLAGS" | md5sum | cut -c1-6)"
[ -z "$MUT_DIR" ] || BUILD="${BUILD}_mut_$(basename "$MUT_DIR")"
TAG="${TAG:-$BUILD}"
SRCS+=("$HERE/tb_fe_rand.sv")
for f in "${SRCS[@]}"; do [ -f "$f" ] || { echo "run_rand.sh: missing $f" >&2; exit 2; }; done

OBJ="$WORK/obj_$BUILD"
# the options without paths (they and the sources' names and contents make the stamp)
# shellcheck disable=SC2206
OPTS=(--binary --timing -j 2 -O3 -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN
	--top-module tb_fe_rand "${DEFS[@]}" $VFLAGS -o vtb)
ARGS=("${OPTS[@]}" "-I$HERE" "-I$HERE/../fe_unit" -Mdir "$OBJ" "${SRCS[@]}")
SIG="$("$VERILATOR" --version) ${ARGS[*]}"          # the rebuild test (paths included)
NAMES=()
for f in "${SRCS[@]}"; do NAMES+=("$(basename "$f")"); done
STAMP="$( { "$VERILATOR" --version; echo "${OPTS[*]}"; echo "${NAMES[*]} phase_gen.svh";
	cat "${SRCS[@]}" "$HERE/../fe_unit/phase_gen.svh"; } | md5sum | cut -c1-12)"
if [ "${STAMP_ONLY:-0}" != 0 ]; then
	echo "run_rand: build $BUILD stamp $STAMP"
	exit 0
fi
AH="$(echo "${PLUS[*]}" | md5sum | cut -c1-6)"   # the plusargs: a verdict counts only for the same ones
LOCK="$WORK/.build_$BUILD.lock"
(
	flock 9
	if [ ! -x "$OBJ/vtb" ] || [ "$(cat "$OBJ/args" 2>/dev/null)" != "$SIG" ] || \
			[ -n "$(find "${SRCS[@]}" "$HERE/../fe_unit/phase_gen.svh" -newer "$OBJ/vtb" 2>/dev/null | head -1)" ]; then
		rm -rf "$OBJ"
		echo "run_rand.sh: building $BUILD"
		if ! nice -n 10 "$VERILATOR" "${ARGS[@]}" > "$OBJ.log" 2>&1; then
			echo "run_rand.sh: build failed, see $OBJ.log"
			grep -m10 "%Error" "$OBJ.log" | cut -c1-240
			exit 3
		fi
		find "$OBJ" -name '*.gch' -delete
		find "$OBJ" -name '*.o' ! -name 'vtb' -delete 2>/dev/null
		echo "$SIG" > "$OBJ/args"
	fi
) 9> "$LOCK" || exit 3

run_one() {
	local s="$1" log="$WORK/runs/${TAG}_s$1.log" st t0 v
	if [ "${SKIP_DONE:-0}" != 0 ] && [ -f "$log" ]; then
		v=$(grep -E "^run_rand: verdict (PASS|FAIL) .* stamp $STAMP args $AH\$" "$log" | tail -1)
		if [ -n "$v" ]; then
			echo "SKIP $TAG seed $s (done on stamp $STAMP: $(echo "$v" | cut -d' ' -f3))"
			grep -E "^tb_fe_rand: [0-9]+ epochs|^  bad:" "$log" | cut -c1-400 | sed 's/^/  /'
			echo "$v" | grep -q "verdict PASS"
			return $?
		fi
	fi
	t0=$(date +%s)
	echo "run_rand: build $BUILD stamp $STAMP tag $TAG seed $s args ${PLUS[*]}" > "$log"
	timeout "${TIMEOUT:-1800}" nice -n 10 "$OBJ/vtb" +seed="$s" +pg_seed="$s" "${PLUS[@]}" >> "$log" 2>&1
	st=$?
	if [ $st = 0 ]; then
		echo "PASS $TAG seed $s ($(( $(date +%s) - t0 )) s)"
		echo "run_rand: verdict PASS (exit 0, $(( $(date +%s) - t0 )) s) stamp $STAMP args $AH" >> "$log"
	else
		local why="exit $st"
		[ $st = 124 ] && why="timeout"
		echo "FAIL $TAG seed $s ($why, $(( $(date +%s) - t0 )) s, $log)"
		# a timeout is no verdict: a restarted campaign runs the seed again
		[ $st = 124 ] || echo "run_rand: verdict FAIL ($why, $(( $(date +%s) - t0 )) s) stamp $STAMP args $AH" >> "$log"
	fi
	grep -E "^tb_fe_rand: [0-9]+ epochs|^  bad:" "$log" | cut -c1-400 | sed 's/^/  /'
	return $st
}

JOBS="${JOBS:-1}"
[ "$JOBS" -gt 2 ] && JOBS=2
fail=0
pids=()
for s in "${SEEDS[@]}"; do
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 2; done
	run_one "$s" &
	pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || fail=$((fail + 1)); done
echo "run_rand: $(( ${#SEEDS[@]} - fail )) of ${#SEEDS[@]} passed ($TAG, build $BUILD stamp $STAMP)"
[ $fail = 0 ]
