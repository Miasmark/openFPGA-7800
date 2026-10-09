#!/bin/bash
# Every game-free gate of DARIA step 7 in one run (docs/daria_step7/plan.md
# 3.6, 7.7: the fresh-clone run), each with its own log and one verdict; an
# optional directory of game images for the gates that need one.
#   sim/step7_gates.sh [--out DIR] [--only G,G...] [--skip G,G...] [--list]
# Gates (in this order):
#   hygiene      sim/check/hygiene.sh over BASE..HEAD (HYGIENE_NAMES, the
#                name list kept outside the repository; HYGIENE_BASE)
#   pp_equiv     sim/tools/pp_equiv.py: the non-DARIA stream (the qsf's
#                macros without POCKET_DARIA, the new DARIA files excluded)
#                has 0 'daria' tokens, and its hash is PP_EXPECT (F's; on
#                aeee6d2 fc52edb6...6f52)
#   pp_guards    sim/tools/pp_guards.py PP_GUARD_FROM..HEAD (--qsf daria when
#                the qsf has POCKET_DARIA, else --qsf comments)
#   cartram      cartram2600_test.py matrix and the directed s19 run
#   run_sim      run_sim.sh (the build the qsf names) and its checker; with
#                POCKET_DARIA in the qsf also the plain build (DARIA=0), both
#                with FP=1, and every non-BupChip case's fingerprints equal
#                between the two (plan 7.5 row 5)
#   extra_tests  extra_tests.sh on run_sim's WORK, checked against EXTRA_REF
#                (the reference build's extra_tests.sh log); AR_TAPE passes
#                through
#   selftest     sim/check/selftest.py: the checkers' planted faults, on this
#                run's run_sim.sh, extra_tests.sh and cartram logs and
#                fingerprints (so it runs after them)
#   s4_check     sim/bupchip/s4/check.sh with JOBS=2 (with S4_GAME=FILE and
#                REFDIR, its game jobs)
#   lint         sim/lint_step7.sh (lane I1's three macro sets)
#   daria_smp    sim/bupchip/daria/smp/run_smp.sh gate (lane I1)
#   dbg_snap     sim/bupchip/dbgsnap/run_dbgsnap.sh (lane I3)
# A gate whose script or input does not exist yet is NOT AVAILABLE, which is
# not a pass. --list prints the gates and whether each is available.
# Environment: VERILATOR (default /opt/verilator-5.040/bin/verilator when it
# exists), VL_JOBS (default 2), SIM_LOCK=FILE (each simulation gate runs
# under flock FILE, niced: the machine's simulation slot), BIOS=FILE and
# BUPFW=FILE (run_sim.sh's BIOS and BupChip sections; without them those
# sections are skipped, which fails run_sim), GAMES=DIR (game images by path;
# they are never copied into the tree).
# Every log starts with the tree's HEAD and status and the Verilator path
# and version (plan P23); the run scripts add the md5 of each binary they
# build. Output in --out DIR (default sim/work/step7/gates): <gate>.log and
# summary.txt. Exit status 0 when every selected gate passed, 1 when one
# failed, 3 when none failed but one was not available.
# SPDX-License-Identifier: MIT
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$HERE/work/step7/gates"
ONLY=""; SKIP=""; LIST=0
while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT="$2"; shift 2 ;;
		--only) ONLY=",$2,"; shift 2 ;;
		--skip) SKIP=",$2,"; shift 2 ;;
		--list) LIST=1; shift ;;
		*) echo "step7_gates.sh: unknown argument $1" >&2; exit 2 ;;
	esac
done
[ -n "${VERILATOR:-}" ] || { [ -x /opt/verilator-5.040/bin/verilator ] && VERILATOR=/opt/verilator-5.040/bin/verilator || VERILATOR=verilator; }
export VERILATOR VL_JOBS="${VL_JOBS:-2}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
QSF="$REPO/src/fpga/ap_core.qsf"
QSF_DARIA=0
grep -q '^set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"' "$QSF" && QSF_DARIA=1
GATES=(hygiene pp_equiv pp_guards cartram run_sim extra_tests selftest s4_check lint daria_smp dbg_snap)

