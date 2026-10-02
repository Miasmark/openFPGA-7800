#!/bin/bash
# Measure the BupChip firmware's CPU load on one song (tested with Verilator
# 5.040; point VERILATOR at the binary if it is not the one on PATH).
#   ./run_bupchip.sh GAME.a78 [SONG] [SECONDS] [extra +plusargs...]
# GAME.a78 must carry its ARSC block (make_arsc.py). Writes the song as
# $WORK/song<N>.wav. About 90 s of wall time per second of audio.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../../src/fpga/mister/rtl"
WORK="${WORK:-$HERE/../work/bupchip}"
VERILATOR="${VERILATOR:-verilator}"
GAME="$(realpath "${1:?usage: run_bupchip.sh GAME.a78 [SONG] [SECONDS]}")"
SONG="${2:-0}"
SECS="${3:-4}"
shift $(( $# < 3 ? $# : 3 ))
mkdir -p "$WORK"

if [ ! -x "$WORK/obj_dir/tb_bupchip" ] || [ -n "$(find "$HERE/tb_bupchip.sv" "$RTL"/bupchip_* "$RTL/arm7tdmi" -newer "$WORK/obj_dir/tb_bupchip" 2>/dev/null)" ]; then
	(cd "$WORK" && "$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module tb_bupchip -DROMHEX="\"$RTL/bupchip.hex\"" \
		"$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$RTL/arm7tdmi/arm7tdmi_core.sv" "$RTL/arm_host.sv" \
		"$RTL/cache_ram.v" "$RTL/bram.v" "$RTL/bupchip_memory.sv" "$RTL/bupchip_peripheral.sv" \
		"$RTL/bupchip_asset_ddr.sv" "$RTL/bupchip_subsystem.sv" "$HERE/tb_bupchip.sv" \
		-o tb_bupchip > build.log 2>&1) || { grep -E "^%Error" "$WORK/build.log"; exit 1; }
fi

cd "$WORK"
./obj_dir/tb_bupchip +rom="$GAME" +song="$SONG" +secs="$SECS" +out="song$SONG.pcm" "$@" | grep -v "^- "
python3 - "song$SONG.pcm" "song$SONG.wav" <<'EOF'
import sys, wave
d = open(sys.argv[1], "rb").read()
with wave.open(sys.argv[2], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000); w.writeframes(d[:len(d) // 4 * 4])
print("wrote", sys.argv[2])
EOF
