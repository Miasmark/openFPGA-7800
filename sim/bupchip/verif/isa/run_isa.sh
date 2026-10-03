#!/bin/bash
# ISA suite: assemble each test, run it on the reference RTL (tb_ref_trace.sv)
# and on Unicorn (iss_run.py), and compare the RAM signatures and the number
# of instructions to the end marker.
#   ./run_isa.sh                 sample.S, then gen_random.py for each seed in seeds.txt
#   ./run_isa.sh TEST.S ...      only these
# OPS operations per random test (default 300), JOBS parallel runs (default
# nproc). LOCKSTEP=1 also runs every test through tb_lockstep.sv (DUT=ref, or
# DUT=bup for the new core); ISS=0 skips Unicorn, for directed tests outside
# the subset ARMv4 and ARMv5 share (they need LOCKSTEP=1). Work files go to
# $WORK/isa; exits 0 when every test passes. Unicorn comes from $VENV
# (setup_dev.sh makes it) or PYTHON.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIF="$(cd "$HERE/.." && pwd)"
WORK="${WORK:-$VERIF/../../work/bupchip/verif}"
mkdir -p "$WORK/isa"
WORK="$(cd "$WORK" && pwd)"
export WORK
VENV="${VENV:-$VERIF/../../work/bupchip/venv}"
PYTHON="${PYTHON:-$VENV/bin/python}"

if [ "$1" = "--one" ]; then
	# One test, from the parallel loop below: T.S -> T.elf/.bin/.hex/.sig/.iss.sig
	set +e
	T="$2"; B="$WORK/isa/$(basename "${T%.S}")"
	rm -f "$B.sig" "$B.iss.sig"
	if ! { arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -Wl,-T,"$HERE/link.ld" \
		-Wl,--no-warn-rwx-segments -o "$B.elf" "$T" && arm-none-eabi-objcopy -O binary -j .text "$B.elf" "$B.bin" &&
		python3 "$HERE/bin2hex.py" "$B.bin" "$B.hex"; } > "$B.log" 2>&1; then
		echo "FAIL $(basename "$T"): does not build, see $B.log"
		exit 0
	fi
	"$WORK/obj_ref_trace/vtb" +rom="$WORK/isa/blank.a78" +romhex="$B.hex" +sig="$B.sig" \
		+maxcyc=2000000 >> "$B.log" 2>&1
	ref="$(sed -n 's/^result: fault=\([0-9a-f]*\) retired=\([0-9]*\).*/\1 \2/p' "$B.log")"
	why=""
	[ "${ref%% *}" = "aa" ] || why="$why reference ended with fault ${ref%% *};"
	if [ "$ISS" != 0 ]; then
		"$PYTHON" "$HERE/iss_run.py" "$B.bin" "$B.iss.sig" 2048 >> "$B.log" 2>&1
		iss="$(sed -n 's/^ISS: \([0-9]*\) instructions, end code \(.*\)/\2 \1/p' "$B.log")"
		[ "$ref" = "$iss" ] || why="$why end marker: reference '$ref', Unicorn '$iss';"
		cmp -s "$B.sig" "$B.iss.sig" || why="$why signatures differ;"
	fi
	if [ -n "$LOCKSTEP" ]; then
		"$LOCKSTEP_BIN" +rom="$WORK/isa/blank.a78" +romhex="$B.hex" > "$B.lock.log" 2>&1 || true
		grep -q "^LOCKSTEP PASS" "$B.lock.log" || why="$why lockstep failed ($B.lock.log);"
	fi
	if [ -z "$why" ]; then
		echo "PASS $(basename "$T") (${ref#* } instructions, $(grep -vc '^00000000$' "$B.sig") nonzero signature words)"
	else
		echo "FAIL $(basename "$T"):$why see $B.log"
	fi
	exit 0
fi

[ "$ISS" = 0 ] || "$PYTHON" -c "import unicorn" 2>/dev/null || { echo "no unicorn in $PYTHON: run sim/bupchip/setup_dev.sh, or set VENV or PYTHON" >&2; exit 1; }
"$VERIF/build.sh" ref_trace tb_ref_trace > /dev/null
python3 "$VERIF/make_synth_arsc.py" "$WORK/isa/blank.a78" --none > /dev/null
if [ -n "$LOCKSTEP" ]; then
	LOCKSTEP_BIN="$("$VERIF/run_lockstep.sh" --build)"
	export LOCKSTEP_BIN
fi
export LOCKSTEP PYTHON ISS
TESTS=()
if [ $# -gt 0 ]; then
	for t in "$@"; do TESTS+=("$(realpath "$t")"); done
else
	TESTS+=("$HERE/sample.S")
	while read -r seed; do
		case "$seed" in ''|'#'*) continue ;; esac
		python3 "$HERE/gen_random.py" "$seed" "${OPS:-300}" > "$WORK/isa/rand$seed.S"
		TESTS+=("$WORK/isa/rand$seed.S")
	done < "$HERE/seeds.txt"
fi
printf '%s\n' "${TESTS[@]}" | xargs -P "${JOBS:-$(nproc)}" -I{} "$0" --one {} | tee "$WORK/isa/results.txt"
pass=$(grep -c "^PASS" "$WORK/isa/results.txt" || true)
echo "ISA: $pass of ${#TESTS[@]} tests pass"
[ "$pass" -eq "${#TESTS[@]}" ]
