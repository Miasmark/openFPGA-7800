#!/bin/bash
# Run run_daria.sh on every .bin in a directory, two at a time, then print
# the cross-demo table (summarize.py --table).
#   ./run_all.sh DIR [+plusargs...]
# A run whose report.txt exists is skipped; FORCE=1 reruns it. JOBS sets the
# number of parallel simulations (default 2). Outputs as run_daria.sh;
# SHADOW=1, WRAPPER=1 and WIN_KB pass through to it (runs/shadow<WIN_KB>/,
# runs/wrap<WIN_KB>/).
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/daria}"
DIR="$(realpath "${1:?usage: run_all.sh DIR [+plusargs...]}")"
shift
PREFIX=""
[ "${SHADOW:-0}" = 0 ] || PREFIX="shadow${WIN_KB:-128}/"
[ "${SHADOW:-0}" = 0 ] || [ "${WRAPPER:-0}" = 0 ] || PREFIX="wrap${WIN_KB:-128}/"
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
