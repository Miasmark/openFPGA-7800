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
#   INPUTS=tb_daria  +inputs_tbdaria: the TIA's paddle inputs (INPT0-3) held
#                as tb_daria presents them (4'b1010), for a comparison with
#                R1's tb_daria runs (bench parity, plan P13; sim/step7_gates.sh's
#                frames gate sets it); INPUTS=pocket (the default) leaves the
#                wrapper's own mapping (0 on INPT1 and INPT3 for a 2600 image
#                with a joystick)
#   DARIA, ARM_DIV, VERILATOR, VL_JOBS, RTL_TREE: passed to run_sim.sh's build
#                (ARM_DIV=18 or 19 also adds +arm_div to the run; tb_load's
#                default is 18, pll_core.v's divider)
#   FRAMES_DEBUG=1  passed to run_sim.sh's build too: BUP_DEBUG, and the
#                DARIA status overlay's checks (tb_frames.sv's header).
#                run_sim.sh records the build's mode in WORK/obj_frames.mode
#                with the binary's md5; a binary whose recorded mode is not
#                the one asked for (FRAMES_DEBUG, default 0), or has none, is
#                rebuilt, and with NOBUILD=1 the run is refused. run.log
#                names the mode, and with FRAMES_DEBUG=1 the run passes only
#                with "OVERLAY result: PASS" in it too
# Writes WORK/runs/NAME/{fp,calls,slack,zero,frames}.csv and run.log; run.log
# starts with the tree's HEAD and status, the Verilator and the binary's md5
# (plan P23), then the bench's output, its exit status and the wall time per
# emulated second. Exit status: the bench's (0 when its FRAMES result line
# says PASS, and with FRAMES_DEBUG=1 its OVERLAY result line too; 1 when
# run.log has a "$readmem file not found" line for one of the palette and ROM
# tables below; 2 when the binary's mode is not the one asked for, or before
# the run when WORK/rtl lacks one of those tables, as when WORK shares another
# directory's obj_frames without its rtl/). The warning for rtl/mem0.hex does
# not count: a BUILD_TOP build never writes that file, and the bench takes its
# image from +image. Every file there derives from the game image: keep it in
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
FDBG="${FRAMES_DEBUG:-0}"
[ "$FDBG" = 1 ] || FDBG=0
# the binary's mode as run_sim.sh recorded it, if the record is this binary's
mode() { [ -x "$BIN" ] && sed -n "s/^FRAMES_DEBUG=\([01]\) md5 $(md5sum < "$BIN" | cut -d' ' -f1)\$/\1/p" "$WORK/obj_frames.mode" 2>/dev/null; }
if [ ! -x "$BIN" ] || [ "$(mode)" != "$FDBG" ] || { [ "${NOBUILD:-0}" = 0 ] && [ -n "$(find "$TREE/src/fpga" "$HERE/tb_frames.sv" "$HERE/tb_load.sv" \
		"$HERE/run_sim.sh" "$HERE/sim_stubs.sv" "$HERE/bupchip/s4/psram_model.sv" -newer "$BIN" \
		\( -name '*.sv' -o -name '*.v' -o -name '*.sh' -o -name '*.qsf' -o -name '*.hex' \) 2>/dev/null | head -1)" ]; }; then
	if [ "${NOBUILD:-0}" != 0 ] && [ -x "$BIN" ]; then
		m="$(mode || true)"
		if [ -n "$m" ]; then m="a FRAMES_DEBUG=$m build"; else m="a build with no mode recorded for it"; fi
		echo "run_frames.sh: NOBUILD=1, but $BIN is $m, not FRAMES_DEBUG=$FDBG" >&2
		exit 2
	fi
	echo "building $BIN (FRAMES_DEBUG=$FDBG) ..." >&2
	WORK="$WORK" BUILD_TOP=tb_frames FRAMES_DEBUG="$FDBG" VL_JOBS="${VL_JOBS:-2}" nice -n 10 bash "$HERE/run_sim.sh" >&2
	[ "$(mode)" = "$FDBG" ] || { echo "run_frames.sh: the build did not record FRAMES_DEBUG=$FDBG (BUPCHIP=0 has no BUP_DEBUG)" >&2; exit 2; }
fi
# tb_load reads its palette and ROM tables from WORK/rtl, which run_sim.sh
# links. Without them Verilator only warns ("$readmem file not found") and the
# bench runs on zeroed tables: a black picture that shows up later as a video
# difference (2.2.4's campaign, a WORK that shared obj_frames without rtl/).
# rtl/mem0.hex is not one of them (above).
TABLES=(palettes/NWARM.hex palettes/NCOOL.hex palettes/NHOT.hex palettes/PWARM.hex palettes/PCOOL.hex
	palettes/PHOT.hex Minnie/minnie_wave.hex ooo.hex ar_stub.hex vox_irom.hex vox_drom.hex)
for f in "${TABLES[@]}"; do
	[ -f "$WORK/rtl/$f" ] && continue
	echo "run_frames.sh: $WORK/rtl/$f is missing (no rtl/ link, or a dangling one); tb_load reads its palette and ROM tables from WORK/rtl, so the run would be black. Build into this WORK (run_sim.sh links rtl/), or link WORK/rtl to the build's rtl/" >&2
	exit 2
done
NAME="${NAME:-$(basename "$IMG" .bin)}"
OUT="$WORK/runs/$NAME"
mkdir -p "$OUT"
ARGS=(+image="$IMG" +frames="${FRAMES:-1500}" +out="$OUT/")
[ -n "${ARM_DIV:-}" ] && ARGS+=(+arm_div="$ARM_DIV")
case "${INPUTS:-pocket}" in
	tb_daria) ARGS+=(+inputs_tbdaria) ;;
	pocket) ;;
	*) echo "run_frames.sh: INPUTS=$INPUTS: tb_daria or pocket" >&2; exit 2 ;;
esac
{
	echo "HEAD $(git -C "$HERE/.." rev-parse HEAD)"
	echo "status: [$(git -C "$HERE/.." status --porcelain | tr '\n' ';')]"
	[ "$TREE" = "$(cd "$HERE/.." && pwd)" ] || echo "RTL tree $TREE HEAD $(git -C "$TREE" rev-parse HEAD) status: [$(git -C "$TREE" status --porcelain | tr '\n' ';')]"
	echo "verilator $VERILATOR ($("$VERILATOR" --version))"
	echo "binary $BIN md5 $(md5sum < "$BIN" | cut -c1-32), FRAMES_DEBUG=$(mode)"
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
# any of those tables the bench could not load fails the run, whatever its
# verdict; rtl/mem0.hex's warning is expected and ignored
miss="$(grep -a 'readmem file not found' "$OUT/run.log" | grep -aF -f <(printf 'rtl/%s:\n' "${TABLES[@]}") | head -n 1 || true)"
if [ -n "$miss" ]; then
	echo "run_frames.sh: the bench could not load a table ($miss); the run does not count" | tee -a "$OUT/run.log" >&2
	exit 1
fi
grep -aq "^FRAMES result: PASS" "$OUT/run.log" && [ "$rc" = 0 ] || exit 1
# a FRAMES_DEBUG=1 run checks the overlay: a missing line fails
if [ "$FDBG" = 1 ] && ! grep -aq "^OVERLAY result: PASS" "$OUT/run.log"; then
	echo "run_frames.sh: FRAMES_DEBUG=1, and run.log has no 'OVERLAY result: PASS'" | tee -a "$OUT/run.log" >&2
	exit 1
fi
