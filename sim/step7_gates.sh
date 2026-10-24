#!/bin/bash
# Every game-free gate of DARIA step 7 in one run (docs/daria_step7/plan.md
# 3.6, 7.7: the fresh-clone run), each with its own log and one verdict; an
# optional directory of game images for the gates that need one.
#   sim/step7_gates.sh [--out DIR] [--only G,G...] [--skip G,G...] [--list]
# --only and --skip take names from the list below; an unknown name is
# refused (exit 2) before any gate runs.
# Gates (in this order):
#   hygiene      sim/check/hygiene.sh over BASE..HEAD (HYGIENE_NAMES, the
#                name list kept outside the repository; HYGIENE_BASE)
#   pp_equiv     sim/tools/pp_equiv.py: the non-DARIA stream (the qsf's
#                macros without POCKET_DARIA, the new DARIA files excluded,
#                which pp_equiv refuses when one holds a directive that
#                would reach the files after it) has 0 'daria' tokens, and
#                its hash is PP_EXPECT (F's, on aeee6d2 fc52edb6...6f52;
#                for the release, F′'s: see pp_guards);
#                and top.sv with cart2600.sv preprocess to PP_ORACLE_BASE's
#                (default aeee6d2) with tb_daria's two macro sets, plain and
#                WRAPPER (plan 2.8: upstream's oracle untouched)
#   pp_guards    sim/tools/pp_guards.py PP_GUARD_FROM..HEAD (--qsf daria when
#                the qsf has POCKET_DARIA, --qsf release when PP_GUARD_FROM's
#                qsf has it too, else --qsf comments). The release's chain
#                (docs/daria_step10/plan.md 3.1, re-based 2026-10-22) runs
#                from F′, the last commit that changes the build without
#                DARIA: the merge of 2.2.2 (origin/main d38fd13: the POKEY
#                read fix and the AtariVox escape fix) into the ÷18 tree,
#                PP_GUARD_FROM=a080f6f6c8cc8d40cd17d0271e132df7b8bee6f9.
#                It was found as the first-parent commit that brought
#                READ_WHOLE_CYCLE in
#                (git log -1 --format=%h --first-parent -S READ_WHOLE_CYCLE -- src/fpga/mister/rtl/Pokey/pokey_bus.sv,
#                run on rev1/merge-222, the branch the merge is on); pass the
#                full hash, not the expression. The expression names F′ only
#                on a branch that has the merge on its first-parent line:
#                without --first-parent it finds 9aa125a, 2.2.2's own POKEY
#                commit, whose ÷19 tree cannot start the chain; after a
#                --no-ff merge of the release into DARIA-dev it finds that
#                later merge (use the merge's ^2, or take the branch into
#                DARIA-dev by fast-forward); and on main, after the PR's
#                merge, it finds d38fd13, 2.2.2's ÷19 tree, where
#                --qsf release fails. Never evaluate it on main. F′ has
#                PP_EXPECT
#                b1b706d3b6a2e3af4668de257b284aa652f19a1e67448521270e2466ce9e877c,
#                F′'s non-DARIA stream (the stream below with pokey.sv,
#                pokey_bus.sv, pokey_adapter.sv and avox_rx.sv from 2.2.2).
#                pp_guards then takes --qsf release: from F′ only
#                ap_core.qsf's SEED line and comments may change. Before it
#                the chain ran from the commit that added fa2_on to the
#                wrapper (-S fa2_on -- src/fpga/core/atari7800_pocket.sv,
#                35bf88f) with 2fe5aed7...4f4b (MR, virtual_axis5 without
#                virtual_axis.sv, the FA2 slot in 2600 mode, the L1W+L3 CPU,
#                the sram_ctrl key copy); before that from the FA2 slot's
#                first commit (-S fa2_nvram_bridge, 4738c65) with
#                8a7e8a3d...3b7b, until the Stage 2 review found that an A78
#                could write the slot; before that, from the MR commit
#                (git log -1 --format=%h -S MUX_RESTRUCTURE --
#                src/fpga/ap_core.qsf) with 34b3f60a...bd21
#   divider      sim/check/div_check.py: every bench's and gate's default
#                clk_arm divider (tb_load's and tb_system's arm_div, wire.py's
#                ARM_DIV, run_sim.sh's and this script's guard expectations
#                and s4 set, frame_gate.py's --expect-guard, the fit driver's
#                DIV, run_daria.sh's MODE_B +d_div) is pll_core.v's DARIA
#                counter 3 (step7_prep.py --tree-div; the D review's finding 7)
#   cartram      cartram2600_test.py matrix and the directed s19 run
#                (CARTRAM_ONLY=e7,... runs a subset of the matrix: a quick
#                look, never the gate); with Fix B in the tree (sram_ctrl.sv's
#                t_new) also the console-reset sweep (reset), the address
#                compare (midswap) and the P2 assertion's forced coincidence
#                (forcecoinc), and the mutants each must catch: nohold by the
#                reset sweep's K = 0 runs and by forcecoinc c_rd, nocmp by
#                midswap (CAUGHT); with POCKET_DARIA in the qsf also
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
#                WORK/fp) equal to this run's (frame_gate.py --strict).
#                FP_REF must hold fingerprints in tb_load's current format
#                (frame,len_sys,riot,video,audio,cpu,t_sys,rst_n,rst_sys:
#                made by these benches since 56ff012, e.g. run_sim.sh
#                with FP=1 and RTL_TREE set to an aeee6d2 checkout, then
#                extra_tests.sh with FP=1 on its WORK); an older set has
#                fewer columns, and --strict fails it ("the columns differ")
#   extra_tests  extra_tests.sh with FP=1 on run_sim's WORK, checked against
#                EXTRA_REF (the reference build's extra_tests.sh log); AR_TAPE=1
#                passes through (the tape path, and the tape load with
#                +cartram, which the checker then requires); with FP_REF=DIR
#                its extra_<case>.csv there too (the two tape loads'
#                extra_ar_tape_full and _multi only with AR_TAPE=1, the run
#                that writes them); with POCKET_DARIA in the
#                qsf also on run_sim's plain build, checked the same way,
#                and every extra_ and cartram_ fingerprint equal between the
#                builds but the ARM image's (plan 7.5 row 5, 1.2 row 4).
#                About 9 h with AR_TAPE=1 run whole, one build after the
#                other (5.2 h + 3.9 h on 2.2.4's tree, docs/ENVIRONMENT.md 6).
#                In pieces, the same checks: EXTRA_JOBS=N runs each build's
#                sections N at once (extra_tests.sh's header), each under
#                EXTRA_SLOT (a command prefix holding one simulation slot;
#                default flock SIM_LOCK when SIM_LOCK is set), and the
#                run itself outside any slot; EXTRA_BOTH=1 runs the plain
#                build's extra_tests.sh beside the DARIA one's, each under
#                EXTRA_SLOT, else under the slot (SIM_LOCK takes them in
#                turn). Run step7_gates.sh outside a slot then: every
#                piece takes its own. EXTRA_JOBS>1 with neither EXTRA_SLOT
#                nor SIM_LOCK is refused (exit 2) before any gate runs: it
#                would start N simulations per build, 2N with EXTRA_BOTH=1.
#                The SIM_LOCK default is one lock file, so it runs every
#                piece of both builds one at a time: no faster than a whole
#                run. On the owner's VM use
#                EXTRA_SLOT=~/daria_work/bin/simslot (3 slots,
#                first come, first served; docs/ENVIRONMENT.md 6.1).
#   selftest     sim/check/selftest.py: the checkers' planted faults, on this
#                run's run_sim.sh, extra_tests.sh, cartram, reset and artape logs
#                and fingerprints (so it runs after them), the guards'
#                (pp_guards.py, hygiene.sh, pp_equiv.py) on scratch trees,
#                wire.py's mutant verdict on a fake tb_wire, and this
#                script's gate names, frames list and PARTIAL verdicts on a
#                scratch copy with stand-in gate scripts. Without one of
#                those logs (the gates that write them not run, or with --skip,
#                no EXTRA_REF; the reset log only with Fix B in the tree) its
#                planted faults cannot run: the gate is then PARTIAL and names
#                the inputs that were missing
#   fit_selftest the fit driver's self-test, no Quartus
#                (sim/bupchip/quartus_probe/step7/selftest.sh, plan 5.4):
#                step7_prep.py's DARIA lines and divider, step7_checks.py's
#                verdicts on made-up report files (among them plan 5.4's (a),
#                (l) and (h) as amended 2026-10-14, judged by the divider, and
#                the misread cross-check), its (k') rule, the two copies of plan
#                2.7's table (step7_report.tcl's ff_table, f3_crossings.txt)
#                against each other, and run_step7.sh's refusals with a
#                stand-in docker and a stand-in df (run_step7.sh's 2,048 MB
#                floor tested at 2,048 and 2,047 MB); about a minute. It
#                writes about 15 MB; with less than 100 MB free on / it skips
#                the tests that copy src/fpga and is PARTIAL
#   s4_check     sim/bupchip/s4/check.sh with JOBS=S4_JOBS (default 2:
#                that many simulations at once), both sets of plan 1.2
#                row 5: the non-DARIA one and DARIA=1 ARM38=1 (VCO/18,
#                pll_core.v's divider)
#                PSRAM_CS=50.0, the latter with SNAP_REQUIRED=1 once
#                bup_dbg_snap.sv is in the tree (every tb_s4 run must then
#                print "snap: ok": the snapshot check of plan 1.2 rows 5 and
#                10 cannot be skipped). Row 5 needs the game jobs (S4_GAME=FILE and
#                REFDIR) and the firmware jobs (check.sh reads the tree's
#                src/fpga/mister/rtl/bupchip.hex): without them the jobs
#                that can run must pass and the gate reports PARTIAL, which
#                is not a pass
#   lint         sim/lint_step7.sh --debug: Verilator -Wall over the three
#                macro sets of plan 3.3 item 1 (the shipped set, the shipped
#                set without POCKET_DARIA, run_daria.sh's WRAPPER set) and the
#                shipped set with BUP_DEBUG (the hardware test builds' set,
#                which holds the DARIA status overlay), no warning added
#                against aeee6d2 (about 20 s)
#   wire         lane I1's whole-core checks of the DARIA wiring (plan 7.3,
#                1.2 row 1; sim/bupchip/daria/wire/wire.py): tb_wire built in
#                both builds, every scenario (DIRECTED=1: the whole-core
#                directed set; GAMES adds the Turbo run, found under it by
#                name, BIOS decision 11's runs, BUPFW the four Souper runs:
#                the BupChip firmware, by default the tree's gitignored
#                src/fpga/mister/rtl/bupchip.hex), then every mutant of
#                wire.py's MUTANTS (plan 7.2: P20's fix and daria_pal's source,
#                each undone on a scratch copy of the tree) CAUGHT: each
#                scenario that plan 7.2 names for it (wire.py's CATCH) fails
#                on one of its keys; a mutant run that crashes, times out,
#                hits a %Fatal, gives no WIRE summary or leaves a scenario
#                without a result is an ERROR, and fails the gate as NOT
#                CAUGHT does. A scenario not run for want of GAMES, BIOS or
#                BUPFW makes it PARTIAL; WIRE_ONLY=S,... runs only those
#                scenarios, and each mutant on those of them that catch it
#                (none: ERROR, so name the mutants with WIRE_MUT), and
#                WIRE_MUT=M,... only those mutants (a quick look, never the
#                gate: PARTIAL).
#                Needs POCKET_DARIA in the qsf; about 6 hours in one slot
#   daria_smp    sim/bupchip/daria/smp/run_smp.sh gate (lane I1)
#   dbg_snap     sim/bupchip/dbgsnap/run_dbgsnap.sh (lane I3)
#   dbg_overlay  opt-in (only with --only dbg_overlay; not in a run without
#                --only): the DARIA status overlay of the BUP_DEBUG builds.
#                sim/bupchip/dstat/run_dstat.sh (daria_dbg_status against
#                M6532.sv and tb_frames' late rule, its mutations caught),
#                then sim/bupchip/dstat/run_ovl.sh: run_sim.sh's DARIA
#                section alone in a BUP_DEBUG build (each run's overlay line
#                with its coverage, the pattern run, the section's "overlay
#                cells:" line), and its RTL mutants each CAUGHT; ARM_DIV
#                passes through (default 18, pll_core.v's divider). Then
#                run_ovl.sh's control again with ARM_DIV=19, the other
#                lattice, where the guard never locks. About
#                an hour and a half in one slot. Needs POCKET_DARIA in the qsf
#   frames       the frame gate on game images (plan P13, 7.4): tb_frames
#                (sim/run_frames.sh, INPUTS=tb_daria: the TIA's paddle inputs
#                as R1's bench presents them, bench parity) against R1's
#                tb_daria runs: for each name
#                in FRAMES_LIST (default plan 1.2 row 7's 16 images, the 15
#                demos and Stratovox: FRAMES16 below; a list that leaves one
#                of them out makes the gate PARTIAL, naming those not run, and
#                Juno-First_demo_final_CGP_NTSC, the calibration image, is
#                not one of them), GAMES/**/NAME.bin run for as many frames
#                as R1_DIR/NAME/fp.csv holds plus one, and compared with
#                frame_gate.py --auto: the scheme tb_frames' real loader
#                found decides, and R1's detect2600 must have chosen the same
#                (P27); a DPC+ or CDF image takes the gate's rules with
#                --scheme: the V1 rule by default, FRAMES_RULE=shift for the
#                strict one (plan P13), and --strict when R1's run of it makes
#                no call (P27: the load shown by detect2600's scheme alone;
#                an R1 run with no calls.csv is void); any
#                other --strict (every column equal, no call on either side)
#                (FRAMES_GUARD: locked, unlocked or none; default locked,
#                as at VCO/18, pll_core.v's divider and tb_load's default).
#                The images are read by path, never copied; the runs go to
#                OUT/frames/runs. Needs GAMES and R1_DIR
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
# FP_REF=DIR, PP_ORACLE_BASE=REV, CARTRAM_ONLY=LIST, FRAMES_LIST,
# FRAMES_GUARD, FRAMES_RULE, WIRE_ONLY, WIRE_MUT, EXTRA_JOBS, EXTRA_SLOT,
# EXTRA_BOTH (above).
# Every log starts with the tree's HEAD and status and the Verilator path
# and version (plan P23); the run scripts add the md5 of each binary they
# build. Output in --out DIR (default sim/work/step7/gates): <gate>.log and
# summary.txt. Exit status 0 when every selected gate passed, 1 when one
# failed, 3 when none failed but one was not available or partial, or when
# no gate ran at all (every one not selected or not available), 2 on a
# usage error.
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
GATES=(hygiene pp_equiv pp_guards divider cartram run_sim extra_tests selftest fit_selftest s4_check lint wire daria_smp dbg_snap frames dbg_overlay)
# opt-in gates: run only when --only names them
OPTIN=" dbg_overlay "
# --only and --skip name gates of GATES only: a misspelt name would select nothing
for g in ${ONLY//,/ } ${SKIP//,/ }; do
	[[ " ${GATES[*]} " == *" $g "* ]] || { echo "step7_gates.sh: unknown gate '$g' in --only or --skip (the gates: ${GATES[*]})" >&2; exit 2; }
done
[ "$ONLY" != ",," ] || { echo "step7_gates.sh: --only names no gate" >&2; exit 2; }
# plan 1.2 row 7 (P13, 7.4): the 15 demos and Stratovox, 1,500 frames each (R1's fp.csv)
FRAMES16="Elevator-Agent_demo_final_CG_NTSC Galagon_demo_final_CG_NTSC Gorf-Arcade_demo_final_CG_NTSC
Lady-Bug-Arcade_demo_final_CG_NTSC Mappy_demo_final_CG_NTSC Qyx_demo_final_CG_NTSC RobotWar-2684_demo_final_CG_NTSC
Scramble_demo_final_CG_NTSC Spiders-Arcade_demo_final__CG_NTSC Stratovox_demo_final_CGP_NTSC
Super-Cobra-Arcade_demo_final_CG_NTSC Turbo-Arcade_demo_final_CG_NTSC Tutankham-Arcade_demo_final_CG_NTSC
Wizard-of-Wor-Arcade_demo_final_CG_NTSC Zaxxon-Arcade_demo_v2_CG_NTSC Zoo-Keeper_demo_final_CG_NTSC"

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
		divider) [ -f "$HERE/bupchip/quartus_probe/step7/step7_prep.py" ] || echo "step7_prep.py (--tree-div) does not exist" ;;
		fit_selftest) [ -f "$HERE/bupchip/quartus_probe/step7/selftest.sh" ] || echo "sim/bupchip/quartus_probe/step7/selftest.sh does not exist" ;;
		extra_tests) [ -n "${EXTRA_REF:-}" ] && [ -f "${EXTRA_REF:-}" ] || echo "EXTRA_REF (the reference build's extra_tests.sh log) not given" ;;
		lint) [ -f "$HERE/lint_step7.sh" ] || echo "sim/lint_step7.sh does not exist" ;;
		wire) if [ ! -f "$HERE/bupchip/daria/wire/wire.py" ]; then echo "sim/bupchip/daria/wire/wire.py does not exist"
			elif [ "$QSF_DARIA" != 1 ]; then echo "POCKET_DARIA is not in the qsf (tb_wire checks the DARIA wiring)"; fi ;;
		daria_smp) [ -f "$HERE/bupchip/daria/smp/run_smp.sh" ] || echo "sim/bupchip/daria/smp/run_smp.sh does not exist yet (lane I1)" ;;
		dbg_snap) [ -f "$HERE/bupchip/dbgsnap/run_dbgsnap.sh" ] || echo "sim/bupchip/dbgsnap/run_dbgsnap.sh does not exist yet (lane I3)" ;;
		dbg_overlay) if [ ! -f "$HERE/bupchip/dstat/run_ovl.sh" ]; then echo "sim/bupchip/dstat/run_ovl.sh does not exist"
			elif [ "$QSF_DARIA" != 1 ]; then echo "POCKET_DARIA is not in the qsf (the overlay's DARIA rows)"; fi ;;
		frames) if [ ! -f "$HERE/tb_frames.sv" ]; then echo "sim/tb_frames.sv does not exist"
			elif [ -z "${GAMES:-}" ] || [ ! -d "${GAMES:-}" ]; then echo "GAMES (the directory of game images) not given"
			elif [ -z "${R1_DIR:-}" ] || [ ! -d "${R1_DIR:-}" ]; then echo "R1_DIR (the reference runs) not given"; fi ;;
	esac
}

