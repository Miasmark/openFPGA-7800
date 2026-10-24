#!/bin/bash
# Build the AtariVox ROM images, then run the unit test on a byte file and
# check the RTL against the emulator:
#   sim/atarivox/run.sh BYTES_FILE [tb plusargs...]
# (Verilator 5.040; point VERILATOR at it if it is not the one on PATH.
# VL_JOBS: build parallelism (default 4). Python: PYTHON, else
# sim/work/bupchip/venv's, which needs numpy.)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
AV="$ROOT/src/fpga/core/atarivox"
WORK="${WORK:-$HERE/work}"
# tools/atarivox needs numpy (sjsynth.py). Use PYTHON, else the repo's venv
# (docs/ENVIRONMENT.md 4), else python3.
VENV="${VENV:-$ROOT/sim/work/bupchip/venv}"
if [ -z "$PYTHON" ]; then
	PYTHON=python3
	[ -x "$VENV/bin/python" ] && PYTHON="$VENV/bin/python"
fi
"$PYTHON" -c 'import numpy' 2>/dev/null || {
	if [ -x "$VENV/bin/python" ]; then
		echo "run.sh: $PYTHON has no numpy; install it: $VENV/bin/pip install numpy (docs/ENVIRONMENT.md 4)" >&2
	else
		# a fresh worktree has no sim/work, so no venv
		echo "run.sh: $PYTHON has no numpy, and there is no venv at $VENV. Either set PYTHON (or VENV) to another checkout's venv, e.g. PYTHON=<main checkout>/sim/work/bupchip/venv/bin/python, or create the venv as in docs/ENVIRONMENT.md's quick start and then run $VENV/bin/pip install numpy" >&2
	fi
	exit 2; }
mkdir -p "$WORK"
"$PYTHON" "$ROOT/tools/atarivox/sjhw.py" --build "$AV"
mkdir -p "$WORK/rtl"
cp "$AV/vox_irom.hex" "$AV/vox_drom.hex" "$WORK/rtl/"
if [ ! -x "$WORK/obj/vtb" ] || [ -n "$(find "$AV" "$HERE/tb_avox.sv" -newer "$WORK/obj/vtb" -name '*.sv')" ]; then
	"${VERILATOR:-verilator}" --binary --timing -j "${VL_JOBS:-4}" -O2 -Wno-fatal -Wno-lint -Wno-style \
		--top-module tb_avox -Mdir "$WORK/obj" -o vtb \
		"$ROOT/src/fpga/mister/rtl/cache_ram.v" "$AV/avox_rx.sv" "$AV/avox_engine.sv" "$AV/atarivox.sv" \
		"$HERE/tb_avox.sv" > "$WORK/build.log" 2>&1 || { grep -m20 "%Error" "$WORK/build.log"; exit 1; }
fi
BYTES="$(realpath "$1")"; shift
(cd "$WORK" && ./obj/vtb +bytes="$BYTES" "$@" > run.log)
"$PYTHON" "$ROOT/tools/atarivox/vox_check.py" "$WORK/avox.log" "$WORK/avox.wav"
