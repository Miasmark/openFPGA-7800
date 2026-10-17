#!/bin/bash
# Directed Thumb tests of DARIA's core (docs/DARIA_CORE.md, "The CPU: Thumb",
# "Verification", the "Directed" row of the Tests table). Each directed/*.S
#   1. runs on the reference RTL (../../verif/tb_ref_trace.sv), which must
#      reach the end marker (a FAULT write of 0xAA) with no abort and no
#      exception;
#   2. runs in lockstep with bup_cpu built with THUMB 1 (DARIA: Thumb and
#      ARM, MODES 1, arm_only low) against the reference
#      (../../verif/tb_lockstep.sv, DUT=bup THUMB=1), where every retire (PC,
#      encoding, r0-r14, NZCV, T), RAM store and peripheral access must
#      agree, with C skipped only while the core reports it unknown:
#        plain;
#        with random asset waits and throttle clocks (+await=40
#        +throttle=25), once per seed in SEEDS (default "11 23");
#        with the core built with BUP_SIM_LATE_RF (LATE_RF=1: register-file
#        writes land a clock late, so only the bypass keeps results right).
# Unicorn is not used: these tests are about what ARMv4T does and ARMv5T does
# not (POP {pc} without interworking, BX PC alignment, the C flag after MUL).
#   ./run_directed.sh [TEST.S ...]     default: directed/*.S
# JOBS (default 2) tests run at once. The image carries 1 KiB of patterned
# asset bytes (as ../../s1/run_directed.sh makes it), so tests load from the
# asset window and +await has something to delay. Work files and the
# Verilator builds go to $WORK (default sim/work/bupchip/daria/thumb). Prints
# one line per test, then the pass count of each variant; exits 0 when
# everything passes.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/../../verif" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/daria/thumb}"
JOBS="${JOBS:-2}"
SEEDS="${SEEDS:-11 23}"
mkdir -p "$WORK/directed"
WORK="$(cd "$WORK" && pwd)"
OUT="$WORK/directed"
IMG="$WORK/assets.a78"
T0=$(date +%s)

# A78 header, a 4 KiB cartridge, then 1 KiB of asset bytes (both signs).
python3 - "$IMG" <<'EOF'
import sys
h = bytearray(128)
h[0] = 3
h[1:10] = b"ATARI7800"
h[49:53] = (4096).to_bytes(4, "big")
h[100:128] = b"ACTUAL CART DATA STARTS HERE"
assets = bytes((i * 37 + 0x81) & 0xff for i in range(1024))
open(sys.argv[1], "wb").write(bytes(h) + bytes([0xff]) * 4096 + assets)
EOF

REF_BIN="$(WORK="$WORK" "$VERIF/build.sh" ref_trace tb_ref_trace)"
LOCK_BIN="$(WORK="$WORK" DUT=bup THUMB=1 "$VERIF/run_lockstep.sh" --build)"
LATE_BIN="$(WORK="$WORK" DUT=bup THUMB=1 LATE_RF=1 "$VERIF/run_lockstep.sh" --build)"

TESTS=("$@")
[ $# -gt 0 ] || TESTS=("$HERE"/directed/*.S)

# One test: build, then every run; the verdicts go to $OUT/NAME.res, one
# "variant PASS|FAIL" line each, and a summary line to $OUT/NAME.line.
run_one() {
	local t="$1" n b v why=""
	n="$(basename "${t%.S}")"
	b="$OUT/$n"
	: > "$b.res"
	if ! { arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -I "$HERE/directed" \
			-Wl,-T,"$VERIF/isa/link.ld" -Wl,--no-warn-rwx-segments -o "$b.elf" "$t" &&
		arm-none-eabi-objcopy -O binary -j .vectors -j .text "$b.elf" "$b.bin" &&
		python3 "$VERIF/isa/bin2hex.py" "$b.bin" "$b.hex" &&
		arm-none-eabi-objdump -d "$b.elf" > "$b.dis"; } > "$b.build.log" 2>&1; then
		echo "build FAIL" > "$b.res"
		echo "FAIL $n: does not build, see $b.build.log" > "$b.line"
		return
	fi
	"$REF_BIN" +rom="$IMG" +romhex="$b.hex" +maxcyc=4000000 +trace="$b.trace" > "$b.ref.log" 2>&1 || true
	if grep -q "^result: fault=aa .* aborts=0 exceptions=0" "$b.ref.log"; then v=PASS; else v=FAIL; why="$why reference;"; fi
	echo "reference $v" >> "$b.res"
	"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=10000000 > "$b.lock.log" 2>&1 || true
	if grep -q "^LOCKSTEP PASS" "$b.lock.log"; then v=PASS; else v=FAIL; why="$why plain ($b.lock.log);"; fi
	echo "plain $v" >> "$b.res"
	for s in $SEEDS; do
		"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=10000000 +await=40 +throttle=25 +seed="$s" \
			> "$b.lock_s$s.log" 2>&1 || true
		if grep -q "^LOCKSTEP PASS" "$b.lock_s$s.log"; then v=PASS; else v=FAIL; why="$why await+throttle seed $s ($b.lock_s$s.log);"; fi
		echo "await40_throttle25_seed$s $v" >> "$b.res"
	done
	"$LATE_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=10000000 > "$b.late.log" 2>&1 || true
	if grep -q "^LOCKSTEP PASS" "$b.late.log"; then v=PASS; else v=FAIL; why="$why LATE_RF ($b.late.log);"; fi
	echo "late_rf $v" >> "$b.res"
	if [ -z "$why" ]; then
		echo "PASS $n ($(sed -n 's/^compared: \([0-9]*\) retires, \([0-9]*\) RAM stores, \([0-9]*\) peripheral writes; \([0-9]*\).*/\1 retires, \2 stores, \3 peripheral writes, \4 peripheral reads/p' "$b.lock.log") compared$(sed -n 's/^C not compared in \([0-9]*\) retires.*/; C skipped in \1/p' "$b.lock.log"))" > "$b.line"
	else
		{ echo "FAIL $n:$why"
		  cat "$b.lock.log" "$b.late.log" 2>/dev/null | grep -m3 "^MISMATCH\|halted" | sed 's/^/    /' || true; } > "$b.line"
	fi
}

for t in "${TESTS[@]}"; do
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
	run_one "$t" &
done
wait

fail=0
for t in "${TESTS[@]}"; do
	n="$(basename "${t%.S}")"
	cat "$OUT/$n.line"
	grep -q "^PASS" "$OUT/$n.line" || fail=$((fail + 1))
done
echo "directed, per variant (passed of ${#TESTS[@]}):"
for v in reference plain $(for s in $SEEDS; do echo "await40_throttle25_seed$s"; done) late_rf; do
	k=0
	for t in "${TESTS[@]}"; do
		grep -q "^$v PASS" "$OUT/$(basename "${t%.S}").res" 2>/dev/null && k=$((k + 1))
	done
	echo "  $v: $k"
done
echo "directed: $(( ${#TESTS[@]} - fail )) passed, $fail failed, $(( $(date +%s) - T0 )) s"
[ "$fail" = 0 ]