header() {   # the P23 header of every gate log
	echo "HEAD $(git -C "$REPO" rev-parse HEAD)"
	echo "git status --porcelain: [$(git -C "$REPO" status --porcelain)]"
	echo "VERILATOR $VERILATOR ($("$VERILATOR" --version 2>/dev/null))"
	echo "date $(date -u +%FT%TZ)"
}
slot() {     # slot CMD...: under the simulation slot when SIM_LOCK is set
	if [ -n "${SIM_LOCK:-}" ]; then flock "$SIM_LOCK" nice -n 10 "$@"; else nice -n 10 "$@"; fi
}

# avail GATE: prints why a gate cannot run, or nothing
avail() {
	case "$1" in
		hygiene) [ -n "${HYGIENE_NAMES:-}" ] || echo "HYGIENE_NAMES (the name list, outside the repository) not given" ;;
		pp_equiv) [ -n "${PP_EXPECT:-}" ] || echo "PP_EXPECT (the expected non-DARIA stream hash) not given" ;;
		pp_guards) [ -n "${PP_GUARD_FROM:-}" ] || echo "PP_GUARD_FROM (commit F) not given" ;;
		extra_tests) [ -n "${EXTRA_REF:-}" ] && [ -f "${EXTRA_REF:-}" ] || echo "EXTRA_REF (the reference build's extra_tests.sh log) not given" ;;
		lint) [ -f "$HERE/lint_step7.sh" ] || echo "sim/lint_step7.sh does not exist yet (lane I1)" ;;
		daria_smp) [ -f "$HERE/bupchip/daria/smp/run_smp.sh" ] || echo "sim/bupchip/daria/smp/run_smp.sh does not exist yet (lane I1)" ;;
		dbg_snap) [ -f "$HERE/bupchip/dbgsnap/run_dbgsnap.sh" ] || echo "sim/bupchip/dbgsnap/run_dbgsnap.sh does not exist yet (lane I3)" ;;
	esac
}

selected() {
	[ -z "$ONLY" ] || [[ "$ONLY" == *",$1,"* ]] || return 1
	[[ "$SKIP" != *",$1,"* ]]
}

if [ "$LIST" = 1 ]; then
	for g in "${GATES[@]}"; do
		w="$(avail "$g")"
		printf '%-12s %s\n' "$g" "${w:-available}"
	done
	exit 0
fi

