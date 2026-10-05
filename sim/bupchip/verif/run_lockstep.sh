#!/bin/bash
# Lockstep the reference BupChip against a core under test, retire by retire
# (tb_lockstep.sv; README.md). DUT=ref (the default) runs the reference against
# a second copy of itself on a zero-wait bus; DUT=bup runs the new core, built
# from BUP_SRCS (default: src/fpga/core/bupchip/bup_cpu.sv and bup_regfile.sv);
# with LATE_RF=1 it is built with BUP_SIM_LATE_RF, so register-file writes
# land a clock late (bup_cpu.sv) and only the bypass keeps results right;
# with MODES=1 the core is built with MODES 1 (SVC, SYS and FIQ, banked);
# with THUMB=1, with THUMB 1 (and MODES 1: DARIA), arm_only low unless
# ARM_ONLY=1 (the BupChip profile).
#   ./run_lockstep.sh IMAGE.a78 [+plusargs...]
#   ./run_lockstep.sh rv.a78 +song=13 +songcyc=1000000 +maxret=1000000
#   ./run_lockstep.sh --build     only build, and print the binary's path
# Plusargs are tb_lockstep.sv's. Writes $LOG (default
# $WORK/lockstep_<image>.log); exits 0 on LOCKSTEP PASS.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/verif}"
export WORK
DUT="${DUT:-ref}"
[ $# -gt 0 ] || { echo "usage: run_lockstep.sh IMAGE.a78 [+plusargs...]" >&2; exit 2; }
mkdir -p "$WORK"
case "$DUT" in
	ref)
		BIN="$("$HERE/build.sh" lockstep_ref tb_lockstep lockstep_dut_ref.sv)" ;;
	bup)
		CORE="$(cd "$HERE/../../../src/fpga/core" && pwd)/bupchip"
		if [ -z "$BUP_SRCS" ]; then
			[ -f "$CORE/bup_cpu.sv" ] || { echo "DUT=bup: $CORE/bup_cpu.sv does not exist yet (docs/BUPCHIP_CORE.md, step 2)" >&2; exit 2; }
			BUP_SRCS="$CORE/bup_cpu.sv"
			[ -f "$CORE/bup_regfile.sv" ] && BUP_SRCS="$BUP_SRCS $CORE/bup_regfile.sv"
		fi
		NAME=lockstep_bup
		[ "${LATE_RF:-0}" = 0 ] || { NAME=lockstep_bup_laterf; BUP_SRCS="$BUP_SRCS -DBUP_SIM_LATE_RF"; }
		[ "${MODES:-0}" = 0 ] || { NAME=${NAME}_modes; BUP_SRCS="$BUP_SRCS -DBUP_MODES"; }
		[ "${THUMB:-0}" = 0 ] || { NAME=${NAME}_thumb; BUP_SRCS="$BUP_SRCS -DBUP_THUMB"; }
		[ "${ARM_ONLY:-0}" = 0 ] || { NAME=${NAME}_armonly; BUP_SRCS="$BUP_SRCS -DBUP_ARM_ONLY"; }
		# shellcheck disable=SC2086
		BIN="$("$HERE/build.sh" "$NAME" tb_lockstep lockstep_dut_bup.sv $BUP_SRCS -DDUT_BUP)" ;;
	*)
		echo "DUT must be ref or bup" >&2; exit 2 ;;
esac
[ "$1" = "--build" ] && { echo "$BIN"; exit 0; }
IMAGE="$(realpath "$1")"
shift
LOG="${LOG:-$WORK/lockstep_$(basename "$IMAGE" .a78).log}"
"$BIN" +rom="$IMAGE" "$@" | grep -v "^- " | tee "$LOG"
grep -q "^LOCKSTEP PASS" "$LOG"
