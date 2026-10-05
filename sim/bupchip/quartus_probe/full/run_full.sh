#!/bin/bash
# DARIA step 3's full-build probe (docs/DARIA_CORE.md, step 3): the shipped
# core with DARIA's CPU and memories in place of ARIA's, clk_arm at
# VCO / DIV, compiled as CI compiles a release (quartus_sh --flow compile
# ap_core, Quartus Prime Lite 21.1.1 in raetro/quartus:21.1).
#
#   ./run_full.sh                  DIV=21 (32.73 MHz), the qsf's seed (2)
#   DIV=17 SEED=1 ./run_full.sh    40.43 MHz, seed 1
#   BASE=1 SEED=1 ./run_full.sh    the core as it is (no edits), for comparison
#
# The build is a copy of src/fpga in $WORK/<tag>/fpga (default WORK
# sim/work/bupchip/fullprobe; tag d<DIV>_s<SEED>, or base_s<SEED>), edited
# by daria_probe.py; the firmware files are not copied. After the compile,
# full_report.tcl writes timing.txt, arm_paths.rpt and cross.rpt there, and
# full_summary.py prints summary.txt: the device's resources, the BupChip's
# and the CPU's ALMs, and the slack per clock. KEEP_DB=1 keeps db/ and
# incremental_db/ (several hundred MB).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/fullprobe}"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
DIV="${DIV:-21}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
case "$WORK/" in "$ROOT"/*) ;; *) echo "run_full.sh: WORK must be inside $ROOT for docker" >&2; exit 2 ;; esac

tag="d${DIV}"
[ "${BASE:-0}" = 0 ] || tag="base"
tag="${tag}_s${SEED:-q}"
dir="$WORK/$tag"
rm -rf "$dir"
mkdir -p "$dir"
cp -a "$ROOT/src/fpga" "$dir/fpga"
rm -rf "$dir/fpga/output_files" "$dir/fpga/db" "$dir/fpga/incremental_db"
rm -f "$dir/fpga/mister/rtl/bupchip.hex" "$dir/fpga/mister/rtl/bupchip.mif" "$dir/fpga/mister/rtl/bupchip.bin"
if [ -n "$SEED" ]; then
	sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $SEED/" "$dir/fpga/ap_core.qsf"
	grep -q "^set_global_assignment -name SEED $SEED\$" "$dir/fpga/ap_core.qsf" || { echo "run_full.sh: no SEED line in ap_core.qsf" >&2; exit 1; }
fi
[ "${BASE:-0}" != 0 ] || python3 "$HERE/daria_probe.py" "$dir/fpga" --div "$DIV"
cp "$HERE/full_report.tcl" "$dir/fpga/"

echo "== $tag: $dir"
docker run --rm -v "$ROOT:/build" -w "/build/${dir#$ROOT/}/fpga" "$IMAGE" \
	bash -c "quartus_sh --flow compile ap_core && quartus_sta -t full_report.tcl" \
	> "$dir/quartus.log" 2>&1 || { echo "Quartus failed, see $dir/quartus.log" >&2; exit 1; }
for f in timing.txt arm_paths.rpt cross.rpt exceptions.rpt; do
	[ ! -f "$dir/fpga/$f" ] || mv "$dir/fpga/$f" "$dir/"
done
python3 "$HERE/full_summary.py" "$dir" | tee "$dir/summary.txt"
[ "${KEEP_DB:-0}" != 0 ] || rm -rf "$dir/fpga/db" "$dir/fpga/incremental_db" "$dir/fpga/output_files/ap_core.sof"