# gate functions: run, write the log, return 0 (pass) or 1 (fail)
g_hygiene() { bash "$HERE/check/hygiene.sh" --base "${HYGIENE_BASE:-aeee6d2}" --names "$HYGIENE_NAMES"; }
g_pp_equiv() {
	python3 "$REPO/sim/tools/pp_equiv.py" "$REPO/src/fpga" "$OUT/pp_nodaria" -U POCKET_DARIA \
		--exclude 'daria_|bup_dbg_snap' --max-token 0 --expect "$PP_EXPECT"
}
g_pp_guards() {
	local q=comments; [ "$QSF_DARIA" = 1 ] && q=daria
	python3 "$REPO/sim/tools/pp_guards.py" --repo "$REPO" --from "$PP_GUARD_FROM" --to HEAD --qsf "$q"
}
g_cartram() {
	local w="$OUT/cartram_work" rc=0
	mkdir -p "$w"
	WORK="$w" BUILD_TOP=tb_cartram bash "$HERE/run_sim.sh" || return 1
	slot python3 "$HERE/cartram2600_test.py" matrix --work "$w" || rc=1
	slot python3 "$HERE/cartram2600_test.py" s19 --work "$w" || rc=1
	return $rc
}
g_run_sim() {
	local rc=0 d
	FP=1 WORK="$OUT/rs" slot bash "$HERE/run_sim.sh" > "$OUT/run_sim.out" 2>&1; echo "exit $?" >> "$OUT/run_sim.out"
	cat "$OUT/run_sim.out"
	python3 "$HERE/check/run_sim_check.py" "$OUT/run_sim.out" || rc=1
	if [ "$QSF_DARIA" = 1 ]; then
		echo "== the plain build (DARIA=0), for the fingerprints of 7.5 row 5"
		DARIA=0 FP=1 WORK="$OUT/rs_plain" slot bash "$HERE/run_sim.sh" > "$OUT/run_sim_plain.out" 2>&1; echo "exit $?" >> "$OUT/run_sim_plain.out"
		python3 "$HERE/check/run_sim_check.py" "$OUT/run_sim_plain.out" --build plain || rc=1
		for f in "$OUT/rs_plain/fp/"*.csv; do
			d="$(basename "$f" .csv)"
			case "$d" in bupchip_*|daria_*) continue ;; esac     # BupChip runs: by PCM (run_sim.sh's pcm_check)
			echo "-- fingerprints $d: DARIA build against the plain build"
			python3 "$HERE/check/frame_gate.py" --strict "$OUT/rs/fp/$d.csv" "$f" || rc=1
		done
	fi
	return $rc
}
g_selftest() {
	local args=(--work "$OUT/selftest")
	[ -f "$OUT/run_sim.out" ] && args+=(--run-sim "$OUT/run_sim.out")
	[ -f "$OUT/rs/fp/load_a26.csv" ] && args+=(--fp "$OUT/rs/fp/load_a26.csv")
	[ -f "$OUT/cartram_work/cartram/logs/e7_b0.log" ] && args+=(--cartram "$OUT/cartram_work/cartram/logs/e7_b0.log")
	[ -f "$OUT/extra_tests.out" ] && [ -n "${EXTRA_REF:-}" ] && args+=(--extra "$OUT/extra_tests.out" --extra-ref "$EXTRA_REF" --extra-dir "$OUT/rs/extra")
	python3 "$HERE/check/selftest.py" "${args[@]}"
}
g_extra_tests() {
	[ -x "$OUT/rs/obj_load/vtb" ] || { echo "no run_sim build in $OUT/rs: run the run_sim gate first"; return 1; }
	WORK="$OUT/rs" slot bash "$HERE/extra_tests.sh" > "$OUT/extra_tests.out" 2>&1; echo "exit $?" >> "$OUT/extra_tests.out"
	cat "$OUT/extra_tests.out"
	python3 "$HERE/check/extra_tests_check.py" "$OUT/extra_tests.out" --ref "$EXTRA_REF" ${AR_TAPE:+--ar-tape}
}
g_s4_check() {
	local game=()
	[ -n "${S4_GAME:-}" ] && game=("$S4_GAME")
	JOBS=2 WORK="$OUT/s4" slot bash "$HERE/bupchip/s4/check.sh" "${game[@]}"
}
g_lint() { bash "$HERE/lint_step7.sh"; }
g_daria_smp() { WORK="$OUT/smp" slot bash "$HERE/bupchip/daria/smp/run_smp.sh" gate; }
g_dbg_snap() { WORK="$OUT/dbgsnap" slot bash "$HERE/bupchip/dbgsnap/run_dbgsnap.sh"; }

declare -A RES
for g in "${GATES[@]}"; do
	selected "$g" || { RES[$g]="not selected"; continue; }
	why="$(avail "$g")"
	if [ -n "$why" ]; then
		RES[$g]="NOT AVAILABLE: $why"
		continue
	fi
	echo "== $g ($(date -u +%T))"
	{ header; echo "== gate $g"; } > "$OUT/$g.log"
	if "g_$g" >> "$OUT/$g.log" 2>&1; then RES[$g]="PASS"; else RES[$g]="FAIL"; fi
	echo "verdict ${RES[$g]}" >> "$OUT/$g.log"
	echo "   ${RES[$g]}  ($OUT/$g.log)"
done

{
	header
	echo "POCKET_DARIA in the qsf: $QSF_DARIA"
	for g in "${GATES[@]}"; do printf '%-12s %s\n' "$g" "${RES[$g]}"; done
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
fail=0; na=0
for g in "${GATES[@]}"; do
	case "${RES[$g]}" in FAIL*) fail=1 ;; NOT\ AVAILABLE*) na=1 ;; esac
done
[ $fail = 1 ] && { echo "STEP7_GATES FAIL"; exit 1; }
[ $na = 1 ] && { echo "STEP7_GATES incomplete: some gates are not available (not a pass)"; exit 3; }
echo "STEP7_GATES pass"
