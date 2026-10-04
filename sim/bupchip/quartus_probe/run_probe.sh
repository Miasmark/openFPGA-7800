#!/bin/bash
# Quartus probe of the BupChip CPU (docs/BUPCHIP_CORE.md, step 3): compile
# bup_probe_top (bup_cpu.sv with its ROM and RAM) alone on 5CEBA4F23C8, once
# per clock, and print the figures the step's gates need.
#   ./run_probe.sh [MHZ ...]       default: 28.636364 21.477273
# MODES=1 compiles bup_cpu with MODES 1 (SVC, SYS and FIQ; DARIA).
# Each clock builds in $WORK/<MHZ>/ (default sim/work/bupchip/qprobe):
# Analysis & Synthesis, Fitter and Timing Analyzer (no Assembler), a Timing
# Analyzer script for the five worst setup paths at slow 85 C (paths.txt),
# the worst into each kind of endpoint (classes.txt) and a list of the
# placed cells (cells.txt), and the fitted netlist from EDA Netlist
# Writer for its connections. probe_report.py then writes summary.txt: the
# resources, the RAM summary, the timing and an estimate of the CPU's ALMs
# by block. The reports stay in <MHZ>/output_files/, and paths.rpt has the
# five paths in full. KEEP_DB=1 keeps db/, incremental_db/ and the netlist
# (about 25 MB per clock), which only a later Quartus session needs.
# QUARTUS: "docker" (default when quartus_sh is not on the PATH: the
# raetro/quartus:21.1 image, Quartus Prime Lite 21.1.1, as CI uses) or
# "native".
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/qprobe}"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
if [ -z "$QUARTUS" ]; then
	if command -v quartus_sh > /dev/null; then QUARTUS=native; else QUARTUS=docker; fi
fi
CLOCKS=("$@")
[ $# -gt 0 ] || CLOCKS=(28.636364 21.477273)
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
case "$WORK/" in "$ROOT"/*) ;; *) [ "$QUARTUS" = native ] || { echo "run_probe.sh: WORK must be inside $ROOT for docker" >&2; exit 2; } ;; esac

for mhz in "${CLOCKS[@]}"; do
	dir="$WORK/$mhz"
	period=$(python3 -c "print('%.3f' % (1000.0 / float('$mhz')))")
	rm -rf "$dir"
	mkdir -p "$dir"
	qip="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$HERE/bup_probe.qip" "$dir")"
	sed "s#^set_global_assignment -name QIP_FILE bup_probe.qip\$#set_global_assignment -name QIP_FILE $qip#" \
		"$HERE/bup_probe.qsf" > "$dir/bup_probe.qsf"
	grep -q "QIP_FILE $qip\$" "$dir/bup_probe.qsf" || { echo "run_probe.sh: no QIP_FILE line in bup_probe.qsf" >&2; exit 1; }
	[ "${MODES:-0}" = 0 ] || echo "set_parameter -name MODES 1" >> "$dir/bup_probe.qsf"
	sed "s/^set period .*/set period $period/" "$HERE/bup_probe.sdc" > "$dir/bup_probe.sdc"
	grep -q "^set period $period\$" "$dir/bup_probe.sdc" || { echo "run_probe.sh: no period line in bup_probe.sdc" >&2; exit 1; }

	# The five worst setup paths at slow 85 C, with their logic levels, the
	# worst into each kind of endpoint, and the placed cells.
	cat > "$dir/paths.tcl" <<'EOF'
project_open bup_probe
create_timing_netlist
set cond ""
foreach c [get_available_operating_conditions] { if {[string match "*slow*85c*" $c]} { set cond $c } }
set_operating_conditions $cond
read_sdc
update_timing_netlist
set f [open "paths.txt" w]
puts $f "operating conditions: $cond"
puts $f [format "%8s %8s %6s %s -> %s" "slack" "data" "levels" "from" "to"]
foreach_in_collection p [get_timing_paths -setup -npaths 5 -nworst 1] {
	puts $f [format "%8.3f %8.3f %6d %s -> %s" [get_path_info $p -slack] [get_path_info $p -data_delay] \
		[get_path_info $p -num_logic_levels] [get_node_info -name [get_path_info $p -from]] \
		[get_node_info -name [get_path_info $p -to]]]
}
close $f
report_timing -setup -npaths 5 -nworst 1 -detail full_path -file paths.rpt
# The worst setup path into each kind of endpoint.
proc worst {f label k} {
	foreach_in_collection p [get_timing_paths -setup -to $k -npaths 1] {
		puts $f [format "%-36s %4d %8.3f %8.3f %6d %s -> %s" $label [get_collection_size $k] \
			[get_path_info $p -slack] [get_path_info $p -data_delay] [get_path_info $p -num_logic_levels] \
			[get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
	}
}
set f [open "classes.txt" w]
puts $f [format "%-36s %4s %8s %8s %6s %s -> %s" "endpoints" "n" "slack" "data" "levels" "from" "to"]
worst $f "ROM port A address (fetch)" [get_keepers *rom|*porta_address_reg*]
worst $f "ROM port B (data, firmware write)" [get_keepers *rom|*portb_*]
worst $f "RAM port A (address, data, we, be)" [get_keepers *cache_ram_tdp_dc_be:ram|*porta_*]
worst $f "Register file MLAB write port" [get_keepers *rf*rtl_0*]
worst $f "DSP data inputs (multiplier)" [get_pins -compatibility_mode "cpu|Mult0*|a?\[*\]"]
worst $f "CPU flip-flops and MLAB inputs" [get_keepers cpu|*]
worst $f "Output boundary flip-flops" [get_keepers *_o*~reg0]
close $f
# Every placed cell, for probe_report.py's breakdown by block.
set f [open "cells.txt" w]
foreach_in_collection c [get_cells -compatibility_mode *] {
	puts $f "[get_cell_info -name $c]\t[get_cell_info -wysiwyg_type $c]\t[get_cell_info -location $c]"
}
close $f
delete_timing_netlist
project_close
EOF

	steps="quartus_map bup_probe && quartus_fit bup_probe && quartus_sta bup_probe && quartus_sta -t paths.tcl"
	steps="$steps && quartus_eda bup_probe --simulation --tool=modelsim --format=verilog"
	echo "== $mhz MHz (period $period ns): $dir"
	if [ "$QUARTUS" = native ]; then
		(cd "$dir" && bash -c "$steps") > "$dir/quartus.log" 2>&1 || { echo "Quartus failed, see $dir/quartus.log" >&2; exit 1; }
	else
		docker run --rm -v "$ROOT:/build" -w "/build/${dir#$ROOT/}" "$IMAGE" bash -c "$steps" \
			> "$dir/quartus.log" 2>&1 || { echo "Quartus failed, see $dir/quartus.log" >&2; exit 1; }
	fi
	python3 "$HERE/probe_report.py" "$dir" | tee "$dir/summary.txt"
	[ "${KEEP_DB:-0}" != 0 ] || rm -rf "$dir/db" "$dir/incremental_db" "$dir/simulation"
done
