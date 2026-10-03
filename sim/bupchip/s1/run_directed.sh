#!/bin/bash
# Directed tests of the S1 core (docs/BUPCHIP_CORE.md, "Verification plan"):
#   1. each directed/*.S runs on the reference RTL (../verif/tb_ref_trace.sv),
#      which must reach the end marker (a FAULT write of 0xAA), and in
#      lockstep with the new core (../verif/tb_lockstep.sv, DUT=bup), where
#      every retire, RAM store and peripheral access must agree; then in
#      lockstep again with random asset waits and throttle clocks (+await=40
#      +throttle=25). Unicorn is not used: these tests cover what ARMv4 and
#      ARMv5 do differently (unaligned and odd accesses, forms the ARM7TDMI
#      defines and later architectures do not).
#   2. halt_tests.py: one program per halt class on tb_s1.sv; the core must
#      halt with the expected code at the expected instruction.
#   ./run_directed.sh [TEST.S ...]     default: directed/*.S, then the halt tests
# The image carries 1 KiB of patterned asset bytes, so tests can load from
# the asset window. Work files go to $WORK (default
# sim/work/bupchip/s1/directed); the lockstep and reference builds are shared
# with ../verif ($VWORK). Exits 0 when everything passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/../verif" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s1/directed}"
VWORK="${VWORK:-$HERE/../../work/bupchip/verif}"
mkdir -p "$WORK" "$VWORK"
WORK="$(cd "$WORK" && pwd)"
VWORK="$(cd "$VWORK" && pwd)"
IMG="$WORK/assets.a78"

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

REF_BIN="$(WORK="$VWORK" "$VERIF/build.sh" ref_trace tb_ref_trace)"
LOCK_BIN="$(WORK="$VWORK" DUT=bup "$VERIF/run_lockstep.sh" --build)"

build() {	# T.S -> $WORK/T.hex (and .elf, .bin)
	local b="$WORK/$(basename "${1%.S}")"
	arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -Wl,-T,"$VERIF/isa/link.ld" \
		-Wl,--no-warn-rwx-segments -o "$b.elf" "$1" &&
	arm-none-eabi-objcopy -O binary -j .vectors -j .text "$b.elf" "$b.bin" &&
	python3 "$VERIF/isa/bin2hex.py" "$b.bin" "$b.hex"
}

TESTS=("$@")
[ $# -gt 0 ] || TESTS=("$HERE"/directed/*.S)
pass=0
fail=0
for t in "${TESTS[@]}"; do
	n="$(basename "${t%.S}")"
	b="$WORK/$n"
	if ! build "$t" > "$b.build.log" 2>&1; then
		echo "FAIL $n: does not build, see $b.build.log"; fail=$((fail + 1)); continue
	fi
	"$REF_BIN" +rom="$IMG" +romhex="$b.hex" +maxcyc=4000000 > "$b.ref.log" 2>&1 || true
	"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=10000000 > "$b.lock.log" 2>&1 || true
	"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=10000000 +await=40 +throttle=25 +seed=11 \
		> "$b.lock2.log" 2>&1 || true
	why=""
	grep -q "^result: fault=aa .* aborts=0 exceptions=0" "$b.ref.log" || why="$why reference did not reach the end marker cleanly;"
	grep -q "^LOCKSTEP PASS" "$b.lock.log" || why="$why lockstep failed;"
	grep -q "^LOCKSTEP PASS" "$b.lock2.log" || why="$why lockstep with waits and throttle failed ($b.lock2.log);"
	if [ -z "$why" ]; then
		echo "PASS $n ($(sed -n 's/^compared: \([0-9]*\) retires, \([0-9]*\) RAM stores, \([0-9]*\) peripheral writes; \([0-9]*\).*/\1 retires, \2 stores, \3 peripheral writes, \4 peripheral reads/p' "$b.lock.log") compared)"
		pass=$((pass + 1))
	else
		echo "FAIL $n:$why see $b.ref.log, $b.lock.log"
		grep -m3 "^MISMATCH\|halted" "$b.lock.log" | sed 's/^/    /' || true
		fail=$((fail + 1))
	fi
done
echo "directed: $pass passed, $fail failed"
if [ $# -eq 0 ]; then
	S1_BIN="$("$HERE/build_s1.sh")"
	python3 "$HERE/halt_tests.py" "$S1_BIN" "$WORK/halt" "$IMG" || fail=$((fail + 1))
fi
[ "$fail" = 0 ]
