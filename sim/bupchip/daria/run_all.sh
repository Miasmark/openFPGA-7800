#!/bin/bash
# Run run_daria.sh on every .bin in a directory, two at a time, then print
# the cross-demo table (summarize.py --table).
#   ./run_all.sh DIR [+plusargs...]
# A run whose report.txt exists is skipped; FORCE=1 reruns it. JOBS sets the
# number of parallel simulations (default 2). Outputs as run_daria.sh.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/daria}"
DIR="$(realpath "${1:?usage: run_all.sh DIR [+plusargs...]}")"
shift
# Build once, before the parallel runs race to do it.
"$HERE/run_daria.sh" --build-only 2>/dev/null || true
for f in "$DIR"/*.bin; do
	n="$(basename "$f" .bin)"
	if [ -z "$FORCE" ] && [ -f "$WORK/runs/$n/report.txt" ]; then continue; fi
	printf '%s\0' "$f"
done | xargs -0 -n 1 -P "${JOBS:-2}" -I{} "$HERE/run_daria.sh" {} "$@" > /dev/null
python3 "$HERE/summarize.py" --table "$WORK"/runs/*/
