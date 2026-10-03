#!/bin/bash
# More directed tests of the new core (docs/BUPCHIP_CORE.md, "Verification
# plan"), on top of ../../s1/run_directed.sh:
#   1. each *.S here except romend.S runs on the reference RTL
#      (../tb_ref_trace.sv), which must reach the end marker without an abort
#      or exception, and in lockstep with the new core (DUT=bup), plainly and
#      with random asset waits and throttle clocks (+await=40 +throttle=25);
#      the tests include ../../s1/directed/common.inc;
#   2. romend.S on tb_s1.sv: running off the end of the ROM must halt (code
#      4, FETCH), not wrap to 0;
#   3. fuzz_run.py for each seed in FUZZ (default "1 2 3 4 5 6 7 8"), CELLS
#      cells each (default 450): random encodings of every class; the core
#      may halt on any of them, but the rest must match the reference in
#      lockstep.
#   ./run.sh [TEST.S ...]          only these tests (a bare name is one here), no fuzz
# Work files go to $WORK (default sim/work/bupchip/verif/directed); the
# reference and lockstep builds are shared with ../ ($VWORK) and tb_s1 with
# ../../s1 ($S1WORK). Exits 0 when everything passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/.." && pwd)"
S1="$(cd "$HERE/../../s1" && pwd)"
WORK="${WORK:-$HERE/../../../work/bupchip/verif/directed}"
VWORK="${VWORK:-$HERE/../../../work/bupchip/verif}"
S1WORK="${S1WORK:-$HERE/../../../work/bupchip/s1}"
mkdir -p "$WORK" "$VWORK" "$S1WORK"
WORK="$(cd "$WORK" && pwd)"
VWORK="$(cd "$VWORK" && pwd)"
S1WORK="$(cd "$S1WORK" && pwd)"
IMG="$WORK/assets.a78"

# A78 header, a 4 KiB cartridge, then 1 KiB of asset bytes (both signs), as
# ../../s1/run_directed.sh makes it.
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
S1_BIN="$(WORK="$S1WORK" "$S1/build_s1.sh")"

build() {	# T.S -> $WORK/T.hex (and .elf, .bin)
	local b="$WORK/$(basename "${1%.S}")"
	arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -I"$S1/directed" \
		-Wl,-T,"$VERIF/isa/link.ld" -Wl,--no-warn-rwx-segments -o "$b.elf" "$1" &&
	arm-none-eabi-objcopy -O binary -j .text "$b.elf" "$b.bin" &&
	python3 "$VERIF/isa/bin2hex.py" "$b.bin" "$b.hex"
}

TESTS=()
for t in "$@"; do	# a bare name means the test here
	[ -f "$t" ] || [ ! -f "$HERE/$t" ] || t="$HERE/$t"
	TESTS+=("$t")
done
[ $# -gt 0 ] || TESTS=("$HERE"/*.S)
pass=0
fail=0
for t in "${TESTS[@]}"; do
	n="$(basename "${t%.S}")"
	b="$WORK/$n"
	if ! build "$t" > "$b.build.log" 2>&1; then
		echo "FAIL $n: does not build, see $b.build.log"; fail=$((fail + 1)); continue
	fi
	if [ "$n" = romend ]; then
		"$S1_BIN" +romhex="$b.hex" +rom="$IMG" +maxcyc=200000 > "$b.s1.log" 2>&1 || true
		if grep -Eq "^result: halted=1 code=4 pc=0000(3ffc|4000)" "$b.s1.log"; then
			echo "PASS $n (halts with code 4)"; pass=$((pass + 1))
		else
			echo "FAIL $n: running off the end of the ROM does not halt with code 4: $(grep '^result' "$b.s1.log")"
			fail=$((fail + 1))
		fi
		continue
	fi
	"$REF_BIN" +rom="$IMG" +romhex="$b.hex" +maxcyc=4000000 > "$b.ref.log" 2>&1 || true
	"$S1_BIN" +romhex="$b.hex" +rom="$IMG" +maxcyc=4000000 > "$b.s1.log" 2>&1 || true
	"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=10000000 > "$b.lock.log" 2>&1 || true
	"$LOCK_BIN" +rom="$IMG" +romhex="$b.hex" +maxret=10000000 +await=40 +throttle=25 +seed=11 \
		> "$b.lock2.log" 2>&1 || true
	why=""
	grep -q "^result: fault=aa .* aborts=0 exceptions=0" "$b.ref.log" || why="$why reference did not reach the end marker cleanly;"
	grep -q "^result: halted=0 .* fault=aa" "$b.s1.log" || why="$why the core halted on tb_s1 ($(grep '^result' "$b.s1.log"));"
	grep -q "^LOCKSTEP PASS" "$b.lock.log" || why="$why lockstep failed;"
	grep -q "^LOCKSTEP PASS" "$b.lock2.log" || why="$why lockstep with waits and throttle failed ($b.lock2.log);"
	if [ -z "$why" ]; then
		echo "PASS $n ($(sed -n 's/^compared: \([0-9]*\) retires, \([0-9]*\) RAM stores.*/\1 retires, \2 stores/p' "$b.lock.log") compared)"
		pass=$((pass + 1))
	else
		echo "FAIL $n:$why see $b.ref.log, $b.lock.log"
		grep -m3 "^MISMATCH\|halted" "$b.lock.log" | sed 's/^/    /' || true
		fail=$((fail + 1))
	fi
done
if [ $# -eq 0 ]; then
	for s in ${FUZZ:-1 2 3 4 5 6 7 8}; do
		if python3 "$HERE/fuzz_run.py" "$S1_BIN" "$LOCK_BIN" "$WORK/fuzz" "$IMG" "$s" "${CELLS:-450}"; then
			pass=$((pass + 1))
		else
			fail=$((fail + 1))
		fi
	done
fi
echo "directed (verif): $pass passed, $fail failed"
[ "$fail" = 0 ]
