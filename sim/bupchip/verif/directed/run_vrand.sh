#!/bin/bash
# Dense random programs (vrand.py) and an exhaustive shifter sweep
# (vshift_all.S) on the new core, for each seed in SEEDS (default 1-64),
# OPS operations each (default 1800):
#   1. the full mix, through run.sh: on the reference RTL (end marker, no
#      abort), on tb_s1.sv (no halt) and in lockstep with the new core
#      (DUT=bup), plainly and with random asset waits and throttle clocks;
#   2. the --iss mix (what ARMv4 and ARMv5 do alike), through
#      ../isa/run_isa.sh: the reference's signature and instruction count
#      must equal Unicorn's, and the new core must agree in lockstep. With
#      them vshift_all.S, every shift type by every register amount 0-259
#      and every immediate encoding. This checks the shifter and condition
#      logic the reference and the new core share (arm7tdmi_pkg) against an
#      independent model.
#   ./run_vrand.sh
#   SEEDS="$(seq 1 500)" ./run_vrand.sh
#   LATE_RF=1 ./run_vrand.sh          the core built with BUP_SIM_LATE_RF
#   ISS=0 ./run_vrand.sh              part 1 only (no Unicorn needed)
# Work files go to $WORK (default sim/work/bupchip/verif/vrand, or
# vrand_laterf); the reference and lockstep builds are shared with ../
# ($VWORK) and tb_s1 with ../../s1 ($S1WORK). Unicorn as for run_isa.sh
# (VENV or PYTHON). About 1 s per seed and part on 4 cores once the builds
# exist. Exits 0 when every program passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/.." && pwd)"
SUFFIX=""
[ "${LATE_RF:-0}" = 0 ] || SUFFIX=_laterf
WORK="${WORK:-$HERE/../../../work/bupchip/verif/vrand$SUFFIX}"
VWORK="${VWORK:-$HERE/../../../work/bupchip/verif}"
S1WORK="${S1WORK:-$HERE/../../../work/bupchip/s1}"
VENV="${VENV:-$HERE/../../../work/bupchip/venv}"
mkdir -p "$WORK/src" "$WORK/iss" "$VWORK" "$S1WORK"
WORK="$(cd "$WORK" && pwd)"
VWORK="$(cd "$VWORK" && pwd)"
S1WORK="$(cd "$S1WORK" && pwd)"
VENV="$(cd "$VENV" 2>/dev/null && pwd || echo "$VENV")"
TESTS=()
ISS_TESTS=("$HERE/vshift_all.S")
for s in ${SEEDS:-$(seq 1 64)}; do
	python3 "$HERE/vrand.py" "$s" "${OPS:-1800}" > "$WORK/src/vrand$s.S"
	TESTS+=("$WORK/src/vrand$s.S")
	python3 "$HERE/vrand.py" "$s" "${OPS:-1800}" --iss > "$WORK/src/vrand${s}_iss.S"
	ISS_TESTS+=("$WORK/src/vrand${s}_iss.S")
done
RESULTS=()
step() {
	local name="$1"; shift
	echo "=== $name"
	if "$@"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); fi
}
step "${#TESTS[@]} programs: reference, tb_s1 and lockstep (run.sh)" \
	env WORK="$WORK/run" VWORK="$VWORK" S1WORK="$S1WORK" "$HERE/run.sh" "${TESTS[@]}"
if [ "${ISS:-1}" != 0 ]; then
	# run_isa.sh builds into its own WORK; lend it the builds already in $VWORK.
	LOCK=obj_lockstep_bup
	[ -z "$SUFFIX" ] || LOCK=obj_lockstep_bup_laterf
	for o in obj_ref_trace "$LOCK"; do
		[ -e "$WORK/iss/$o" ] || [ ! -d "$VWORK/$o" ] || ln -s "$VWORK/$o" "$WORK/iss/$o"
	done
	step "vshift_all.S and $((${#ISS_TESTS[@]} - 1)) --iss programs against Unicorn and in lockstep (../isa/run_isa.sh)" \
		env WORK="$WORK/iss" VENV="$VENV" ISS=1 LOCKSTEP=1 DUT=bup "$VERIF/isa/run_isa.sh" "${ISS_TESTS[@]}"
fi
echo
echo "=== summary"
printf '%s\n' "${RESULTS[@]}"
! printf '%s\n' "${RESULTS[@]}" | grep -q "^FAIL"
