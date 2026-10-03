#!/bin/bash
# Mixer harness (kernel/harness.S): CoreTone's own voice mixer on 16
# fabricated voices, 24 batches of 200 frames, no game data. Builds the image
# (make_kernel.py), runs it on the reference RTL (tb_ref_trace.sv), checks
# the end marker and that all 4,800 frames are nonzero, then runs it in
# lockstep (run_lockstep.sh; DUT=ref unless set) unless --no-lockstep.
#   ./run_kernel.sh [--no-lockstep]
# Work files go to $WORK/kernel; exits 0 when every check passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)/bupchip.hex"
[ -f "$FW" ] || { echo "run_kernel.sh: no firmware at $FW (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2; exit 2; }
WORK="${WORK:-$HERE/../../work/bupchip/verif}"
mkdir -p "$WORK/kernel"
WORK="$(cd "$WORK" && pwd)"
export WORK
K="$WORK/kernel"
arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -Wl,-Ttext=0x2000 -Wl,-e,_start \
	-Wl,--no-warn-rwx-segments -o "$K/harness.elf" "$HERE/kernel/harness.S"
arm-none-eabi-objcopy -O binary -j .text "$K/harness.elf" "$K/harness.bin"
python3 "$HERE/make_kernel.py" "$K/harness.bin" "$K/kernel.hex" "$K/kernel.a78"
BIN="$("$HERE/build.sh" ref_trace tb_ref_trace)"
"$BIN" +rom="$K/kernel.a78" +romhex="$K/kernel.hex" +maxcyc=20000000 | grep -v "^- " | tee "$K/reference.log"
res="$(grep "^result:" "$K/reference.log")"
ok=1
case "$res" in
	*"fault=aa "*"pushes=4800 nonzero=4800 aborts=0 exceptions=0 spin=0"*) echo "kernel on the reference: PASS" ;;
	*) echo "kernel on the reference: FAIL (want fault=aa, 4800 nonzero pushes, no aborts)"; ok=0 ;;
esac
if [ "$1" != "--no-lockstep" ]; then
	LOG="$K/lockstep.log" "$HERE/run_lockstep.sh" "$K/kernel.a78" +romhex="$K/kernel.hex" +maxret=10000000 || ok=0
fi
[ "$ok" = 1 ]
