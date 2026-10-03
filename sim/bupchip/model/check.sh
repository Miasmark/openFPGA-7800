#!/bin/bash
# Regression for the Python model of the BupChip firmware.
#   ./check.sh [GAME.a78 [REF_DIR]]
# Without arguments it needs no game files: the static inventory (1,704 code
# words, objdump agrees), the synthetic ARSC's coverage, and the synthetic
# block booting and rendering 0.25 s of songs 0 and 1 (PCM in $WORK). With
# GAME.a78 (Rikki & Vikki with its ARSC block), each song<N>.pcm that
# run_bupchip.sh left in REF_DIR (default $WORK/../ref) must come out
# identical. About 20 s, plus 10-65 s per reference song.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/model}"
GAME="${1:+$(realpath "$1")}"
REF="$(realpath -m "${2:-$WORK/../ref}")"
mkdir -p "$WORK"
cd "$HERE"
fail=0

python3 inventory.py > "$WORK/inventory.txt"
grep -q "^code words: 1704;" "$WORK/inventory.txt" || { echo "FAIL inventory: code words changed"; fail=1; }
grep -q "objdump cross-check: 1704 code words, 0 mismatches" "$WORK/inventory.txt" ||
	grep -q "objdump cross-check skipped" "$WORK/inventory.txt" || { echo "FAIL inventory: objdump disagrees"; fail=1; }
grep -E "^code words|objdump" "$WORK/inventory.txt"

python3 coverage.py > "$WORK/coverage.txt"
grep -E "^coverage|handlers run|fault 0x" "$WORK/coverage.txt"
grep -q "coverage: 1516 of 1704" "$WORK/coverage.txt" || { echo "FAIL coverage changed"; fail=1; }

python3 synth_arsc.py "$WORK/synthetic.a78" > /dev/null
for s in 0 1; do
	out="$(python3 armemu.py "$WORK/synthetic.a78" --song $s --secs 0.25 --pcm "$WORK/synthetic_song$s.pcm")"
	echo "synthetic song $s: $(grep "^PCM" <<< "$out")"
	grep -q "fault None, FIFO overflow False" <<< "$out" || { echo "FAIL synthetic song $s: fault or overflow"; fail=1; }
	grep -q " 0 non-zero)" <<< "$out" && { echo "FAIL synthetic song $s: silent"; fail=1; }
done

if [ -n "$GAME" ]; then
	for f in "$REF"/song*.pcm; do
		n="$(basename "$f" .pcm)"; n="${n#song}"
		python3 armemu.py "$GAME" --song "$n" --secs 4 --pcm "$WORK/song$n.pcm" --ref "$f" | tail -1 || fail=1
	done
fi
[ $fail = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
