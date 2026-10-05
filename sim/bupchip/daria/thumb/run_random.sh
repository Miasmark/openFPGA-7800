#!/bin/bash
# Thumb random streams for DARIA (docs/DARIA_CORE.md, "The CPU: Thumb",
# "Verification"): for each seed, gen_thumb.py writes a program; it is built,
# run on the reference RTL (tb_ref_trace.sv, must end with FAULT = 0xAA) and
# on Unicorn (thumb_iss.py, no LINT lines); all 16 KiB of RAM and the number
# of instructions to the end marker must agree (Unicorn's count plus its BL
# pairs). Then DARIA (bup_cpu.sv, THUMB 1) runs in lockstep with the
# reference three times: plainly, with +await=20 +throttle=10 +seed=SEED,
# and built with LATE_RF=1.
#   ./run_random.sh               seeds 1-400
#   ./run_random.sh 7 12-15       these seeds
# OPS operations per test (default 300), JOBS parallel seeds (default nproc).
# LOCKSTEP=0 skips DARIA. Work files go to $WORK (default
# sim/work/bupchip/daria_thumb_rand): tN.S/.elf/.bin/.hex, tN.log (reference
# and Unicorn), tN.lock{1,2,3}.log, results.txt and coverage.txt (the
# executed formats summed over the seeds). Exits 0 when every seed passes.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/../../verif" && pwd)"
WORK="${WORK:-$VERIF/../../work/bupchip/daria_thumb_rand}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
export WORK
VENV="${VENV:-$VERIF/../../work/bupchip/venv}"
PYTHON="${PYTHON:-$VENV/bin/python}"

if [ "$1" = "--one" ]; then
	# One seed, from the parallel loop below.
	set +e
	S="$2"; B="$WORK/t$S"
	rm -f "$B.sig" "$B.iss.sig" "$B.cov" "$B.lock1.log" "$B.lock2.log" "$B.lock3.log"
	if ! { python3 "$HERE/gen_thumb.py" "$S" "${OPS:-300}" > "$B.S" &&
		arm-none-eabi-gcc -mcpu=arm7tdmi -nostdlib -nostartfiles -Wl,-T,"$VERIF/isa/link.ld" \
			-Wl,--no-warn-rwx-segments -o "$B.elf" "$B.S" &&
		arm-none-eabi-objcopy -O binary -j .text "$B.elf" "$B.bin" &&
		python3 "$VERIF/isa/bin2hex.py" "$B.bin" "$B.hex"; } > "$B.log" 2>&1; then
		echo "FAIL $S: does not build, see $B.log"
		exit 0
	fi
	"$REF_BIN" +rom="$IMG" +romhex="$B.hex" +sig="$B.sig" +signum=4096 +maxcyc=2000000 >> "$B.log" 2>&1
	ref="$(sed -n 's/^result: fault=\([0-9a-f]*\) retired=\([0-9]*\).*/\1 \2/p' "$B.log")"
	why=""
	[ "${ref%% *}" = "aa" ] || why="$why reference ended with fault '${ref%% *}';"
	"$PYTHON" "$HERE/thumb_iss.py" "$B.bin" "$B.iss.sig" --image "$IMG" --cov "$B.cov" >> "$B.log" 2>&1
	iss="$(sed -n 's/^ISS: .* end code \([0-9a-f]*\), .* BL pairs, \([0-9]*\) reference retires/\1 \2/p' "$B.log")"
	grep -q "^LINT" "$B.log" && why="$why Unicorn lint: $(grep -m1 "^LINT" "$B.log" | cut -c7-);"
	[ "$ref" = "$iss" ] || why="$why end marker: reference '$ref', Unicorn '$iss';"
	cmp -s "$B.sig" "$B.iss.sig" || why="$why RAM differs;"
	if [ "$LOCKSTEP" != 0 ]; then
		"$LOCK_BIN" +rom="$IMG" +romhex="$B.hex" > "$B.lock1.log" 2>&1
		grep -q "^LOCKSTEP PASS" "$B.lock1.log" || why="$why lockstep: $(grep -m1 -E '^MISMATCH|^LOCKSTEP' "$B.lock1.log");"
		"$LOCK_BIN" +rom="$IMG" +romhex="$B.hex" +await=20 +throttle=10 +seed="$S" > "$B.lock2.log" 2>&1
		grep -q "^LOCKSTEP PASS" "$B.lock2.log" || why="$why lockstep +await +throttle: $(grep -m1 -E '^MISMATCH|^LOCKSTEP' "$B.lock2.log");"
		"$LATE_BIN" +rom="$IMG" +romhex="$B.hex" > "$B.lock3.log" 2>&1
		grep -q "^LOCKSTEP PASS" "$B.lock3.log" || why="$why lockstep LATE_RF: $(grep -m1 -E '^MISMATCH|^LOCKSTEP' "$B.lock3.log");"
	fi
	if [ -z "$why" ]; then
		cskip="$(sed -n 's/^C not compared in \([0-9]*\) retires.*/\1/p' "$B.lock1.log" 2>/dev/null)"
		echo "PASS $S (${ref#* } retires, ${cskip:-0} with C unknown)"
	else
		echo "FAIL $S:$why see $B.log"
	fi
	exit 0
