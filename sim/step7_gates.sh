#!/bin/bash
# Every game-free gate of DARIA step 7 in one run (docs/daria_step7/plan.md
# 3.6, 7.7: the fresh-clone run), each with its own log and one verdict; an
# optional directory of game images for the gates that need one.
#   sim/step7_gates.sh [--out DIR] [--only G,G...] [--skip G,G...] [--list]
# Gates (in this order):
#   hygiene      sim/check/hygiene.sh over BASE..HEAD (HYGIENE_NAMES, the
#                name list kept outside the repository; HYGIENE_BASE)
#   pp_equiv     sim/tools/pp_equiv.py: the non-DARIA stream (the qsf's
#                macros without POCKET_DARIA, the new DARIA files excluded,
#                which pp_equiv refuses when one holds a directive that
#                would reach the files after it) has 0 'daria' tokens, and
#                its hash is PP_EXPECT (F's; on aeee6d2 fc52edb6...6f52);
#                and top.sv with cart2600.sv preprocess to PP_ORACLE_BASE's
#                (default aeee6d2) with tb_daria's two macro sets, plain and
#                WRAPPER (plan 2.8: upstream's oracle untouched)
#   pp_guards    sim/tools/pp_guards.py PP_GUARD_FROM..HEAD (--qsf daria when
#                the qsf has POCKET_DARIA, else --qsf comments)
#   cartram      cartram2600_test.py matrix and the directed s19 run
#                (CARTRAM_ONLY=e7,... runs a subset of the matrix: a quick
#                look, never the gate); with POCKET_DARIA in the qsf also
#                on the plain build (DARIA=0), every run with its +fp
#                fingerprint, all equal between the builds but the ARM
#                image's (plan 7.5 row 5)
#   run_sim      run_sim.sh (the build the qsf names) with FP=1 and its
#                checker (with RUN_SIM_REF=LOG, every measurement and verdict
#                line also equal to that log's, a run of the same build type);
#                with POCKET_DARIA in the qsf also the plain build (DARIA=0),
#                and every non-BupChip case's fingerprints equal between the
#                two (plan 7.5 row 5); with FP_REF=DIR every run_sim.sh
#                fingerprint there (DIR/<case>.csv, e.g. another tree's
#                WORK/fp) equal to this run's (frame_gate.py --strict)
#   extra_tests  extra_tests.sh with FP=1 on run_sim's WORK, checked against
#                EXTRA_REF (the reference build's extra_tests.sh log); AR_TAPE=1
#                passes through (the tape path, and the tape load with
#                +cartram, which the checker then requires); with FP_REF=DIR
#                its extra_<case>.csv there too; with POCKET_DARIA in the
#                qsf also on run_sim's plain build, checked the same way,
#                and every extra_ and cartram_ fingerprint equal between the
#                builds but the ARM image's (plan 7.5 row 5, 1.2 row 4)
#   selftest     sim/check/selftest.py: the checkers' planted faults, on this
#                run's run_sim.sh, extra_tests.sh, cartram and artape logs
#                and fingerprints (so it runs after them), and the guards'
#                (pp_guards.py, hygiene.sh, pp_equiv.py) on scratch trees
#   s4_check     sim/bupchip/s4/check.sh with JOBS=S4_JOBS (default 2:
#                that many simulations at once), both sets of plan 1.2
#                row 5: the non-DARIA one and DARIA=1 ARM38=1
#                PSRAM_CS=50.0. Row 5 needs the game jobs (S4_GAME=FILE and
#                REFDIR) and the firmware jobs (check.sh reads the tree's
#                src/fpga/mister/rtl/bupchip.hex): without them the jobs
#                that can run must pass and the gate reports PARTIAL, which
#                is not a pass
#   lint         sim/lint_step7.sh (lane I1's three macro sets)
#   daria_smp    sim/bupchip/daria/smp/run_smp.sh gate (lane I1)
#   dbg_snap     sim/bupchip/dbgsnap/run_dbgsnap.sh (lane I3)
#   frames       the frame gate on game images (plan P13, 7.4): tb_frames
#                (lane I4c, not yet in the tree) against R1's tb_daria runs,
#                GAMES=DIR and R1_DIR=DIR; until tb_frames exists it is NOT
#                AVAILABLE
# A gate whose script or input does not exist yet is NOT AVAILABLE, and one
# that ran only part of what its plan row needs is PARTIAL: neither is a
# pass. --list prints the gates and whether each is available.
# Environment: VERILATOR (default /opt/verilator-5.040/bin/verilator when it
# exists), VL_JOBS (default 2), SIM_LOCK=FILE (each simulation gate runs
# under flock FILE, niced: the machine's simulation slot), BIOS=FILE and
# BUPFW=FILE (run_sim.sh's BIOS and BupChip sections; without them those
# sections are skipped, which fails run_sim), GAMES=DIR (game images by path;
# they are never copied into the tree), R1_DIR=DIR (the reference runs),
# S4_GAME=FILE and REFDIR (s4/check.sh's game jobs), S4_JOBS, RUN_SIM_REF=LOG,
# FP_REF=DIR, PP_ORACLE_BASE=REV, CARTRAM_ONLY=LIST (above).
# Every log starts with the tree's HEAD and status and the Verilator path
# and version (plan P23); the run scripts add the md5 of each binary they
# build. Output in --out DIR (default sim/work/step7/gates): <gate>.log and
# summary.txt. Exit status 0 when every selected gate passed, 1 when one
# failed, 3 when none failed but one was not available or partial.
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
GATES=(hygiene pp_equiv pp_guards cartram run_sim extra_tests selftest s4_check lint daria_smp dbg_snap frames)

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
		frames) if [ ! -f "$HERE/tb_frames.sv" ]; then echo "sim/tb_frames.sv does not exist yet (lane I4c)"
			elif [ -z "${GAMES:-}" ] || [ ! -d "${GAMES:-}" ]; then echo "GAMES (the directory of game images) not given"
			elif [ -z "${R1_DIR:-}" ] || [ ! -d "${R1_DIR:-}" ]; then echo "R1_DIR (the reference runs) not given"; fi ;;
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

