#!/bin/bash
# Every check of the S1 core (docs/BUPCHIP_CORE.md, step 2), in one run:
#   1. the directed and halt tests (run_directed.sh);
#   2. ../verif/run_all.sh with DUT=bup and LOCKSTEP=1: the ISA suite against
#      Unicorn and in lockstep, the mixer harness in lockstep, the synthetic
#      ARSC checks in lockstep, and with GAME.a78 the lockstep through boot and
#      Misery_F with the corrupted-load check;
#   3. with GAME.a78, SONGS (default "13 14 9 30") for SECS seconds (default
#      4) on tb_s1.sv (run_s1.sh, up to JOBS at once, default nproc): PCM
#      identical to MiSTer's ($REFDIR/song<N>.pcm, default
#      sim/work/bupchip/ref) with no halt, underrun or overflow, and Misery_F
#      (song 13) at a CPI within 1% of 1.383.
#   ./check.sh [GAME.a78]
# About 3 minutes without a game, 6 with one on 4 cores. Exits 0 when
# everything passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s1}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
REFDIR="${REFDIR:-$WORK/../ref}"
GAME="${1:+$(realpath "$1")}"
RESULTS=()
step() {
	local name="$1"; shift
	echo "=== $name"
	if "$@"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); fi
}

step "directed and halt tests" "$HERE/run_directed.sh"
step "verification suite with DUT=bup (../verif/run_all.sh)" \
	env DUT=bup LOCKSTEP=1 WORK="$WORK/../verif" "$HERE/../verif/run_all.sh" ${GAME:+"$GAME"}

if [ -n "$GAME" ]; then
	"$HERE/build_s1.sh" > /dev/null
	SONGS="${SONGS:-13 14 9 30}"
	for s in $SONGS; do echo "$s"; done | xargs -P "${JOBS:-$(nproc)}" -I{} sh -c \
		'REF="$1/song$2.pcm" "$3/run_s1.sh" "$4" "$2" "$5" > "$6/song$2.out" 2>&1; echo $? > "$6/song$2.rc"' \
		_ "$REFDIR" {} "$HERE" "$GAME" "${SECS:-4}" "$WORK"
	for s in $SONGS; do
		echo "=== song $s, ${SECS:-4} s"
		grep -E "^(busy|work|audio|fifo|status|PCM|batches)" "$WORK/song$s.out" || true
		ok=0
		[ "$(cat "$WORK/song$s.rc")" = 0 ] && grep -q "^PCM IDENTICAL: all" "$WORK/song$s.out" && ok=1
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
