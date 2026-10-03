#!/bin/bash
# Every BupChip verification check that needs no game data, and, given a
# game image with its ARSC block (make_arsc.py), the lockstep run on real music.
#   ./run_all.sh [GAME.a78]
#   1. ISA suite (isa/run_isa.sh): sample.S and the 200 seeds in
#      isa/seeds.txt, reference RTL against Unicorn
#   2. mixer harness (run_kernel.sh) on the reference RTL, then in lockstep
#   3. synthetic ARSC (run_synth.sh): tb_bupchip renders nonzero PCM, fault
#      paths, Unicorn replay, lockstep over every command class and random blocks
#   4. with GAME.a78: lockstep through boot and Misery_F (song 13 from clock
#      1,000,000) for MAXRET compared instructions (default 1,000,000), then
#      the same with the DUT's 50,000th data load corrupted, which must fail
# The lockstep DUT is DUT (ref, or bup for the new core). Takes about 3
# minutes on 4 cores. Exits 0 when everything passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/verif}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
export WORK
GAME="${1:+$(realpath "$1")}"
RESULTS=()
step() {
	local name="$1"; shift
	echo "=== $name"
	if "$@"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); fi
}

step "ISA suite, reference RTL against Unicorn" "$HERE/isa/run_isa.sh"
step "mixer harness, reference and lockstep" "$HERE/run_kernel.sh"
step "synthetic ARSC" "$HERE/run_synth.sh"
if [ -n "$GAME" ]; then
	step "lockstep, boot + Misery_F, ${MAXRET:-1000000} instructions" \
		env LOG="$WORK/lockstep_game.log" "$HERE/run_lockstep.sh" "$GAME" \
		+song=13 +songcyc=1000000 +maxret="${MAXRET:-1000000}"
	inject_caught() {
		LOG="$WORK/lockstep_inject.log" "$HERE/run_lockstep.sh" "$GAME" \
			+song=13 +songcyc=1000000 +maxret="${MAXRET:-1000000}" +inject=50000 > /dev/null || true
		grep -m1 "^MISMATCH" "$WORK/lockstep_inject.log"
		grep -q "^LOCKSTEP FAIL" "$WORK/lockstep_inject.log"
	}
	step "lockstep catches a corrupted load (+inject=50000)" inject_caught
fi
echo
echo "=== summary"
printf '%s\n' "${RESULTS[@]}"
! printf '%s\n' "${RESULTS[@]}" | grep -q "^FAIL"
