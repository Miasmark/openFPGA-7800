#!/bin/bash
# Run run_daria.sh on every .bin in a directory, two at a time, then print
# the cross-demo table (summarize.py --table).
#   ./run_all.sh DIR [+plusargs...]
# A run whose report.txt exists is skipped; FORCE=1 reruns it. JOBS sets the
# number of parallel simulations (default 2). Outputs as run_daria.sh;
# SHADOW=1, WRAPPER=1, WIN_KB and FE=1 pass through to it (runs/shadow<WIN_KB>/,
# runs/wrap<WIN_KB>/; with FE=1 runs/fe/, runs/shadow<WIN_KB>_fe/, ...;
# FE_STAGE0=1 and FE_POISON=1 as run_daria.sh: runs/fe_s0/, runs/fe_poison/;
# MODE_B=1 as run_daria.sh: runs/shadow<WIN_KB>_fe_modeB/).
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/daria}"
DIR="$(realpath "${1:?usage: run_all.sh DIR [+plusargs...]}")"
shift
if [ "${MODE_B:-0}" != 0 ]; then
	export SHADOW=1 FE=1
fi
PREFIX=""
[ "${SHADOW:-0}" = 0 ] || PREFIX="shadow${WIN_KB:-128}/"
[ "${SHADOW:-0}" = 0 ] || [ "${WRAPPER:-0}" = 0 ] || PREFIX="wrap${WIN_KB:-128}/"
FE_SUF=""
[ "${FE_POISON:-0}" = 0 ] || FE_SUF="_poison"
[ "${FE_STAGE0:-0}" = 0 ] || FE_SUF="_s0"
[ "${MODE_B:-0}" = 0 ] || FE_SUF="_modeB${FE_SUF}"
[ "${FE:-0}" = 0 ] || { PREFIX="${PREFIX%/}"; PREFIX="${PREFIX:+${PREFIX}_}fe${FE_SUF}/"; }
# Build once, before the parallel runs race to do it; they then use that
# binary even if a source changes while they run.
"$HERE/run_daria.sh" --build-only
export NOBUILD=1
for f in "$DIR"/*.bin; do
	n="$(basename "$f" .bin)"
	if [ -z "$FORCE" ] && [ -f "$WORK/runs/$PREFIX$n/report.txt" ]; then continue; fi
	printf '%s\0' "$f"
done | xargs -0 -P "${JOBS:-2}" -I{} "$HERE/run_daria.sh" {} "$@" > /dev/null
python3 "$HERE/summarize.py" --table "$WORK/runs/$PREFIX"*/
