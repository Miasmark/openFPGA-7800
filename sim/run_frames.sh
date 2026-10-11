#!/bin/bash
# Run tb_frames (sim/tb_frames.sv: the whole Pocket core on a 2600 image for
# a number of frames, with tb_daria's fingerprint, input script and call log;
# docs/daria_step7/plan.md 3.6 I4c, 7.4 R2) and keep its files in one run
# directory that sim/check/frame_gate.py compares with tb_daria's.
#   sim/run_frames.sh IMAGE.bin [+plusargs...]
# Environment:
#   WORK=DIR     run_sim.sh work directory with obj_frames/ (default
#                sim/work/step7/frames); built there with BUILD_TOP=tb_frames
#                when missing or when a source is newer, unless NOBUILD=1
#   NOBUILD=1    run the binary that is there, without checking its sources
#   NAME=NAME    the run directory, WORK/runs/NAME (default the image's name)
#   FRAMES=N     +frames (default 1500)
#   DARIA, ARM_DIV, VERILATOR, VL_JOBS, RTL_TREE: passed to run_sim.sh's build
#                (ARM_DIV=18 or 19 also adds +arm_div to the run; tb_load's
#                default is 19, pll_core.v's divider)
# Writes WORK/runs/NAME/{fp,calls,slack,zero,frames}.csv and run.log; run.log
# starts with the tree's HEAD and status, the Verilator and the binary's md5
# (plan P23), then the bench's output, its exit status and the wall time per
# emulated second. Exit status: the bench's (0 when its FRAMES result line
# says PASS). Every file there derives from the game image: keep it in
# sim/work.
# SPDX-License-Identifier: MIT
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="$(realpath "${1:?usage: run_frames.sh IMAGE.bin [+plusargs...]}")"
shift
export VERILATOR="${VERILATOR:-/opt/verilator-5.040/bin/verilator}"
WORK="${WORK:-$HERE/work/step7/frames}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
BIN="$WORK/obj_frames/vtb"
TREE="$(cd "${RTL_TREE:-$HERE/..}" && pwd)"
if [ ! -x "$BIN" ] || { [ "${NOBUILD:-0}" = 0 ] && [ -n "$(find "$TREE/src/fpga" "$HERE/tb_frames.sv" "$HERE/tb_load.sv" \
		"$HERE/run_sim.sh" "$HERE/sim_stubs.sv" "$HERE/bupchip/s4/psram_model.sv" -newer "$BIN" \
		\( -name '*.sv' -o -name '*.v' -o -name '*.sh' -o -name '*.qsf' -o -name '*.hex' \) 2>/dev/null | head -1)" ]; }; then
	echo "building $BIN ..." >&2
	WORK="$WORK" BUILD_TOP=tb_frames VL_JOBS="${VL_JOBS:-2}" nice -n 10 bash "$HERE/run_sim.sh" >&2
fi
NAME="${NAME:-$(basename "$IMG" .bin)}"
OUT="$WORK/runs/$NAME"
mkdir -p "$OUT"
ARGS=(+image="$IMG" +frames="${FRAMES:-1500}" +out="$OUT/")
[ -n "${ARM_DIV:-}" ] && ARGS+=(+arm_div="$ARM_DIV")
{
	echo "HEAD $(git -C "$HERE/.." rev-parse HEAD)"
	echo "status: [$(git -C "$HERE/.." status --porcelain | tr '\n' ';')]"
	[ "$TREE" = "$(cd "$HERE/.." && pwd)" ] || echo "RTL tree $TREE HEAD $(git -C "$TREE" rev-parse HEAD) status: [$(git -C "$TREE" status --porcelain | tr '\n' ';')]"
	echo "verilator $VERILATOR ($("$VERILATOR" --version))"
	echo "binary $BIN md5 $(md5sum < "$BIN" | cut -c1-32)"
	echo "args ${ARGS[*]} $*"
} > "$OUT/run.log"
start=$(date +%s.%N)
rc=0
# tb_load reads its tables from rtl/... in the working directory (run_sim.sh
# links WORK/rtl)
(cd "$WORK" && nice -n "${NICE:-10}" "$BIN" "${ARGS[@]}" "$@" < /dev/null) >> "$OUT/run.log" 2>&1 || rc=$?
end=$(date +%s.%N)
python3 - "$OUT/run.log" "$start" "$end" "$rc" <<'PY'
import re, sys
log, t0, t1, rc = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
t = open(log, errors="replace").read()
m = re.search(r"^FRAMES \d+ frames after .*?; ([0-9.]+) s emulated", t, re.M)
emu = float(m.group(1)) if m else 0.0
with open(log, "a") as f:
    f.write(f"exit {rc}\n")
    f.write(f"wall {t1 - t0:.1f} s" + (f", {(t1 - t0) / emu:.1f} s of wall time per emulated second ({emu:.3f} s emulated from time 0)" if emu else "") + "\n")
PY
tail -n 4 "$OUT/run.log"
grep -q "^FRAMES result: PASS" "$OUT/run.log" && [ "$rc" = 0 ]
