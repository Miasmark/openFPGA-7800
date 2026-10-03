#!/bin/bash
# One run of tb_s4.sv (step 4 of docs/BUPCHIP_CORE.md): the Pocket BupChip
# wrapper with its three clocks, the firmware loaded through the data slot
# (bupchip.bin, made from the user's bupchip.hex with tools/hex2bin.py), the
# cartridge downloaded at the loader's rate, the PSRAM behind psram.sv, and
# the song's command; then the PCM compared with MiSTer's (pcm_check.py) from
# the song's first frame, both as pushed by the firmware and as returned to
# clk_sys.
#   ./run_s4.sh GAME.a78 [SONG] [SECONDS] [extra +plusargs...]
# Environment:
#   NAME     output name in $WORK (default song<SONG>): NAME.log, NAME.pcm
#            (pushed), NAME.out.pcm (returned to clk_sys), NAME.batches
#   REF      reference PCM (default $WORK/../ref/song<SONG>.pcm, checked when
#            it exists); REF_START its song start (default 4,000, MiSTer's
#            prefill)
#   FW       firmware image (default $WORK/bupchip.bin, made from
#            src/fpga/mister/rtl/bupchip.hex); FW=none loads no firmware
#   MINLEV   lowest FIFO level allowed while playing (default 600)
#   PSRAM, PREEMPT, PREFETCH, PCM_DEPTH: see build_s4.sh
#   WORK     default sim/work/bupchip/s4
# Exits 0 when the CPU did not halt, nothing underflowed or overflowed, the
# FIFO stayed at or above MINLEV, every testbench check passed (ROM and PSRAM
# contents, capture messages, the frame crossing, the shadow counters, the
# M10K read-during-write rule) and, with a reference, every frame matched in
# both streams. Plusargs such as +silent=MS (no song) are passed through; see
# tb_s4.sv. About 1 minute per second of audio, plus 1 for the download.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HEX="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)/bupchip.hex"
TOOLS="$(cd "$HERE/../../../tools" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s4}"
GAME="$(realpath "${1:?usage: run_s4.sh GAME.a78 [SONG] [SECONDS] [+plusargs...]}")"
SONG="${2:-13}"
SECS="${3:-4}"
shift $(( $# < 3 ? $# : 3 ))
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
export WORK
BIN="$("$HERE/build_s4.sh")"

if [ -z "$FW" ]; then
	[ -f "$HEX" ] || { echo "run_s4.sh: no firmware at $HEX (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2; exit 2; }
	FW="$WORK/bupchip.bin"
	[ -f "$FW" ] && [ "$FW" -nt "$HEX" ] || python3 "$TOOLS/hex2bin.py" "$HEX" > "$FW"
fi
FWARG=()
[ "$FW" = none ] || FWARG=(+fw="$(realpath "$FW")")

NAME="${NAME:-song$SONG}"
OUT="$WORK/$NAME"
REF="${REF:-$WORK/../ref/song$SONG.pcm}"
MINLEV="${MINLEV:-600}"
nice -n "${NICE:-5}" "$BIN" "${FWARG[@]}" +rom="$GAME" +song="$SONG" +secs="$SECS" +out="$OUT" "$@" \
	| grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " | tee "$OUT.log"
RES="$(grep "^result: " "$OUT.log" || true)"
[ -n "$RES" ] || { echo "run_s4.sh: no result line" >&2; exit 1; }
ok=1
if grep -q "^result: silent=" <<< "$RES"; then
	grep -q "^result: silent=1 .* lost=0 cross=0$" <<< "$RES" || ok=0
	[ "$ok" = 1 ] && echo "PASS $NAME: held and silent" || echo "FAIL $NAME"
	[ "$ok" = 1 ]
	exit
fi
grep -Eq "^result: .* under=0 under_all=0 over=0 minlev=[0-9]+ fault=00 halted=0 clear=1 lost=0 rom=0 psram=0 cross=0 shadow=0 .* rdw=0 held=0 held_nz=0 pause_nz=0 pause_pops=0$" <<< "$RES" || ok=0
lev="$(sed -n 's/.* minlev=\([0-9]*\) .*/\1/p' <<< "$RES")"
[ "${lev:-0}" -ge "$MINLEV" ] || { echo "lowest FIFO level $lev is under $MINLEV"; ok=0; }
if [ -f "$REF" ]; then
	PS="$(sed -n 's/^song start: pushed \([0-9-]*\), output \([0-9-]*\)$/\1/p' "$OUT.log")"
	OS="$(sed -n 's/^song start: pushed \([0-9-]*\), output \([0-9-]*\)$/\2/p' "$OUT.log")"
	echo "pushed frames:" | tee -a "$OUT.log"
	python3 "$HERE/../s1/pcm_check.py" "$OUT.pcm" "$REF" --song-start "$PS" --ref-start "${REF_START:-4000}" \
		--batches "$OUT.batches" | tee -a "$OUT.log" || ok=0
	grep -q "^PCM IDENTICAL: all" "$OUT.log" || ok=0
	echo "frames returned to clk_sys:" | tee -a "$OUT.log"
	python3 "$HERE/../s1/pcm_check.py" "$OUT.out.pcm" "$REF" --song-start "$OS" --ref-start "${REF_START:-4000}" \
		| tee -a "$OUT.log" || ok=0
	[ "$(grep -c "^PCM IDENTICAL: all" "$OUT.log")" = 2 ] || ok=0
else
	echo "no reference at $REF: PCM not compared"
fi
[ "$ok" = 1 ] && echo "PASS $NAME" || echo "FAIL $NAME"
[ "$ok" = 1 ]
