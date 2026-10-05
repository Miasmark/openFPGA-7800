#!/bin/bash
# The mutation check of docs/DARIA_CORE.md, step 2 ("Mutations"): every
# mutant in mutants.py (one planted Thumb bug in a copy of bup_cpu.sv) must
# be caught. For each, the suites run cheapest first until one fails:
# run_decode.sh (the exhaustive decode check), run_directed.sh,
# run_halts.sh, then run_random.sh on seeds 1-8, then run_fuzz.sh on seeds
# 1-4. A mutant that passes all of them SURVIVED.
#   ./run_mutants.sh [NAME ...]          default: every mutant
# Work files go to $WORK/<name>/ (default sim/work/bupchip/daria/mutants);
# each mutant builds its own copies of the testbenches. Summary in
# $WORK/results.txt. Exits 0 when every mutant is caught.
# SPDX-License-Identifier: MIT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/mutants}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
export JOBS="${JOBS:-2}"
NAMES=("$@")
[ $# -gt 0 ] || mapfile -t NAMES < <(python3 "$HERE/mutants.py" list)
: > "$WORK/results.txt"
survived=0
for m in "${NAMES[@]}"; do
	d="$WORK/$m"
	mkdir -p "$d"
	python3 "$HERE/mutants.py" make "$m" "$d/bup_cpu.sv"
	how=""
	# Each suite takes the mutant through its own variable.
	run() {	# LABEL COMMAND...
		local label="$1"; shift
		if ! (export BUP_SRCS="$d/bup_cpu.sv" CORE_SV="$d/bup_cpu.sv" BUP_CPU="$d/bup_cpu.sv"; "$@") \
			> "$d/$label.log" 2>&1; then how="$label"; fi
	}
	[ -n "$how" ] || run decode env WORK="$d/decode" "$HERE/run_decode.sh"
	[ -n "$how" ] || run directed env WORK="$d" "$HERE/run_directed.sh"
	[ -n "$how" ] || run halts env WORK="$d" "$HERE/run_halts.sh"
	[ -n "$how" ] || run random env WORK="$d/rand" "$HERE/run_random.sh" 1-8
	[ -n "$how" ] || run fuzz env WORK="$d/fuzz" "$HERE/run_fuzz.sh" 1 2 3 4
	if [ -n "$how" ]; then
		line="CAUGHT   $m (by $how: $d/$how.log)"
	else
		line="SURVIVED $m"; survived=$((survived + 1))
	fi
	echo "$line" | tee -a "$WORK/results.txt"
done
echo "mutants: ${#NAMES[@]}, survived: $survived" | tee -a "$WORK/results.txt"
[ "$survived" = 0 ]
