#!/bin/bash
# The +mam directed tests (docs/HARMONY_MODEL.md; dirtests.py): build the
# synthetic images (nine tests, each at two loop counts: 18 images), build the
# plain tb_daria (run_daria.sh --build-only), run each image for 5 frames with
# +mam=1 +mamtrace=4, then judge every run twice:
#   dircheck.py      the hand-worked waits per loop iteration in all ten
#                    configurations, the categories, one absolute total, the
#                    cfn column, mam_chk = 0, and the bench's Python twin
#                    (mam_check.py) on each trace;
#   mymam_check.py   the independent model (mymam.py), access for access.
#   ./run_dir.sh [OUTDIR]       (default: sim/work/bupchip/daria/mam/dir)
# OUTDIR/img/ holds the images, OUTDIR/runs/<test>_n<N>/ each run,
# OUTDIR/results.txt and OUTDIR/mymam.txt the verdicts.
# Environment:
#   WORK       run_daria.sh's work directory for the bench (default its own,
#              sim/work/bupchip/daria); the bench is WORK/obj/vtb
#   NOBUILD=1  use the bench that is there
#   RUNNER     a command each simulation runs through, e.g. a wrapper that
#              takes a simulation slot (default: none)
# Exit status 0 when both checks pass. Nothing here derives from a game, but
# the outputs stay in sim/work.
# SPDX-License-Identifier: MIT
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$(cd "$HERE/.." && pwd)"
WORK="${WORK:-$D/../../work/bupchip/daria}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OUT="${1:-$D/../../work/bupchip/daria/mam/dir}"
mkdir -p "$OUT/img" "$OUT/runs"
OUT="$(cd "$OUT" && pwd)"

python3 -I "$HERE/dirtests.py" "$OUT/img" > /dev/null
if [ "${NOBUILD:-0}" = 0 ] || [ ! -x "$WORK/obj/vtb" ]; then
	WORK="$WORK" "$D/run_daria.sh" --build-only
fi
VTB="$WORK/obj/vtb"
for img in "$OUT"/img/*.bin; do
	n=$(basename "$img" .bin)
	mkdir -p "$OUT/runs/$n"
	( cd "$WORK" && ${RUNNER:-} nice -n 10 "$VTB" +rom="$img" +out="$OUT/runs/$n/" \
		+frames=5 +snap=0 +mam=1 +mamtrace=4 > "$OUT/runs/$n/run.log" 2>&1 )
	echo "$n: $(($(grep -c . "$OUT/runs/$n/calls.csv") - 1)) calls"
done
rc=0
python3 -I "$HERE/dircheck.py" "$OUT" > "$OUT/results.txt" || rc=1
cat "$OUT/results.txt"
python3 -I "$HERE/mymam_check.py" "$OUT/runs" > "$OUT/mymam.txt" || rc=1
tail -1 "$OUT/mymam.txt"
exit $rc