# fp_compare GLOB: every FP_REF/GLOB fingerprint equal to this run's (rs/fp);
# GLOB '*.csv' means run_sim.sh's (not extra_ or cartram_)
fp_compare() {
	[ -n "${FP_REF:-}" ] || return 0
	fp_cross "$FP_REF" "$OUT/rs/fp" "$1" FP_REF
}
# fp_cross REF_DIR DIR GLOB WHAT: every REF_DIR/GLOB fingerprint has its twin
# in DIR, equal on every column and frame (frame_gate.py --strict); with
# GLOB '*.csv' the extra_ and cartram_ files are left out, and so is the ARM
# image's (cartram_armimg), whose run differs between the builds by design
fp_cross() {
	local f d rc=0 n=0
	for f in "$1"/$3; do
		[ -f "$f" ] || continue
		d="$(basename "$f")"
		case "$3:$d" in "*.csv:extra_"*|"*.csv:cartram_"*) continue ;; esac
		case "$d" in cartram_armimg_*) continue ;; esac
		n=$((n + 1))
		echo "-- fingerprints $d: $4 against this run"
		if [ -f "$2/$d" ]; then python3 "$HERE/check/frame_gate.py" --strict "$f" "$2/$d" || rc=1
		else echo "  FAIL: $2/$d missing"; rc=1; fi
	done
	[ $n -gt 0 ] || { echo "  FAIL: no fingerprints matching $3 in $1"; rc=1; }
	return $rc
}

