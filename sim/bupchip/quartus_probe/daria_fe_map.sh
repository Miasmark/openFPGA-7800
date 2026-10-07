#!/bin/bash
# Quartus probe of DARIA's front end (docs/daria_fe/design.md 10.3, 12.2;
# the frozen interfaces are docs/daria_fe/interfaces.md): daria_fe, or one
# of its blocks alone, on the Pocket's 5CEBA4F23C8 with the core's settings
# (ap_core.qsf, as frontend_study/gen.py copies them). Every port but clk_sys
# and clk_arm is a virtual pin, so nothing is pruned for want of a pin.
#   ./daria_fe_map.sh [TOP] [--synth | --fit]
#   TOP      daria_fe (default), or daria_fe_seq, _dec, _core, _audio, _call,
#            _copy, _arb, _guard, or a module in EXTRA_SRCS
#   (none)   Analysis & Elaboration: the interfaces elaborate. Prints the
#            result and every warning that names a daria_fe file.
#   --synth  Analysis & Synthesis: ALMs (the map report's estimate),
#            registers, block memory bits and M10K.
#   --fit    Analysis & Synthesis, Fitter and Timing Analyzer at clk_sys
#            69.841 ns and clk_arm 26.190 ns (DARIA's /18; the two cut as
#            asynchronous): design 10.3's probe, the frontend study's method.
#            Prints ALMs needed less those recoverable by dense packing (the
#            study's measure; the virtual I/O is most of the rest), ALMs
#            needed, registers, M10K and the worst setup slack.
# Environment: WORK (default sim/work/bupchip/qfe/<TOP>-<ae|synth|fit>),
# EXTRA_SRCS (more SystemVerilog files, e.g. a fallback block), DEFINES
# (VERILOG_MACROs, space-separated NAME or NAME=VALUE), KEEP_DB=1 (keep db/
# and incremental_db/, deleted otherwise), QUARTUS (docker, the default when
# quartus_sh is not on the PATH, with IMAGE raetro/quartus:21.1; or native).
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TOP=daria_fe
MODE=ae
for a in "$@"; do
	case "$a" in
		--synth) MODE=synth ;;
		--fit) MODE=fit ;;
		-h|--help) sed -n '2,27p' "$0"; exit 0 ;;
		-*) echo "daria_fe_map.sh: unknown option $a" >&2; exit 2 ;;
		*) TOP="$a" ;;
	esac