fi

SEEDS=()
for a in "${@:-1-400}"; do
	case "$a" in
		*-*) for ((s = ${a%-*}; s <= ${a#*-}; s++)); do SEEDS+=("$s"); done ;;
		*) SEEDS+=("$a") ;;
	esac
done
"$PYTHON" -c "import unicorn" 2>/dev/null || { echo "no unicorn in $PYTHON: run sim/bupchip/setup_dev.sh, or set VENV or PYTHON" >&2; exit 1; }
REF_BIN="$("$VERIF/build.sh" ref_trace tb_ref_trace)"
IMG="$WORK/thumb_rand.a78"
python3 "$HERE/gen_thumb.py" --image "$IMG"
if [ "$LOCKSTEP" != 0 ]; then
	LOCK_BIN="$(THUMB=1 DUT=bup "$VERIF/run_lockstep.sh" --build)"
	LATE_BIN="$(LATE_RF=1 THUMB=1 DUT=bup "$VERIF/run_lockstep.sh" --build)"
fi
export REF_BIN LOCK_BIN LATE_BIN IMG PYTHON LOCKSTEP OPS
start=$(date +%s)
printf '%s\n' "${SEEDS[@]}" | xargs -P "${JOBS:-$(nproc)}" -I{} "$0" --one {} | tee "$WORK/results.txt"
sort -t' ' -k2 -n -o "$WORK/results.txt" "$WORK/results.txt"
covs=()
for s in "${SEEDS[@]}"; do [ -f "$WORK/t$s.cov" ] && covs+=("$WORK/t$s.cov"); done
[ ${#covs[@]} -eq 0 ] || python3 "$HERE/thumb_iss.py" --cover "${covs[@]}" > "$WORK/coverage.txt"
pass=$(grep -c "^PASS" "$WORK/results.txt" || true)
nref=$(grep -c "^FAIL.*reference ended" "$WORK/results.txt" || true)
niss=$(grep -cE "^FAIL.*(Unicorn|end marker|RAM differs)" "$WORK/results.txt" || true)
nlock=$(grep -c "^FAIL.*lockstep" "$WORK/results.txt" || true)
nbuild=$(grep -c "^FAIL.*does not build" "$WORK/results.txt" || true)
[ -f "$WORK/coverage.txt" ] && sed -n '1,11p' "$WORK/coverage.txt"
echo "Thumb random: $pass of ${#SEEDS[@]} seeds pass ($nbuild do not build, $nref reference," \
	"$niss reference/Unicorn, $nlock lockstep failures) in $(( $(date +%s) - start )) s; $WORK/results.txt"
[ "$pass" -eq "${#SEEDS[@]}" ]
