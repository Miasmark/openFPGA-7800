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
#            A test marked tree_bench in tests.py needs the bench in the tree:
#            FLAVOR=s0 skips it (verdict SKIP).
#   ARGS     extra plusargs for every test (e.g. +fe_merge_hook=1), and
#   TAG      a name for that set: runs go to runs/fe_<TAG>/, results to
#            results_<TAG>.txt (default: runs/fe/, results.txt)
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
	export FE_DIR_SNAP="$W/snap" FE_STAGE0=1
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

# Build from scratch whenever any input changed (a stamp of their contents):
# run_daria.sh's own check sees its patched copies as new on every call, and an
# incremental rebuild in an object directory whose .gch it deleted fails.
BUP="$(cd "$D/../../../src/fpga/core/bupchip" && pwd)"
INPUTS=("$HERE/fe_dir_mon.sv" "$HERE/vwrap.sh" "$D/run_daria.sh" "$D/tb_daria.sv" "$D"/*.svh "$BUP"/daria_fe*.sv "$BUP/daria_mem.sv")
[ -z "$FE_DIR_SNAP" ] || INPUTS+=("$FE_DIR_SNAP"/*)
for m in $FE_DIR_MUT; do INPUTS+=("${m#*=}"); done    # the mutated copies vwrap.sh builds instead
STAMP="$(cat "${INPUTS[@]}" | md5sum | cut -c1-32)"
STAMP="$STAMP ${FE_STAGE0:-0} ${FE_POISON:-0} $(echo "$FE_DIR_MUT" | md5sum | cut -c1-8)"
if [ -n "$REBUILD" ] || [ "$(cat "$W/build.stamp" 2>/dev/null)" != "$STAMP" ] || ! ls "$W"/obj_fe*/vtb > /dev/null 2>&1; then
	rm -rf "$W"/obj_fe* "$W/build.stamp"
	WORK="$W" FE=1 VERILATOR="$HERE/vwrap.sh" "$D/run_daria.sh" --build-only
	echo "$STAMP" > "$W/build.stamp"
fi
[ -z "$NORUN" ] || exit 0

RUNS="fe${TAG:+_$TAG}"
RES="$W/results${TAG:+_$TAG}.txt"
one() {
	local t="$1" a f
	if [ -n "$FE_DIR_SNAP" ] && grep -q '^tree_bench 1$' "$W/img/$t.meta"; then
		# a test that needs the bench in the tree (tests.py, tree_bench): not run on the snapshot
		mkdir -p "$W/runs/$RUNS/$t"
		rm -f "$W/runs/$RUNS/$t/run.log"
		echo "SKIP $t needs the bench in the tree (tree_bench); FLAVOR=s0 is the stage-0 snapshot" \
			| tee "$W/runs/$RUNS/$t/verdict.txt"
		return 0
	fi
	f="$(sed -n 's/^frames //p' "$W/img/$t.meta")"
	a="$(sed -n 's/^args //p' "$W/img/$t.meta")"
	# shellcheck disable=SC2086
	WORK="$W" FE=1 NOBUILD=1 DTRACE=0 NAME="$RUNS/$t" timeout "${TMO:-1800}" "$D/run_daria.sh" "$W/img/$t.bin" \
		+frames="$f" +snap=0 +fire_at=0 +play_at=0 $a $ARGS > /dev/null 2>&1 || true
	python3 "$HERE/dircheck.py" "$W/runs/$RUNS/$t" "$W/img/$t.meta" > "$W/runs/$RUNS/$t/verdict.txt" || true
	cat "$W/runs/$RUNS/$t/verdict.txt"
}
export -f one
export W HERE D RUNS ARGS FE_DIR_SNAP
printf '%s\n' "${TESTS[@]}" | xargs -P "${JOBS:-2}" -I{} bash -c 'one {}'
for t in "${TESTS[@]}"; do cat "$W/runs/$RUNS/$t/verdict.txt"; done > "$RES.new"
# keep the verdicts of tests not run this time
if [ -f "$RES" ]; then
	grep -v -F -f <(printf ' %s \n' "${TESTS[@]}") "$RES" >> "$RES.new" || true
fi
sort -k2,2 "$RES.new" > "$RES"
rm -f "$RES.new"
echo "== $RES"
cat "$RES"