done
WORK="${WORK:-$ROOT/sim/work/bupchip/qfe/$TOP-$MODE}"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
if [ -z "$QUARTUS" ]; then
	if command -v quartus_sh > /dev/null; then QUARTUS=native; else QUARTUS=docker; fi
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
case "$WORK/" in "$ROOT"/*) ;; *) [ "$QUARTUS" = native ] || { echo "daria_fe_map.sh: WORK must be inside $ROOT for docker" >&2; exit 2; } ;; esac

C="$ROOT/src/fpga/core/bupchip"
SRCS=("$C/daria_fe_pkg.sv")
for b in seq dec core audio call copy arb guard; do SRCS+=("$C/daria_fe_$b.sv"); done
SRCS+=("$C/daria_fe.sv")
# shellcheck disable=SC2206
SRCS+=($EXTRA_SRCS)
for f in "${SRCS[@]}"; do [ -f "$f" ] || { echo "daria_fe_map.sh: no file $f" >&2; exit 2; }; done
grep -qE "^\s*module\s+$TOP\b" "${SRCS[@]}" || { echo "daria_fe_map.sh: no module $TOP in the sources" >&2; exit 2; }

rel() { python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$1" "$WORK"; }
rm -rf "$WORK/output_files" "$WORK/db" "$WORK/incremental_db"
{
	echo 'set_global_assignment -name FAMILY "Cyclone V"'
	echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
	echo "set_global_assignment -name TOP_LEVEL_ENTITY $TOP"
	echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
	echo 'set_global_assignment -name SDC_FILE p.sdc'
	echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 2'
	# ap_core.qsf's synthesis and fitter settings (the seed is the study's 1).
	for kv in "MIN_CORE_JUNCTION_TEMP 0" "MAX_CORE_JUNCTION_TEMP 85" \
			'OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"' "SEED 1" "SAFE_STATE_MACHINE ON" \
			"ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP ON" "SYNTH_PROTECT_SDC_CONSTRAINT ON" \
			"PRE_MAPPING_RESYNTHESIS ON" "OPTIMIZATION_TECHNIQUE SPEED" "MUX_RESTRUCTURE OFF" \
			"PHYSICAL_SYNTHESIS_COMBO_LOGIC ON" "PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON" \
			"PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON" 'FITTER_EFFORT "AUTO FIT"'; do
		echo "set_global_assignment -name $kv"
	done
	for d in $DEFINES; do
		case "$d" in *=*) echo "set_global_assignment -name VERILOG_MACRO \"$d\"" ;;
			*) echo "set_global_assignment -name VERILOG_MACRO \"$d=1\"" ;; esac
	done
	for f in "${SRCS[@]}"; do echo "set_global_assignment -name SYSTEMVERILOG_FILE $(rel "$f")"; done
	echo 'set_instance_assignment -name VIRTUAL_PIN ON -to *'
	for c in clk_sys clk_arm; do echo "set_instance_assignment -name VIRTUAL_PIN OFF -to $c"; done
} > "$WORK/p.qsf"
touch "$WORK/p.qpf"
cat > "$WORK/p.sdc" <<'EOF'
# clk_sys 14.318 MHz; clk_arm DARIA's /18 of the VCO (48/18 x clk_sys). The
# guard's one crossing (design 8.2) is not modelled here: the clocks are cut.
if {[get_collection_size [get_ports -nowarn clk_sys]] > 0} {
	create_clock -name clk_sys -period 69.841 [get_ports clk_sys]
}
if {[get_collection_size [get_ports -nowarn clk_arm]] > 0} {
	create_clock -name clk_arm -period 26.190 [get_ports clk_arm]
	set_clock_groups -asynchronous -group [get_clocks clk_sys] -group [get_clocks clk_arm]
}
derive_clock_uncertainty
EOF

case "$MODE" in
	ae)    steps="quartus_map p --analysis_and_elaboration" ;;
	synth) steps="quartus_map p" ;;
	fit)   steps="quartus_map p && quartus_fit p && quartus_sta p" ;;
esac
echo "== $TOP ($MODE): $WORK"
start=$(date +%s)
status=0
if [ "$QUARTUS" = native ]; then
	(cd "$WORK" && bash -c "$steps") > "$WORK/quartus.log" 2>&1 || status=$?
else
	docker run --rm -v "$ROOT:/build" -w "/build/${WORK#"$ROOT"/}" "$IMAGE" bash -c "$steps" \
		> "$WORK/quartus.log" 2>&1 || status=$?
fi
[ "${KEEP_DB:-0}" = 1 ] || rm -rf "$WORK/db" "$WORK/incremental_db"
echo "Quartus: $(( $(date +%s) - start )) s"
if [ "$status" != 0 ]; then
	grep -E "^Error" "$WORK/quartus.log" | head -20 >&2
	echo "Quartus failed (exit $status), see $WORK/quartus.log" >&2
	exit 1
fi

map="$WORK/output_files/p.map.rpt"
grep -m1 -E "^; (Analysis & Elaboration|Analysis & Synthesis) Status" "$map" || true
grep -E "^Info: Quartus Prime Analysis & (Elaboration|Synthesis) was successful" "$WORK/quartus.log" | head -1
nw=$(grep -c "^Warning" "$WORK/quartus.log" || true)
echo "warnings: $nw (all in $WORK/quartus.log); those naming a daria_fe file:"
grep -E "^(Critical )?Warning" "$WORK/quartus.log" | grep -E "daria_fe" | cut -c1-240 | sed 's/^/  /' || true

val() {    # val REPORT LABEL-REGEX: the first number on the first matching line
	sed -n "s#^; *$2[^;]*; *\([0-9,.]*\).*#\1#p" "$1" | head -1 | tr -d ,
}
if [ "$MODE" = synth ] || [ "$MODE" = fit ]; then
	echo "Analysis & Synthesis (the ALM estimate includes the virtual I/O):"
	echo "  ALMs (estimate)      $(val "$map" 'Estimate of Logic utilization (ALMs needed)')"
	echo "  registers            $(val "$map" 'Total registers')"
	echo "  block memory bits    $(val "$map" 'Total block memory bits')"
	m10k=$(awk '/; Analysis & Synthesis RAM Summary/,/^$/' "$map" | grep -c "M10K" || true)
	echo "  RAM instances (M10K) $m10k"
fi
if [ "$MODE" = fit ]; then
	fit="$WORK/output_files/p.fit.rpt"
	a=$(val "$fit" '\[A\] ALMs used in final placement')
	b=$(val "$fit" '\[B\] Estimate of ALMs recoverable by dense packing')
	echo "Fitter:"
	echo "  ALMs needed          $(val "$fit" 'Logic utilization (ALMs needed / total ALMs on device)')"
	echo "  ALMs placed - [B]    $(( ${a:-0} - ${b:-0} ))  (the study's measure)"
	echo "  registers            $(val "$fit" 'Total registers')"
	echo "  M10K blocks          $(val "$fit" 'M10K blocks')"
	sta="$WORK/output_files/p.sta.rpt"
	echo "Timing Analyzer, slow 1100mV 85C setup (clock; slack; TNS), none if no path:"
	awk '/^; Slow 1100mV 85C Model Setup Summary/,/^$/' "$sta" | grep -E "^; *clk_|No paths" | sed 's/^/  /' || true
fi
