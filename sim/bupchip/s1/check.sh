#!/bin/bash
# Every check of the S1 core (docs/BUPCHIP_CORE.md, step 2), in one run:
#   1. the directed and halt tests (run_directed.sh);
#   2. the further directed tests, running off the end of the ROM, and the
#      random-encoding fuzz (../verif/directed/run.sh);
#   3. the verifier's directed tests (../verif/directed/run_vfy.sh: corner
#      cases in lockstep and against Unicorn, more halt and no-halt cases,
#      and, with the firmware, the decoder on every code word);
#   4. with the core built with BUP_SIM_LATE_RF (LATE_RF=1: register-file
#      writes land a clock late, so only the bypass keeps results right):
#      the directed and halt tests again, run_vfy.sh again, and the ISA
#      suite in lockstep;
#   5. ../verif/run_all.sh with DUT=bup and LOCKSTEP=1: the ISA suite against
#      Unicorn and in lockstep, the mixer harness in lockstep, the synthetic
#      ARSC checks in lockstep, and with GAME.a78 the lockstep through boot and
#      Misery_F with the corrupted-load check;
#   6. with GAME.a78, SONGS (default "13 14 9 30") for SECS seconds (default
#      4) on tb_s1.sv (run_s1.sh, up to JOBS at once, default nproc): PCM
#      identical to MiSTer's ($REFDIR/song<N>.pcm, default
#      sim/work/bupchip/ref) from the song's first frame, with no halt,
#      underrun or overflow, and Misery_F (song 13) at a CPI within 1% of
#      1.383.
#   ./check.sh [GAME.a78]
# THUMB=1 runs all of it on DARIA's core (THUMB 1, MODES 1) in the BupChip
# profile, arm_only high (docs/DARIA_CORE.md, step 2: "ARIA unchanged"); use
# a separate WORK. About 5 minutes without a game, 8 with one on 4 cores. Exits 0 when
# everything passes.
#
# Steps 1-4 need no firmware. Step 5's mixer harness and synthetic ARSC, and
# step 6, run CoreTone, which is not in the repository: put your copy of
# MiSTer's bupchip.hex at src/fpga/mister/rtl/ (docs/BUPCHIP.md, "Firmware:
# bupchip.bin"). Without it run_all.sh skips those, and a GAME argument is
# an error.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "${THUMB:-0}" = 0 ] || export THUMB=1 ARM_ONLY=1
WORK="${WORK:-$HERE/../../work/bupchip/s1}"
FW="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)/bupchip.hex"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
REFDIR="${REFDIR:-$WORK/../ref}"
GAME="${1:+$(realpath "$1")}"
if [ ! -f "$FW" ] && [ -n "$GAME" ]; then
	echo "check.sh: the game checks need the firmware, $FW (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2
	exit 2
fi
NOFW=""
[ -f "$FW" ] || NOFW=" (no firmware: the mixer harness and synthetic ARSC skipped)"
RESULTS=()
step() {
	local name="$1"; shift
	echo "=== $name"
	if "$@"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); fi
}

step "directed and halt tests" "$HERE/run_directed.sh"
step "further directed tests, end of ROM and fuzz (../verif/directed/run.sh)" \
	env WORK="$WORK/../verif/directed" VWORK="$WORK/../verif" S1WORK="$WORK" "$HERE/../verif/directed/run.sh"
step "the verifier's directed tests (../verif/directed/run_vfy.sh)" \
	env WORK="$WORK/../verif/vfy" VWORK="$WORK/../verif" S1WORK="$WORK" "$HERE/../verif/directed/run_vfy.sh"
step "directed and halt tests, register-file writes late (LATE_RF=1)" \
	env LATE_RF=1 WORK="$WORK/directed_laterf" VWORK="$WORK/../verif" "$HERE/run_directed.sh"
step "the verifier's directed tests, register-file writes late (LATE_RF=1)" \
	env LATE_RF=1 WORK="$WORK/../verif/vfy_laterf" VWORK="$WORK/../verif" S1WORK="$WORK" \
	"$HERE/../verif/directed/run_vfy.sh"
step "ISA suite in lockstep, register-file writes late (LATE_RF=1)" \
	env DUT=bup LOCKSTEP=1 LATE_RF=1 ISS=0 WORK="$WORK/../verif" "$HERE/../verif/isa/run_isa.sh"
step "verification suite with DUT=bup (../verif/run_all.sh)$NOFW" \
	env DUT=bup LOCKSTEP=1 WORK="$WORK/../verif" "$HERE/../verif/run_all.sh" ${GAME:+"$GAME"}

if [ -n "$GAME" ]; then
	"$HERE/build_s1.sh" > /dev/null
	SONGS="${SONGS:-13 14 9 30}"
	for s in $SONGS; do echo "$s"; done | xargs -P "${JOBS:-$(nproc)}" -I{} sh -c \
		'REF="$1/song$2.pcm" "$3/run_s1.sh" "$4" "$2" "$5" > "$6/song$2.out" 2>&1; echo $? > "$6/song$2.rc"' \
		_ "$REFDIR" {} "$HERE" "$GAME" "${SECS:-4}" "$WORK"
	for s in $SONGS; do
		echo "=== song $s, ${SECS:-4} s"
		grep -E "^(busy|work|audio|fifo|status|command|song starts|PCM|batches)" "$WORK/song$s.out" || true
		ok=0
		[ "$(cat "$WORK/song$s.rc")" = 0 ] && grep -q "^PCM IDENTICAL: all .* from the song's start" "$WORK/song$s.out" && ok=1
		if [ "$s" = 13 ] && [ "$ok" = 1 ]; then
			cpi="$(sed -n 's/^result: .* cpi=\([0-9.]*\) .*/\1/p' "$WORK/song$s.out")"
			python3 -c "import sys; sys.exit(0 if abs($cpi / 1.383 - 1) <= 0.01 else 1)" || ok=0
			echo "CPI $cpi against 1.383: $([ $ok = 1 ] && echo within 1% || echo OUTSIDE 1%)"
		fi
		[ "$ok" = 1 ] && RESULTS+=("PASS  song $s: PCM identical to MiSTer's") || RESULTS+=("FAIL  song $s (see $WORK/song$s.out)")
	done
fi
echo
echo "=== summary"
printf '%s\n' "${RESULTS[@]}"
! printf '%s\n' "${RESULTS[@]}" | grep -q "^FAIL"
