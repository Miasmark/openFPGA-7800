#!/bin/bash
# Build and run the daria_fe unit benches (docs/daria_fe/design.md 12.1,
# 12.3; docs/daria_fe/interfaces.md): every tb_fe_*.sv in this directory, or
# the ones named, each a Verilator --binary --timing build of its own.
#   ./run_unit.sh [NAME ...] [+plusarg ...]
#   NAME: core, tb_fe_core or tb_fe_core.sv; +plusargs go to every bench run.
# Each bench tb_fe_<x>.sv has a sibling tb_fe_<x>.f: one path per line,
# relative to the repository root (upstream src/fpga/mister/rtl files may be
# listed); '#' starts a comment; a line starting with - or + is a Verilator
# option (-DNAME=VALUE, +define+NAME, ...). The bench is added last, its top
# module is tb_fe_<x>, and this directory is on the include path
# (phase_gen.svh). Builds go to $WORK/obj_<x> and are redone when a source,
# the .f, an include here or the options change. Each run is in $WORK, with a
# link rtl -> src/fpga/mister/rtl for upstream's tables, its output in
# $WORK/<x>.log (the build's in $WORK/obj_<x>.log). A bench passes iff its
# binary exits 0 ($finish; $fatal or $stop fail it).
# WORK defaults to sim/work/bupchip/daria/fe_unit. POISON=1 builds with
# -DDARIA_RAM_POISON (daria_mem's poisoned RAM model, design 12.1); VFLAGS
# adds Verilator options; JOBS (default 2) is the build's parallelism;
# TIMEOUT (seconds, default 1800) bounds each run; VERILATOR as elsewhere.
# Prints PASS or FAIL per bench and the count; exits 1 if any failed.
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/fe_unit}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
ln -sfn "$ROOT/src/fpga/mister/rtl" "$WORK/rtl"

NAMES=()
PLUS=()
for a in "$@"; do
	case "$a" in
		+*) PLUS+=("$a") ;;
		*) a="$(basename "$a" .sv)"; a="${a#tb_fe_}"; NAMES+=("$a") ;;
	esac
done
if [ ${#NAMES[@]} -eq 0 ]; then
	for f in "$HERE"/tb_fe_*.sv; do [ -e "$f" ] || continue; a="$(basename "$f" .sv)"; NAMES+=("${a#tb_fe_}"); done
fi
[ ${#NAMES[@]} -gt 0 ] || { echo "run_unit.sh: no benches" >&2; exit 2; }
DEFS=()
[ "${POISON:-0}" = 0 ] || DEFS+=(-DDARIA_RAM_POISON)

pass=0
fail=0
for x in "${NAMES[@]}"; do
	tb="$HERE/tb_fe_$x.sv"
	lst="$HERE/tb_fe_$x.f"
	obj="$WORK/obj_$x"
	if [ ! -f "$tb" ] || [ ! -f "$lst" ]; then
		echo "FAIL tb_fe_$x (no $(basename "$tb") or $(basename "$lst"))"; fail=$((fail + 1)); continue
	fi
	srcs=()
	opts=()
	missing=""
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%#*}"
		line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
		[ -n "$line" ] || continue
		case "$line" in
			-*|+*) opts+=("$line") ;;
			/*) srcs+=("$line") ;;
			*) srcs+=("$ROOT/$line") ;;
		esac
	done < "$lst"
	for f in "${srcs[@]}"; do [ -f "$f" ] || missing="$missing $f"; done
	if [ -n "$missing" ]; then
		echo "FAIL tb_fe_$x (missing:$missing)"; fail=$((fail + 1)); continue
	fi
	srcs+=("$tb")
	# shellcheck disable=SC2206
	args=(--binary --timing -j "${JOBS:-2}" -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD
		-Wno-MULTIDRIVEN "-I$HERE" --top-module "tb_fe_$x" "${DEFS[@]}" "${opts[@]}" $VFLAGS
		-Mdir "$obj" -o vtb "${srcs[@]}")
	sig="$("$VERILATOR" --version) ${args[*]}"
	if [ ! -x "$obj/vtb" ] || [ "$(cat "$obj/args" 2>/dev/null)" != "$sig" ] || \
			[ -n "$(find "${srcs[@]}" "$lst" "$HERE"/*.svh -newer "$obj/vtb" 2>/dev/null | head -1)" ]; then
		rm -rf "$obj"
		if ! nice -n 10 "$VERILATOR" "${args[@]}" > "$obj.log" 2>&1; then
			echo "FAIL tb_fe_$x (build, see $obj.log)"
			grep -m5 "^%Error" "$obj.log" | cut -c1-200 | sed 's/^/  /'
			fail=$((fail + 1)); continue
		fi
		find "$obj" -name '*.gch' -delete
		echo "$sig" > "$obj/args"
	fi
	start=$(date +%s)
	(cd "$WORK" && timeout "${TIMEOUT:-1800}" nice -n 10 "$obj/vtb" "${PLUS[@]}") > "$WORK/$x.log" 2>&1
	st=$?
	t=$(( $(date +%s) - start ))
	if [ $st = 0 ]; then
		echo "PASS tb_fe_$x (${t} s)"; pass=$((pass + 1))
	else
		why="exit $st"; [ $st = 124 ] && why="timeout"
		echo "FAIL tb_fe_$x ($why, ${t} s, see $WORK/$x.log)"
		grep -v "^- " "$WORK/$x.log" | tail -3 | cut -c1-200 | sed 's/^/  /'
		fail=$((fail + 1))
	fi
done
echo "run_unit: $pass of $((pass + fail)) passed${POISON:+ (POISON=$POISON)}"
[ $fail = 0 ]
