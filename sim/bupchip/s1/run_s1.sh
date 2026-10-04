#!/bin/bash
# Play one song on the S1 core (tb_s1.sv: bup_cpu at 28.636 MHz with its ROM,
# RAM, the unmodified peripheral at 8 / 1,024 with the watermark remap, and
# the ARSC block as a behavioural asset memory), then compare its PCM with
# MiSTer's (run_bupchip.sh) from the song's first frame (pcm_check.py) and
# report busy, CPI and MIPS.
#   ./run_s1.sh GAME.a78 [SONG] [SECONDS] [extra +plusargs...]
# GAME.a78 must carry its ARSC block (make_arsc.py). The reference is
# $REF (default $WORK/../ref/song<SONG>.pcm) when it exists. Writes
# $WORK/song<SONG>.pcm, .batches and .log (WORK defaults to
# sim/work/bupchip/s1). PCM_DEPTH=4096 builds the stock FIFO depth instead.
# Exits 0 when the core did not halt, nothing underran and, with a
# reference, every frame matched. About 3 minutes per second of audio.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)/bupchip.hex"
[ -f "$FW" ] || { echo "run_s1.sh: no firmware at $FW (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2; exit 2; }
WORK="${WORK:-$HERE/../../work/bupchip/s1}"
DEPTH="${PCM_DEPTH:-1024}"
GAME="$(realpath "${1:?usage: run_s1.sh GAME.a78 [SONG] [SECONDS] [+plusargs...]}")"
SONG="${2:-13}"
SECS="${3:-4}"
shift $(( $# < 3 ? $# : 3 ))
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
BIN="$("$HERE/build_s1.sh" "$DEPTH")"

REF="${REF:-$WORK/../ref/song$SONG.pcm}"
OUT="$WORK/song$SONG"
"$BIN" +rom="$GAME" +song="$SONG" +secs="$SECS" +out="$OUT.pcm" +batches="$OUT.batches" "$@" \
	| grep -v "^- " | tee "$OUT.log"
ARGS=("$OUT.pcm")
[ -f "$REF" ] && ARGS+=("$REF") || echo "no reference at $REF: PCM not compared"
START="$(sed -n 's/^command .* with \([0-9]*\) frames pushed$/\1/p' "$OUT.log")"
[ -n "$START" ] && [ "$START" -ge 0 ] && ARGS+=(--song-start "$START")
python3 "$HERE/pcm_check.py" "${ARGS[@]}" --batches "$OUT.batches" | tee -a "$OUT.log"
grep -q "^result: .* under=0 over=0 .* fault=00 halted=0 clear=1" "$OUT.log"
