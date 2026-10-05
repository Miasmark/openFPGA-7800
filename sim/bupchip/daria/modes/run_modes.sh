#!/bin/bash
# bup_cpu.sv's MODES 1 (DARIA's ARM-state additions; ../../../../docs/
# DARIA_CORE.md once written) against MiSTer's reference core:
#   1. modes.S on the reference RTL (../../verif/tb_ref_trace.sv): it must
#      reach the end marker with no abort or exception;
#   2. modes.S in lockstep with the core built with MODES 1 (MODES=1 for
#      ../../verif/run_lockstep.sh): plainly, with random asset waits and
#      throttle clocks, and built with BUP_SIM_LATE_RF;
#   3. modes.S on tb_s1.sv, which builds the core with MODES 0 (ARIA): it
#      must halt with code 1 (UNDEF) at its first MSR to SYS mode;
#      with THUMB=1, tb_s1 has DARIA's core in the BupChip profile, which
#      has MODES 1: it must run to the end marker instead;
#   4. unless QUICK=1, ../../verif/directed/run.sh with MODES=1: the
#      directed tests and fuzz seeds written for ARIA, in lockstep with the
#      MODES 1 build.
# THUMB=1 (with ARM_ONLY=1, the BupChip profile) runs all of it on DARIA's
# core (THUMB 1); give it its own WORK, VWORK and S1WORK.
# Work files go to $WORK (default sim/work/bupchip/daria/modes). Nothing here
# needs game data or the firmware. Exits 0 when everything passes.
#   ./run_modes.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/../../verif" && pwd)"
S1="$(cd "$HERE/../../s1" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/daria/modes}"
VWORK="${VWORK:-$HERE/../../../work/bupchip/verif}"
S1WORK="${S1WORK:-$HERE/../../../work/bupchip/s1}"
mkdir -p "$WORK" "$VWORK" "$S1WORK"
WORK="$(cd "$WORK" && pwd)"
VWORK="$(cd "$VWORK" && pwd)"
IMG="$WORK/assets.a78"

# The image ../../verif/directed/run.sh makes: an A78 header, a 4 KiB
# cartridge, 1 KiB of asset bytes.
python3 - "$IMG" <<'PY'
import sys
h = bytearray(128)
h[0] = 3
h[1:10] = b"ATARI7800"
h[49:53] = (4096).to_bytes(4, "big")
h[100:128] = b"ACTUAL CART DATA STARTS HERE"
assets = bytes((i * 37 + 0x81) & 0xff for i in range(1024))
open(sys.argv[1], "wb").write(bytes(h) + bytes([0xff]) * 4096 + assets)
PY

REF_BIN="$(WORK="$VWORK" "$VERIF/build.sh" ref_trace tb_ref_trace)"
LOCK_BIN="$(WORK="$VWORK" DUT=bup MODES=1 "$VERIF/run_lockstep.sh" --build)"
LOCK_LRF="$(WORK="$VWORK" DUT=bup MODES=1 LATE_RF=1 "$VERIF/run_lockstep.sh" --build)"
S1_BIN="$(WORK="$S1WORK" "$S1/build_s1.sh")"

b="$WORK/modes"
arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -I"$S1/directed" \
	-Wl,-T,"$VERIF/isa/link.ld" -Wl,--no-warn-rwx-segments -o "$b.elf" "$HERE/modes.S"
arm-none-eabi-objcopy -O binary -j .text "$b.elf" "$b.bin"
python3 "$VERIF/isa/bin2hex.py" "$b.bin" "$b.hex"
first_sys="$(arm-none-eabi-nm "$b.elf" | awk '$3 == "first_sys" { print $1 }')"

fail=0
check() {	# NAME LOG PATTERN
	if grep -Eq "$3" "$2"; then echo "PASS $1"
	else echo "FAIL $1: see $2"; grep -m3 "^MISMATCH\|halted\|^result" "$2" | sed 's/^/    /' || true; fail=$((fail + 1)); fi
}
"$REF_BIN" +rom="$IMG" +romhex="$b.hex" +maxcyc=4000000 > "$b.ref.log" 2>&1 || true
check "reference reaches the end marker" "$b.ref.log" "^result: fault=aa .* aborts=0 exceptions=0"
"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=1000000 > "$b.lock.log" 2>&1 || true
check "lockstep, MODES 1 ($(sed -n 's/^compared: \([0-9]*\) retires, \([0-9]*\) RAM stores.*/\1 retires, \2 stores/p' "$b.lock.log"))" \
	"$b.lock.log" "^LOCKSTEP PASS"
"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=1000000 +await=40 +throttle=25 +seed=11 > "$b.lock2.log" 2>&1 || true
check "lockstep, MODES 1, waits and throttle" "$b.lock2.log" "^LOCKSTEP PASS"
"$LOCK_LRF" +rom="$IMG" +romhex="$b.hex" +maxret=1000000 > "$b.lock3.log" 2>&1 || true
check "lockstep, MODES 1, BUP_SIM_LATE_RF" "$b.lock3.log" "^LOCKSTEP PASS"
"$S1_BIN" +romhex="$b.hex" +rom="$IMG" +maxcyc=200000 > "$b.s1.log" 2>&1 || true
if [ "${THUMB:-0}" = 0 ]; then
	check "MODES 0 halts with code 1 at the first MSR to SYS (0x$first_sys)" "$b.s1.log" \
		"^result: halted=1 code=1 pc=0*${first_sys#"${first_sys%%[!0]*}"} "
else
	check "THUMB 1 with arm_only (MODES 1) runs it to the end marker on tb_s1" "$b.s1.log" \
		"^result: halted=0 code=0 pc=00000000 fault=aa "
fi

if [ "${QUICK:-0}" = 0 ]; then
	if MODES=1 WORK="$WORK/directed" VWORK="$VWORK" "$VERIF/directed/run.sh"; then echo "PASS ARIA's directed tests and fuzz with MODES 1"
	else echo "FAIL ARIA's directed tests and fuzz with MODES 1"; fail=$((fail + 1)); fi
fi
echo "modes: $fail failed"
[ "$fail" = 0 ]
