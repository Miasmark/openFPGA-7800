#!/bin/bash
# What upstream's ARM costs (docs/DARIA_CORE.md, comparisons): Quartus
# Analysis & Synthesis of upstream MiSTer's core (src/fpga/mister/rtl/top.sv,
# the sources tb_daria.sv simulates) twice, with its ARM7TDMI and ARM mapper
# and with NO_ARM_MAPPER (as the Pocket build has it), on MiSTer's device by
# default. Prints both builds' resources, the difference, and the ARM
# entities' share of the first. Synthesis only: every port but the clocks is
# a virtual pin, so there is no fit and no timing (upstream runs its ARM at
# 5 x clk_sys, 71.59 MHz, on MiSTer).
#   ./upstream_arm_map.sh
# Environment: DEVICE (5CSEBA6U23I7), WORK (sim/work/bupchip/qupstream),
# QUARTUS (docker or native, as run_probe.sh).
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/qupstream}"
DEVICE="${DEVICE:-5CSEBA6U23I7}"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
if [ -z "$QUARTUS" ]; then
	if command -v quartus_sh > /dev/null; then QUARTUS=native; else QUARTUS=docker; fi
fi
RTL="$ROOT/src/fpga/mister/rtl"
SRCS=(
	"$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/arm7tdmi/arm7tdmi_core.sv" "$RTL/arm_host.sv" "$RTL/ddram.sv"
	"$RTL/6502/mos6502_pkg.sv"
	$(ls "$RTL"/6502/*.sv | grep -v pkg)
	$(ls "$RTL"/Maria/*.sv)
	$(ls "$RTL"/Pokey/*.sv)
	$(sed -n 's/.*qip_path) \(.*\.sv\) *\].*/\1/p' "$RTL/Minnie/Minnie.qip" | sed "s#^#$RTL/Minnie/#")
	"$RTL/SN76489/sn76489.sv"
	"$RTL"/jt51/*.v
	"$RTL/cache_ram.v" "$RTL/bram.v"
	"$RTL/composite_out.sv" "$RTL/cart_ram_tdp.sv" "$RTL/cdf_fastjump_table.sv"
	"$RTL"/arm_mapper_{memory,controller,subsystem,tables,ram_init,writeback,audio}.sv
	"$RTL"/mapper_{dpcplus,cdf,bus,fa2}.sv "$RTL/fa2_nvram_bridge.sv"
	"$RTL/ps2_to_pokey.v" "$RTL/souper.v" "$RTL/TIA.sv" "$RTL/cart.sv"
	"$RTL/cart2600.sv" "$RTL/banks2600.sv" "$RTL/video_mux.sv"
	"$RTL/detect2600.sv" "$RTL/a78_cart_extent.sv" "$RTL/RIOT/M6532.sv"
	"$RTL/top.sv" "$RTL/EEPROM_24LC256.sv" "$RTL/lightgun.sv"
)

build() {           # build NAME DEFINES...
	local name="$1" dir="$WORK/$1"
	shift
	mkdir -p "$dir"
	# The sources read their tables from rtl/... relative to the project.
	ln -sfn "$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$RTL" "$dir")" "$dir/rtl"
	{
		echo 'set_global_assignment -name FAMILY "Cyclone V"'
		echo "set_global_assignment -name DEVICE $DEVICE"
		echo 'set_global_assignment -name TOP_LEVEL_ENTITY top'
		echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
		echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 2'
		echo 'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"'
		for d in "$@"; do echo "set_global_assignment -name VERILOG_MACRO \"$d=1\""; done
		for f in "${SRCS[@]}"; do
			case "$f" in *.v) t=VERILOG_FILE ;; *) t=SYSTEMVERILOG_FILE ;; esac
			echo "set_global_assignment -name $t $(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$f" "$dir")"
		done
		echo 'set_instance_assignment -name VIRTUAL_PIN ON -to *'
		for c in clk_sys clk_arm clk_sdram; do echo "set_instance_assignment -name VIRTUAL_PIN OFF -to $c"; done
	} > "$dir/up.qsf"
	touch "$dir/up.qpf"
	echo "== $name ($*): $dir"
	if [ "$QUARTUS" = native ]; then
		(cd "$dir" && quartus_map up) > "$dir/quartus.log" 2>&1 || { echo "Quartus failed, see $dir/quartus.log" >&2; return 1; }
	else
		docker run --rm -v "$ROOT:/build" -w "/build/${dir#$ROOT/}" "$IMAGE" quartus_map up \
			> "$dir/quartus.log" 2>&1 || { echo "Quartus failed, see $dir/quartus.log" >&2; return 1; }
	fi
	grep -E "^; (Estimate of Logic utilization|Total registers|Total block memory bits|Total DSP Blocks)" \
		"$dir/output_files/up.map.rpt" | head -4
}

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
build arm NO_BUPCHIP
build noarm NO_BUPCHIP NO_ARM_MAPPER
python3 - "$WORK" <<'EOF'
import re, sys
def totals(p):
    t = {}
    for line in open(p):
        for k, pat in (("alms", r"Estimate of Logic utilization \(ALMs needed\)\s*;\s*([\d,]+)"),
                       ("regs", r"^; Total registers\s*;\s*([\d,]+)"),
                       ("bits", r"^; Total block memory bits\s*;\s*([\d,]+)"),
                       ("dsp", r"^; Total DSP Blocks\s*;\s*([\d,]+)")):
            m = re.search(pat, line)
            if m and k not in t:
                t[k] = int(m.group(1).replace(",", ""))
    return t
a = totals(sys.argv[1] + "/arm/output_files/up.map.rpt")
n = totals(sys.argv[1] + "/noarm/output_files/up.map.rpt")
print("upstream with ARM:    ", a)
print("upstream NO_ARM_MAPPER:", n)
print("difference:           ", {k: a.get(k, 0) - n.get(k, 0) for k in a})
# The ARM entities in the build with it: the hierarchy lines of the
# entity table whose name starts with arm_ or mapper_.
rpt = open(sys.argv[1] + "/arm/output_files/up.map.rpt").read()
sec = rpt.split("; Analysis & Synthesis Resource Utilization by Entity")[1].split("\n\n")[0]
for line in sec.splitlines():
    cells = [c.strip() for c in line.split(";")]
    if len(cells) > 3 and re.match(r"^\|?(arm_|mapper_|cart_ram_tdp|ddram)", cells[1].split("|")[-1].strip()):
        print(line[:200])
EOF
