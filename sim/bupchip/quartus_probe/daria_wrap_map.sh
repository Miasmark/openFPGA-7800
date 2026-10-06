#!/bin/bash
# Quartus Analysis & Synthesis of the BupChip wrapper as DARIA builds it
# (bupchip_pocket.sv with POCKET_DARIA; docs/DARIA_CORE.md, step 5): every
# RAM inferred or instantiated as the design intends, and what it costs,
# before the full build of step 7. Synthesis only: every port but the
# three clocks is a virtual pin, so there is no fit and no timing.
#   ./daria_wrap_map.sh            POCKET_DARIA
#   ARIA=1 ./daria_wrap_map.sh     the shipped wrapper, for the difference
# Builds in $WORK (default sim/work/bupchip/qwrap/daria or .../aria) and
# prints the resource counts and the RAM summary from the map report.
# QUARTUS: "docker" (default when quartus_sh is not on the PATH: the
# raetro/quartus:21.1 image) or "native", as run_probe.sh.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KIND=daria
[ "${ARIA:-0}" = 0 ] || KIND=aria
WORK="${WORK:-$ROOT/sim/work/bupchip/qwrap/$KIND}"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
if [ -z "$QUARTUS" ]; then
	if command -v quartus_sh > /dev/null; then QUARTUS=native; else QUARTUS=docker; fi
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
case "$WORK/" in "$ROOT"/*) ;; *) [ "$QUARTUS" = native ] || { echo "daria_wrap_map.sh: WORK must be inside $ROOT for docker" >&2; exit 2; } ;; esac

rel() { python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$1" "$WORK"; }
R="$ROOT/src/fpga/mister/rtl"
C="$ROOT/src/fpga/core/bupchip"
{
	echo 'set_global_assignment -name FAMILY "Cyclone V"'
	echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
	echo 'set_global_assignment -name TOP_LEVEL_ENTITY bupchip_pocket'
	echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
	echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 2'
	echo 'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"'
	echo 'set_global_assignment -name SAFE_STATE_MACHINE ON'
	echo 'set_global_assignment -name ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP ON'
	echo 'set_global_assignment -name PRE_MAPPING_RESYNTHESIS ON'
	echo 'set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED'
	echo 'set_global_assignment -name MUX_RESTRUCTURE OFF'
	[ "$KIND" = aria ] || echo 'set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"'
	for f in "$R/arm7tdmi/arm7tdmi_pkg.sv" "$R/bupchip_peripheral.sv" "$C/bup_cpu.sv" "$C/bup_tick48k.sv" \
			"$C/bup_capture.sv" "$C/bup_asset_wr.sv" "$C/bup_load_probe.sv" "$C/bup_asset_cache.sv" \
			"$C/daria_mem.sv" "$C/daria_call.sv" "$C/daria_mmio.sv" "$C/bupchip_pocket.sv"; do
		echo "set_global_assignment -name SYSTEMVERILOG_FILE $(rel "$f")"
	done
	echo "set_global_assignment -name VERILOG_FILE $(rel "$R/cache_ram.v")"
	echo 'set_instance_assignment -name VIRTUAL_PIN ON -to *'
	for c in clk_sys clk_arm clk_74a; do echo "set_instance_assignment -name VIRTUAL_PIN OFF -to $c"; done
} > "$WORK/wrap.qsf"
touch "$WORK/wrap.qpf"

steps="quartus_map wrap"
echo "== $KIND: $WORK"
if [ "$QUARTUS" = native ]; then
	(cd "$WORK" && bash -c "$steps") > "$WORK/quartus.log" 2>&1 || { echo "Quartus failed, see $WORK/quartus.log" >&2; exit 1; }
else
	docker run --rm -v "$ROOT:/build" -w "/build/${WORK#$ROOT/}" "$IMAGE" bash -c "$steps" \
		> "$WORK/quartus.log" 2>&1 || { echo "Quartus failed, see $WORK/quartus.log" >&2; exit 1; }
fi
rpt="$WORK/output_files/wrap.map.rpt"
grep -E "^; (Estimate of Logic utilization|Total registers|Total block memory bits|Total RAM Blocks|Total DSP Blocks|Combinational ALUT usage)" "$rpt" || true
awk '/; Analysis & Synthesis RAM Summary/,/^$/' "$rpt" | cut -c1-240
grep -c "^Warning" "$WORK/quartus.log" | sed 's/^/warnings: /'
grep -E "^Error|altsyncram.*(Warning|error)" "$WORK/quartus.log" | head -20 || true
