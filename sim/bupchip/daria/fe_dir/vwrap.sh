#!/bin/bash
# Verilator wrapper for the directed tests (fe_dir/run_dir.sh): run_daria.sh
# calls "$VERILATOR" with its own sources; this adds the event monitor
# fe_dir_mon.sv (bound into tb_daria) and calls the real Verilator
# ($VERILATOR_REAL). With FE_DIR_SNAP set (run_dir.sh's stage-0 flavour), it
# also swaps tb_daria.sv and the bench include directory for that snapshot
# (the stage-0 bench as committed), so a stage-0 build stays the stage-0
# reference while fe_shadow.svh is being changed. run_daria.sh, tb_daria.sv
# and fe_shadow.svh themselves are not changed. With FE_DIR_MUT it builds
# mutated copies of daria_fe files in place of the originals (mut.sh).
# SPDX-License-Identifier: MIT
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$(cd "$HERE/.." && pwd)"
# FE_DIR_MUT="ORIG=COPY ..." swaps RTL sources for mutated copies (mut.sh).
declare -A mut=()
for m in $FE_DIR_MUT; do mut["${m%%=*}"]="${m#*=}"; done
args=()
for a in "$@"; do
	[ -n "${mut[$a]}" ] && a="${mut[$a]}"
	if [ -n "$FE_DIR_SNAP" ]; then
		[ "$a" = "$D/tb_daria.sv" ] && a="$FE_DIR_SNAP/tb_daria.sv"
		[ "$a" = "-I$D" ] && a="-I$FE_DIR_SNAP"
	fi
	args+=("$a")
done
exec "${VERILATOR_REAL:?}" "${args[@]}" "$HERE/fe_dir_mon.sv"