selected() {
	[ -z "$ONLY" ] || [[ "$ONLY" == *",$1,"* ]] || return 1
	[[ "$OPTIN" != *" $1 "* ]] || [[ "$ONLY" == *",$1,"* ]] || return 1
	[[ "$SKIP" != *",$1,"* ]]
}

# EXTRA_JOBS>1 needs a slot per piece: without EXTRA_SLOT or SIM_LOCK every
# piece would run at once, outside any slot
if [ "$LIST" != 1 ] && selected extra_tests && [ "${EXTRA_JOBS:-1}" -gt 1 ] && [ -z "${EXTRA_SLOT:-}" ] && [ -z "${SIM_LOCK:-}" ]; then
	echo "step7_gates.sh: EXTRA_JOBS=$EXTRA_JOBS needs EXTRA_SLOT (on the owner's VM, EXTRA_SLOT=~/daria_work/bin/simslot) or SIM_LOCK; without either every piece runs outside a slot" >&2
	exit 2
fi
if [ "$LIST" = 1 ]; then
	for g in "${GATES[@]}"; do
		w="$(avail "$g")"
		[[ "$OPTIN" != *" $g "* ]] || w="${w:-available} (opt-in: --only $g)"
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
		# the tape loads' fingerprints exist only in an AR_TAPE=1 run
		case "$d" in extra_ar_tape_full.csv|extra_ar_tape_multi.csv)
			[ "${AR_TAPE:-0}" = 1 ] || { echo "-- fingerprints $d: not compared (AR_TAPE=1 runs the tape load that writes it)"; continue; } ;;
		esac
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
	local q=comments
	if [ "$QSF_DARIA" = 1 ]; then
		q=daria
		git -C "$REPO" show "$PP_GUARD_FROM:src/fpga/ap_core.qsf" 2> /dev/null \
			| grep -q '^set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"' && q=release
	fi
	python3 "$REPO/sim/tools/pp_guards.py" --repo "$REPO" --from "$PP_GUARD_FROM" --to HEAD --qsf "$q"
}
g_divider() { python3 "$HERE/check/div_check.py" --repo "$REPO"; }
g_cartram() {
	local w="$OUT/cartram_work" p="$OUT/cartram_plain" rc=0 fp=() only=()
	[ "$QSF_DARIA" = 1 ] && fp=(--fp)
	[ -n "${CARTRAM_ONLY:-}" ] && only=(--only "$CARTRAM_ONLY")
	mkdir -p "$w"
	WORK="$w" BUILD_TOP=tb_cartram bash "$HERE/run_sim.sh" || return 1
	slot python3 "$HERE/cartram2600_test.py" matrix --work "$w" "${fp[@]}" "${only[@]}" || rc=1
	slot python3 "$HERE/cartram2600_test.py" s19 --work "$w" "${fp[@]}" || rc=1
	if grep -qE '\bt_new\b' "$REPO/src/fpga/core/sram_ctrl.sv"; then
		echo "== Fix B: the console-reset sweep, the address compare and the P2 assertion, and the mutants they catch"
		slot python3 "$HERE/cartram2600_test.py" reset --work "$w" || rc=1
		slot python3 "$HERE/cartram2600_test.py" midswap --work "$w" || rc=1
		slot python3 "$HERE/cartram2600_test.py" forcecoinc --work "$w" || rc=1
		slot python3 "$HERE/cartram2600_test.py" reset --work "$w" --mutant nohold \
			--only rst_hif8_rd_rst_k0,rst_hie7_wr_load_k0,rst_ar_rst_k0 || rc=1
		slot python3 "$HERE/cartram2600_test.py" forcecoinc --work "$w" --mutant nohold --modes c_rd || rc=1
		slot python3 "$HERE/cartram2600_test.py" midswap --work "$w" --mutant nocmp || rc=1
	fi
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
	local args=(--work "$OUT/selftest" --tools) miss=()
	# each log-based group of planted faults needs its input, which an earlier gate of this run writes
	if [ -f "$OUT/run_sim.out" ]; then args+=(--run-sim "$OUT/run_sim.out")
	else miss+=("--run-sim ($OUT/run_sim.out: the run_sim gate)"); fi
	if [ -f "$OUT/rs/fp/load_a26.csv" ]; then args+=(--fp "$OUT/rs/fp/load_a26.csv")
	else miss+=("--fp ($OUT/rs/fp/load_a26.csv: the run_sim gate)"); fi
	if [ -f "$OUT/cartram_work/cartram/logs/e7_b0.log" ]; then args+=(--cartram "$OUT/cartram_work/cartram/logs/e7_b0.log")
	else miss+=("--cartram ($OUT/cartram_work/cartram/logs/e7_b0.log: the cartram gate)"); fi
	if [ -f "$OUT/cartram_work/cartram/logs/rst_hif8_rd_rst_k0.log" ]; then
		args+=(--reset "$OUT/cartram_work/cartram/logs/rst_hif8_rd_rst_k0.log")
	elif grep -qE '\bt_new\b' "$REPO/src/fpga/core/sram_ctrl.sv"; then
		miss+=("--reset ($OUT/cartram_work/cartram/logs/rst_hif8_rd_rst_k0.log: the cartram gate, with Fix B in the tree)")
	fi
	if [ -f "$OUT/rs/cartram/logs/artape_b0.log" ]; then args+=(--artape "$OUT/rs/cartram/logs/artape_b0.log")
	else miss+=("--artape ($OUT/rs/cartram/logs/artape_b0.log: the extra_tests gate with AR_TAPE=1)"); fi
	if [ -f "$OUT/extra_tests.out" ] && [ -n "${EXTRA_REF:-}" ]; then
		args+=(--extra "$OUT/extra_tests.out" --extra-ref "$EXTRA_REF" --extra-dir "$OUT/rs/extra")
	else miss+=("--extra ($OUT/extra_tests.out and EXTRA_REF: the extra_tests gate)"); fi
	python3 "$HERE/check/selftest.py" "${args[@]}" || return 1
	if [ ${#miss[@]} -gt 0 ]; then
		echo "PARTIAL: every planted fault that ran was caught; not run for want of their input: $(printf '%s; ' "${miss[@]%% (*}" | sed 's/; $//')"
		printf '  missing: %s\n' "${miss[@]}"
		return 3
	fi
	return 0
}
g_fit_selftest() { bash "$HERE/bupchip/quartus_probe/step7/selftest.sh"; }
g_extra_tests() {
	[ -x "$OUT/rs/obj_load/vtb" ] || { echo "no run_sim build in $OUT/rs: run the run_sim gate first"; return 1; }
	local tape=() rc=0 bg=""
	# xrun OUT VAR=VALUE...: one whole extra_tests.sh run with FP=1 (any
	# EXTRA_ONLY cleared), in pieces with EXTRA_JOBS>1, its exit status
	# appended to OUT
	xrun() {
		local o="$1"; shift
		( export "$@" FP=1 EXTRA_ONLY=
		if [ "${EXTRA_JOBS:-1}" -gt 1 ]; then
			[ -n "${EXTRA_SLOT:-}" ] || { [ -n "${SIM_LOCK:-}" ] && export EXTRA_SLOT="flock $SIM_LOCK nice -n 10"; }
			nice -n 10 bash "$HERE/extra_tests.sh"
		elif [ -n "${EXTRA_SLOT:-}" ]; then
			$EXTRA_SLOT bash "$HERE/extra_tests.sh"
		else
			slot bash "$HERE/extra_tests.sh"
		fi ) > "$o" 2>&1
		echo "exit $?" >> "$o"
	}
	if [ "$QSF_DARIA" = 1 ] && [ "${EXTRA_BOTH:-0}" = 1 ] && [ -x "$OUT/rs_plain/obj_load/vtb" ]; then
		xrun "$OUT/extra_tests_plain.out" DARIA=0 WORK="$OUT/rs_plain" & bg=$!
	fi
	xrun "$OUT/extra_tests.out" WORK="$OUT/rs"
	[ -z "$bg" ] || wait "$bg"
	cat "$OUT/extra_tests.out"
	[ "${AR_TAPE:-0}" = 1 ] && tape=(--ar-tape)
	python3 "$HERE/check/extra_tests_check.py" "$OUT/extra_tests.out" --ref "$EXTRA_REF" "${tape[@]}" || rc=1
	fp_compare 'extra_*.csv' || rc=1
	if [ "$QSF_DARIA" = 1 ]; then
		echo "== the plain build (DARIA=0): extra_tests.sh on run_sim's plain WORK, and the fingerprints equal (plan 7.5 row 5)"
		[ -x "$OUT/rs_plain/obj_load/vtb" ] || { echo "  FAIL: no plain run_sim build in $OUT/rs_plain (the run_sim gate makes it)"; return 1; }
		[ -n "$bg" ] || xrun "$OUT/extra_tests_plain.out" DARIA=0 WORK="$OUT/rs_plain"
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
	local snap=0
	[ -f "$REPO/src/fpga/core/bupchip/bup_dbg_snap.sv" ] && snap=1
	echo "== s4/check.sh, the DARIA set (DARIA=1 ARM38=1 PSRAM_CS=50.0 SNAP_REQUIRED=$snap)"
	DARIA=1 ARM38=1 PSRAM_CS=50.0 SNAP_REQUIRED=$snap JOBS="${S4_JOBS:-2}" WORK="$OUT/s4_daria" slot bash "$HERE/bupchip/s4/check.sh" "${game[@]}" || rc=1
	[ $rc = 0 ] || return 1
	[ -f "$REPO/src/fpga/mister/rtl/bupchip.hex" ] || why="no firmware in the tree (check.sh reads src/fpga/mister/rtl/bupchip.hex)"
	[ -n "${S4_GAME:-}" ] || why="${why:+$why; }no S4_GAME and REFDIR"
	if [ -n "$why" ]; then
		echo "PARTIAL: every job that ran passed, on both sets; plan 1.2 row 5 needs the firmware and game jobs: $why"
		return 3
	fi
	return 0
}
g_lint() { bash "$HERE/lint_step7.sh" --debug; }
g_wire() {
	local w="$OUT/wire" wp="$HERE/bupchip/daria/wire/wire.py" r rc=0 m mut t tdir="" why="" scn=()
	if [ -n "${GAMES:-}" ] && [ -d "${GAMES:-}" ]; then
		t="$(find "$GAMES" -name Turbo-Arcade_demo_final_CG_NTSC.bin -print -quit)"
		[ -z "$t" ] || tdir="$(dirname "$t")"
	fi
	[ -z "${WIRE_ONLY:-}" ] || scn=(${WIRE_ONLY//,/ })
	WORK="$w" slot python3 "$wp" build daria plain || return 1
	echo "== wire.py run ${scn[*]:-(every scenario)}; Turbo from ${tdir:-nowhere (no GAMES)}; BIOS ${BIOS:-not given}"
	WORK="$w" DIRECTED=1 GAMES="$tdir" slot python3 "$wp" run "${scn[@]}"; r=$?
	case $r in
	0) ;;
	3) why="scenarios not run (wire.py's NOT RUN lines: GAMES with the Turbo image, BIOS, or BUPFW, the BupChip firmware, not given)" ;;
	*) rc=1 ;;
	esac
	mut="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import wire; print(" ".join(wire.MUTANTS))' "$(dirname "$wp")")" || return 1
	[ -z "${WIRE_MUT:-}" ] || mut="${WIRE_MUT//,/ }"
	echo "== the mutants of plan 7.2 (wire.py's MUTANTS): $mut"
	for m in $mut; do
		WORK="$w/mut" slot python3 "$wp" mutant "$m" "${scn[@]}" || { echo "FAIL: mutant $m NOT CAUGHT or ERROR (its MUTANT line)"; rc=1; }
		rm -rf -- "$w/mut/mut_$m"
	done
	[ $rc = 0 ] || return 1
	[ -z "${WIRE_ONLY:-}" ] || why="${why:+$why; }WIRE_ONLY=$WIRE_ONLY"
	[ -z "${WIRE_MUT:-}" ] || why="${why:+$why; }WIRE_MUT=$WIRE_MUT"
	if [ -n "$why" ]; then
		echo "PARTIAL: every scenario that ran passed and every mutant run was CAUGHT; $why"
		return 3
	fi
	return 0
}
g_daria_smp() { WORK="$OUT/smp" slot bash "$HERE/bupchip/daria/smp/run_smp.sh" gate; }
g_dbg_snap() { WORK="$OUT/dbgsnap" slot bash "$HERE/bupchip/dbgsnap/run_dbgsnap.sh"; }
g_dbg_overlay() {
	local rc=0
	WORK="$OUT/dstat" slot bash "$HERE/bupchip/dstat/run_dstat.sh" || rc=1
	WORK="$OUT/ovl" slot bash "$HERE/bupchip/dstat/run_ovl.sh" || rc=1
	WORK="$OUT/ovl19" ARM_DIV=19 slot bash "$HERE/bupchip/dstat/run_ovl.sh" control || rc=1
	return $rc
}
g_frames() {
	local rc=0 name img ref n d="$OUT/frames" left=()
	mkdir -p "$d"
	for name in ${FRAMES_LIST:-$FRAMES16}; do
		img="$(find "$GAMES" -name "$name.bin" -print -quit)"
		ref="$R1_DIR/$name"
		echo "== $name"
		[ -n "$img" ] || { echo "  FAIL: no $name.bin under GAMES"; rc=1; continue; }
		[ -f "$ref/fp.csv" ] || { echo "  FAIL: no $ref/fp.csv"; rc=1; continue; }
		n=$(( $(wc -l < "$ref/fp.csv") ))      # the header and frames 1..N-1: N lines
		# INPUTS=tb_daria: bench parity with R1 (plan P13). R1's tb_daria
		# presents the TIA's paddle inputs as 4'b1010 (INPT1 and INPT3 high),
		# so it ran Genesis-aware games in their Genesis mode, while the
		# Pocket presents 0 there for a 2600 image with a joystick; with the
		# Pocket's inputs such a game takes another path and its RIOT and
		# video differ from R1's for a reason outside DARIA.
		WORK="$d" NAME="$name" FRAMES="$n" INPUTS=tb_daria slot bash "$HERE/run_frames.sh" "$img" || rc=1
		python3 "$HERE/check/frame_gate.py" --auto "$ref" "$d/runs/$name" --frames "$n" --name "$name" \
			--expect-guard "${FRAMES_GUARD:-locked}" --rule "${FRAMES_RULE:-v1}" || rc=1
	done
	for name in $FRAMES16; do
		[[ " $(echo ${FRAMES_LIST:-$FRAMES16}) " == *" $name "* ]] || left+=("$name")
	done
	if [ $rc = 0 ] && [ ${#left[@]} -gt 0 ]; then
		echo "PARTIAL: ${#left[@]} of plan 1.2 row 7's 16 images not run (FRAMES_LIST), every image run passed: ${left[*]}"
		return 3
	fi
	return $rc
}

declare -A RES
for g in "${GATES[@]}"; do
	if ! selected "$g"; then
		RES[$g]="not selected"
		[[ "$OPTIN" != *" $g "* ]] || RES[$g]="not selected (opt-in: --only $g)"
		continue
	fi
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
fail=0; na=0; ran=0
for g in "${GATES[@]}"; do
	case "${RES[$g]}" in FAIL*) fail=1; ran=$((ran + 1)) ;; NOT\ AVAILABLE*) na=1 ;; PARTIAL*) na=1; ran=$((ran + 1)) ;;
		PASS) ran=$((ran + 1)) ;; esac
done
[ $fail = 1 ] && { echo "STEP7_GATES FAIL"; exit 1; }
[ $ran = 0 ] && { echo "STEP7_GATES incomplete: no gate ran (none selected, or none available): not a pass"; exit 3; }
[ $na = 1 ] && { echo "STEP7_GATES incomplete: some gates are not available or partial (not a pass)"; exit 3; }
echo "STEP7_GATES pass ($ran gates)"