# gate functions: run, write the log, return 0 (pass) or 1 (fail)
g_hygiene() { bash "$HERE/check/hygiene.sh" --base "${HYGIENE_BASE:-aeee6d2}" --names "$HYGIENE_NAMES"; }
g_pp_equiv() {
	local rc=0 base="${PP_ORACLE_BASE:-aeee6d2}" d="$OUT/pp_oracle" set h0 h1 defs
	python3 "$REPO/sim/tools/pp_equiv.py" "$REPO/src/fpga" "$OUT/pp_nodaria" -U POCKET_DARIA \
		--exclude 'daria_|bup_dbg_snap' --max-token 0 --expect "$PP_EXPECT" || rc=1
	# upstream's oracle (tb_daria, plain and WRAPPER) builds top.sv and
	# cart2600.sv with run_daria.sh's macros: their text must be base's
	echo "== top.sv and cart2600.sv against $base's, with tb_daria's macro sets (plan 2.8)"
	mkdir -p "$d/base"
	for f in top.sv cart2600.sv; do
		git -C "$REPO" show "$base:src/fpga/mister/rtl/$f" > "$d/base/$f" || { echo "  FAIL: no $f at $base"; return 1; }
	done
	for set in plain wrapper; do
		defs=(-D NO_BUPCHIP -D EXTERNAL_FIRMWARE -D EEPROM_NACK_ENDS_READ)
		[ $set = wrapper ] && defs+=(-D DARIA_SHADOW -D DARIA_WIN_KB=128 -D DARIA_WRAPPER -D POCKET_DARIA)
		h0="$(python3 "$REPO/sim/tools/pp_equiv.py" --files "$d/out_base_$set" "$d/base/top.sv" "$d/base/cart2600.sv" "${defs[@]}" \
			| sed -n '1s/ .*//p')"
		h1="$(python3 "$REPO/sim/tools/pp_equiv.py" --files "$d/out_head_$set" "$REPO/src/fpga/mister/rtl/top.sv" \
			"$REPO/src/fpga/mister/rtl/cart2600.sv" "${defs[@]}" | sed -n '1s/ .*//p')"
		if [ -n "$h0" ] && [ "$h0" = "$h1" ]; then echo "  $set set: $h1, equal to $base's"
		else echo "  FAIL: $set set: HEAD ${h1:-error}, $base ${h0:-error}"; rc=1; fi
	done
	return $rc
}
g_pp_guards() {
	local q=comments; [ "$QSF_DARIA" = 1 ] && q=daria
	python3 "$REPO/sim/tools/pp_guards.py" --repo "$REPO" --from "$PP_GUARD_FROM" --to HEAD --qsf "$q"
}
g_cartram() {
	local w="$OUT/cartram_work" p="$OUT/cartram_plain" rc=0 fp=() only=()
	[ "$QSF_DARIA" = 1 ] && fp=(--fp)
	[ -n "${CARTRAM_ONLY:-}" ] && only=(--only "$CARTRAM_ONLY")
	mkdir -p "$w"
	WORK="$w" BUILD_TOP=tb_cartram bash "$HERE/run_sim.sh" || return 1
	slot python3 "$HERE/cartram2600_test.py" matrix --work "$w" "${fp[@]}" "${only[@]}" || rc=1
	slot python3 "$HERE/cartram2600_test.py" s19 --work "$w" "${fp[@]}" || rc=1
	if [ "$QSF_DARIA" = 1 ]; then
		echo "== the plain build (DARIA=0): the same runs, and their fingerprints equal (plan 7.5 row 5)"
		mkdir -p "$p"
		DARIA=0 WORK="$p" BUILD_TOP=tb_cartram bash "$HERE/run_sim.sh" || return 1
		slot python3 "$HERE/cartram2600_test.py" matrix --work "$p" --fp "${only[@]}" || rc=1
		slot python3 "$HERE/cartram2600_test.py" s19 --work "$p" --fp || rc=1
		fp_cross "$p/fp" "$w/fp" 'cartram_*.csv' "the plain build" || rc=1
	fi
	[ -z "${CARTRAM_ONLY:-}" ] || { echo "CARTRAM_ONLY=$CARTRAM_ONLY: a subset, not the gate"; [ $rc = 0 ] && rc=3; }
	return $rc
}
g_run_sim() {
	local rc=0 d
	FP=1 WORK="$OUT/rs" slot bash "$HERE/run_sim.sh" > "$OUT/run_sim.out" 2>&1; echo "exit $?" >> "$OUT/run_sim.out"
	cat "$OUT/run_sim.out"
	python3 "$HERE/check/run_sim_check.py" "$OUT/run_sim.out" ${RUN_SIM_REF:+--ref "$RUN_SIM_REF"} || rc=1
	fp_compare '*.csv' || rc=1
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
	local args=(--work "$OUT/selftest" --tools)
	[ -f "$OUT/run_sim.out" ] && args+=(--run-sim "$OUT/run_sim.out")
	[ -f "$OUT/rs/fp/load_a26.csv" ] && args+=(--fp "$OUT/rs/fp/load_a26.csv")
	[ -f "$OUT/cartram_work/cartram/logs/e7_b0.log" ] && args+=(--cartram "$OUT/cartram_work/cartram/logs/e7_b0.log")
	[ -f "$OUT/rs/cartram/logs/artape_b0.log" ] && args+=(--artape "$OUT/rs/cartram/logs/artape_b0.log")
	[ -f "$OUT/extra_tests.out" ] && [ -n "${EXTRA_REF:-}" ] && args+=(--extra "$OUT/extra_tests.out" --extra-ref "$EXTRA_REF" --extra-dir "$OUT/rs/extra")
	python3 "$HERE/check/selftest.py" "${args[@]}"
}
g_extra_tests() {
	[ -x "$OUT/rs/obj_load/vtb" ] || { echo "no run_sim build in $OUT/rs: run the run_sim gate first"; return 1; }
	local tape=() rc=0
	FP=1 WORK="$OUT/rs" slot bash "$HERE/extra_tests.sh" > "$OUT/extra_tests.out" 2>&1; echo "exit $?" >> "$OUT/extra_tests.out"
	cat "$OUT/extra_tests.out"
	[ "${AR_TAPE:-0}" = 1 ] && tape=(--ar-tape)
	python3 "$HERE/check/extra_tests_check.py" "$OUT/extra_tests.out" --ref "$EXTRA_REF" "${tape[@]}" || rc=1
	fp_compare 'extra_*.csv' || rc=1
	if [ "$QSF_DARIA" = 1 ]; then
		echo "== the plain build (DARIA=0): extra_tests.sh on run_sim's plain WORK, and the fingerprints equal (plan 7.5 row 5)"
		[ -x "$OUT/rs_plain/obj_load/vtb" ] || { echo "  FAIL: no plain run_sim build in $OUT/rs_plain (the run_sim gate makes it)"; return 1; }
		DARIA=0 FP=1 WORK="$OUT/rs_plain" slot bash "$HERE/extra_tests.sh" > "$OUT/extra_tests_plain.out" 2>&1
		echo "exit $?" >> "$OUT/extra_tests_plain.out"
		python3 "$HERE/check/extra_tests_check.py" "$OUT/extra_tests_plain.out" --ref "$EXTRA_REF" "${tape[@]}" || rc=1
		fp_cross "$OUT/rs_plain/fp" "$OUT/rs/fp" 'extra_*.csv' "the plain build" || rc=1
		fp_cross "$OUT/rs_plain/fp" "$OUT/rs/fp" 'cartram_*.csv' "the plain build" || rc=1
	fi
	return $rc
}
g_s4_check() {
	local game=() rc=0 why=""
	[ -n "${S4_GAME:-}" ] && game=("$S4_GAME")
	echo "== s4/check.sh, the non-DARIA set"
	JOBS="${S4_JOBS:-2}" WORK="$OUT/s4" slot bash "$HERE/bupchip/s4/check.sh" "${game[@]}" || rc=1
	echo "== s4/check.sh, the DARIA set (DARIA=1 ARM38=1 PSRAM_CS=50.0)"
	DARIA=1 ARM38=1 PSRAM_CS=50.0 JOBS="${S4_JOBS:-2}" WORK="$OUT/s4_daria" slot bash "$HERE/bupchip/s4/check.sh" "${game[@]}" || rc=1
	[ $rc = 0 ] || return 1
	[ -f "$REPO/src/fpga/mister/rtl/bupchip.hex" ] || why="no firmware in the tree (check.sh reads src/fpga/mister/rtl/bupchip.hex)"
	[ -n "${S4_GAME:-}" ] || why="${why:+$why; }no S4_GAME and REFDIR"
	if [ -n "$why" ]; then
		echo "PARTIAL: every job that ran passed, on both sets; plan 1.2 row 5 needs the firmware and game jobs: $why"
		return 3
	fi
	return 0
}
g_lint() { bash "$HERE/lint_step7.sh"; }
g_daria_smp() { WORK="$OUT/smp" slot bash "$HERE/bupchip/daria/smp/run_smp.sh" gate; }
g_dbg_snap() { WORK="$OUT/dbgsnap" slot bash "$HERE/bupchip/dbgsnap/run_dbgsnap.sh"; }
g_frames() { echo "the frame gate's runs arrive with tb_frames (lane I4c); this runner has none yet"; return 1; }

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
	"g_$g" >> "$OUT/$g.log" 2>&1
	case $? in
		0) RES[$g]="PASS" ;;
		3) RES[$g]="PARTIAL: $(grep -m1 -E '^(PARTIAL|CARTRAM_ONLY)' "$OUT/$g.log" | cut -c1-200)" ;;
		*) RES[$g]="FAIL" ;;
	esac
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
	case "${RES[$g]}" in FAIL*) fail=1 ;; NOT\ AVAILABLE*|PARTIAL*) na=1 ;; esac
done
[ $fail = 1 ] && { echo "STEP7_GATES FAIL"; exit 1; }
[ $na = 1 ] && { echo "STEP7_GATES incomplete: some gates are not available or partial (not a pass)"; exit 3; }
echo "STEP7_GATES pass"
