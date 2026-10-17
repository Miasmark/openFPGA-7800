#!/bin/bash
# Size the 2600 ARM schemes' front ends (docs/DARIA_CORE.md, "The 6507 side")
# on 5CEBA4F23C8 with the core's settings: each upstream block alone with
# every input live, the DPC+ deletion variants (variants.py), and the lean
# sizing sketch daria_fe3.sv (not functionally verified). Each compiles in
# $WORK/<name>/ (default sim/work/bupchip/daria/frontend_study) in the
# raetro/quartus:21.1 image, 4 at a time; the table at the end gives ALMs
# needed less those recoverable by dense packing (the virtual I/O makes up
# most of the rest).
#   ./run_study.sh [NAME ...]      default: all
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
RTL="$ROOT/src/fpga/mister/rtl"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/frontend_study}"
IMAGE="${IMAGE:-raetro/quartus:21.1}"
export ROOT
mkdir -p "$WORK"
cd "$WORK"
python3 "$HERE/variants.py" "$RTL/mapper_dpcplus.sv" > /dev/null

declare -A SRC=(
	[mapper_dpcplus]="$RTL/mapper_dpcplus.sv"
	[mapper_cdf]="$RTL/mapper_cdf.sv"
	[mapper_bus]="$RTL/mapper_bus.sv"
	[arm_mapper_audio]="$RTL/arm_mapper_audio.sv"
	[arm_mapper_ram_init]="$RTL/arm_mapper_ram_init.sv"
	[arm_mapper_tables]="$RTL/arm_mapper_tables.sv $RTL/cache_ram.v"
	[cdf_fastjump_table]="$RTL/cdf_fastjump_table.sv $RTL/cache_ram.v"
	[arm_mapper_writeback]="$RTL/arm_mapper_writeback.sv"
	[arm_mapper_controller]="$RTL/arm_mapper_controller.sv $RTL/arm7tdmi/arm7tdmi_pkg.sv"
	[daria_fe3]="$HERE/daria_fe3.sv $RTL/cache_ram.v"
)
for v in core nofrac nowindow norandom noservice; do SRC[mapper_dpcplus_$v]="$WORK/mapper_dpcplus_$v.sv"; done
NAMES=("$@")
[ $# -gt 0 ] || NAMES=("${!SRC[@]}")
for n in "${NAMES[@]}"; do
	[ -n "${SRC[$n]}" ] || { echo "run_study.sh: no project $n" >&2; exit 2; }
	top="$n"; case "$n" in mapper_dpcplus_*) top=mapper_dpcplus ;; esac
	rm -rf "$n"
	# shellcheck disable=SC2086
	SUFFIX="${n#"$top"}" python3 "$HERE/gen.py" "$top" ${SRC[$n]} > /dev/null
done
rel="${WORK#"$ROOT"/}"
case "$WORK/" in "$ROOT"/*) ;; *) echo "run_study.sh: WORK must be inside $ROOT for docker" >&2; exit 2 ;; esac
printf '%s\n' "${NAMES[@]}" | xargs -P 4 -I{} sh -c \
	"docker run --rm -v '$ROOT:/build' -w '/build/$rel/{}' '$IMAGE' bash -c 'quartus_map p && quartus_fit p' > '{}/quartus.log' 2>&1 || echo '{} FAILED, see $WORK/{}/quartus.log'"
printf '%-28s %8s %8s %8s\n' project ALMs LUTs FFs
for n in $(printf '%s\n' "${NAMES[@]}" | sort); do
	r="$n/output_files/p.fit.rpt"
	[ -f "$r" ] || { echo "$n: no report"; continue; }
	val() { sed -n "s/^; *$1[^;]*; *\([0-9,]*\) .*/\1/p" "$r" | head -1 | tr -d ,; }
	a=$(val '\[A\] ALMs used in final placement')
	b=$(val '\[B\] Estimate of ALMs recoverable by dense packing')
	l=$(val 'Combinational ALUT usage for logic')
	f=$(val 'Dedicated logic registers')
	printf '%-28s %8s %8s %8s\n' "$n" "$((a - b))" "$l" "$f"
done
