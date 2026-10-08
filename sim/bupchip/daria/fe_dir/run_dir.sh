#!/bin/bash
# The daria_fe directed tests (docs/daria_fe/design.md 12.1, bench.md 7.9
# item 7): build the synthetic images (mkimg.py, tests.py), build tb_daria
# with FE=1 and the event monitor (fe_dir_mon.sv, added by vwrap.sh), run
# each image in mode A (upstream's ARM runs the calls) and judge it
# (dircheck.py): 0 in every bad count of the front-end shadow, and every
# coverage bin the test needs reached.
#   ./run_dir.sh [TEST ...]          (default: every test in tests.py)
# Environment:
#   FLAVOR   name of the build and its work directory (default s0):
#            sim/work/bupchip/daria/fe_dir/<FLAVOR>/ holds img/, obj_fe/ and
#            runs/fe/<test>/. Every other variable (FE_STAGE0, ...) passes
#            through to run_daria.sh, so one FLAVOR per kind of FE build.
#            FLAVOR=s0 builds the stage-0 bench as committed at STAGE0_REV
#            (default d729ba7: tb_daria.sv, fe_shadow.svh, daria_shadow.svh
#            from git, in <work>/snap/), whatever the tree holds now: the
#            reference front end only, against which every test must show 0.
#            Any other FLAVOR builds the bench in the tree (stage 1: daria_fe).
#   JOBS     parallel simulations (default 2)
#   REBUILD=1  rebuild the binary; NORUN=1 only build
#   TMO      seconds per simulation (default 1800)
# Results: <work>/results.txt, one line per test (PASS/FAIL, bad counts,
# bins). Nothing here is game data, but the outputs stay in sim/work.
# SPDX-License-Identifier: MIT
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$(cd "$HERE/.." && pwd)"
FLAVOR="${FLAVOR:-s0}"
W="$(mkdir -p "$D/../../work/bupchip/daria/fe_dir/$FLAVOR" && cd "$D/../../work/bupchip/daria/fe_dir/$FLAVOR" && pwd)"
export VERILATOR_REAL="${VERILATOR_REAL:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"

if [ "$FLAVOR" = s0 ]; then
	export FE_DIR_SNAP="$W/snap"
	mkdir -p "$FE_DIR_SNAP"
	for f in tb_daria.sv fe_shadow.svh daria_shadow.svh; do
		git -C "$D" show "${STAGE0_REV:-d729ba7}:sim/bupchip/daria/$f" > "$FE_DIR_SNAP/$f.new"
		cmp -s "$FE_DIR_SNAP/$f.new" "$FE_DIR_SNAP/$f" && rm "$FE_DIR_SNAP/$f.new" || mv "$FE_DIR_SNAP/$f.new" "$FE_DIR_SNAP/$f"
	done
fi
python3 "$HERE/mkimg.py" "$W/img" "$@" > "$W/mkimg.log"
cat "$W/mkimg.log"
TESTS=("$@")
[ ${#TESTS[@]} -gt 0 ] || mapfile -t TESTS < <(cd "$W/img" && ls *.meta | sed 's/\.meta$//')

BIN="$W/obj_fe/vtb"
if [ -x "$BIN" ] && { [ -n "$REBUILD" ] || [ -n "$(find "$HERE/fe_dir_mon.sv" "$HERE/vwrap.sh" ${FE_DIR_SNAP:+"$FE_DIR_SNAP"} -newer "$BIN")" ]; }; then
	rm -f "$BIN"
fi
WORK="$W" FE=1 VERILATOR="$HERE/vwrap.sh" "$D/run_daria.sh" --build-only
[ -z "$NORUN" ] || exit 0

one() {
	local t="$1" a f
	f="$(sed -n 's/^frames //p' "$W/img/$t.meta")"
	a="$(sed -n 's/^args //p' "$W/img/$t.meta")"
	# shellcheck disable=SC2086
	WORK="$W" FE=1 NOBUILD=1 DTRACE=0 NAME="fe/$t" timeout "${TMO:-1800}" "$D/run_daria.sh" "$W/img/$t.bin" \
		+frames="$f" +snap=0 +fire_at=0 +play_at=0 $a > /dev/null 2>&1 || true
	python3 "$HERE/dircheck.py" "$W/runs/fe/$t" "$W/img/$t.meta" > "$W/runs/fe/$t/verdict.txt" || true
	cat "$W/runs/fe/$t/verdict.txt"
}
export -f one
export W HERE D
printf '%s\n' "${TESTS[@]}" | xargs -P "${JOBS:-2}" -I{} bash -c 'one {}'
for t in "${TESTS[@]}"; do cat "$W/runs/fe/$t/verdict.txt"; done > "$W/results.txt.new"
# keep the verdicts of tests not run this time
if [ -f "$W/results.txt" ]; then
	grep -v -F -f <(printf ' %s \n' "${TESTS[@]}") "$W/results.txt" >> "$W/results.txt.new" || true
fi
sort -k2,2 "$W/results.txt.new" > "$W/results.txt"
rm -f "$W/results.txt.new"
echo "== $W/results.txt"
cat "$W/results.txt"
