#!/bin/bash
# Every step 4 check of the Pocket BupChip wrapper (docs/BUPCHIP_CORE.md,
# implementation step 4), in one run:
#   1. the asset cache's load streams in all eight configurations
#      (run_cache.sh);
#   2. game-free: a synthetic ARSC block (../verif/make_synth_arsc.py, its
#      cartridge type set to Souper) boots and plays song 0 for 2 s with PCM
#      identical to the Python model's (../model/armemu.py), with a 48 kHz
#      tick forced into the clock after the first push into the empty FIFO
#      (+forcetick);
#   3. game-free: the same with an odd-length ARSC block and a firmware file
#      of 7,827 bytes (both tails); the image as made (cartridge type 0, not a
#      Souper cartridge), no firmware, and a 4-byte firmware file: each of
#      these three must leave the BupChip held and silent;
#   4. with GAME.a78: SONGS (default "13 14 9 30") for SECS seconds (default
#      4) after a full download at 174.6 ns per byte, PCM identical to
#      MiSTer's ($REFDIR/song<N>.pcm) both as pushed and as returned to
#      clk_sys, with no underflow or overflow and a lowest FIFO level of at
#      least 600; song 13 also with the loader at 174.6-250 ns per byte, the
#      cache without pre-emption (for the stall comparison), the throttle at
#      13/16, after a cartridge reload, after a PAL retune and across a pause;
#      and the game's cartridge without its ARSC block (held and silent).
#   ./check_s4.sh [GAME.a78]
# Up to JOBS runs at once (default 2). WORK defaults to sim/work/bupchip/s4.
# Without the firmware (src/fpga/mister/rtl/bupchip.hex) only step 1 runs.
# Exits 0 when everything passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s4}"
HEX="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)/bupchip.hex"
mkdir -p "$WORK/synth"
WORK="$(cd "$WORK" && pwd)"
export WORK
REFDIR="${REFDIR:-$WORK/../ref}"
GAME="${1:+$(realpath "$1")}"
JOBS="${JOBS:-2}"
if [ ! -f "$HEX" ] && [ -n "$GAME" ]; then
	echo "check_s4.sh: the game checks need the firmware, $HEX (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2
	exit 2
fi
RESULTS=()
step() {
	local name="$1"; shift
	echo "=== $name"
	if "$@"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); fi
}

step "asset cache load streams (run_cache.sh)" "$HERE/run_cache.sh"

if [ -f "$HEX" ]; then
	"$HERE/build_s4.sh" > /dev/null
	S="$WORK/synth"
	python3 "$HERE/../verif/make_synth_arsc.py" "$S/synth.a78" > /dev/null
	python3 - "$S/synth.a78" "$S/synth_souper.a78" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
d[53] |= 0x10                       # cartridge type bit 12: the Souper mapper
open(sys.argv[2], "wb").write(d)
EOF
	[ -f "$S/song0_model.pcm" ] && [ "$S/song0_model.pcm" -nt "$S/synth.a78" ] || \
		(cd "$HERE/../model" && python3 armemu.py "$S/synth_souper.a78" --song 0 --secs 1 --pcm "$S/song0_model.pcm" > "$S/armemu.log")
	head -c 4 /dev/urandom > "$S/short4.bin"
	python3 "$HERE/../../../tools/hex2bin.py" "$HEX" > "$S/fw_odd.bin"
	printf '\xa5\x5a\x3c' >> "$S/fw_odd.bin"
	cp "$S/synth_souper.a78" "$S/synth_odd.a78"
	printf '\x5a' >> "$S/synth_odd.a78"
	step "synthetic ARSC: boots and plays song 0, PCM identical to the model" \
		env NAME=synth_song0 REF="$S/song0_model.pcm" "$HERE/run_s4.sh" "$S/synth_souper.a78" 0 2 +forcetick
	step "synthetic ARSC, odd-length block and a 7,827-byte firmware file: tails written, PCM identical" \
		env NAME=synth_odd FW="$S/fw_odd.bin" REF="$S/song0_model.pcm" "$HERE/run_s4.sh" "$S/synth_odd.a78" 0 2
	step "not a Souper cartridge: held and silent" \
		env NAME=synth_notsouper "$HERE/run_s4.sh" "$S/synth.a78" 0 1 +silent=20
	step "no firmware: held and silent" \
		env NAME=synth_nofw FW=none "$HERE/run_s4.sh" "$S/synth_souper.a78" 0 1 +silent=20
	step "a 4-byte firmware file: held and silent" \
		env NAME=synth_short FW="$S/short4.bin" "$HERE/run_s4.sh" "$S/synth_souper.a78" 0 1 +silent=20
fi

if [ -n "$GAME" ]; then
	SECS="${SECS:-4}"
	RUNS=()
	for s in ${SONGS:-13 14 9 30}; do RUNS+=("song $s:NAME=song$s:$s:"); done
	RUNS+=("song 13, loader 174.6-250 ns per byte:NAME=song13_jit:13:+bytejit=75.4 +seed=3")
	RUNS+=("song 13, no pre-emption:NAME=song13_nopre PREEMPT=0:13:")
	RUNS+=("song 13, throttle 13/16:NAME=song13_thr13 THROTTLE=13:13:")
	RUNS+=("song 13 after a cartridge reload 0.5 s in:NAME=song13_reload:13:+reload=500")
	RUNS+=("song 13 after a PAL retune 0.5 s in:NAME=song13_retune:13:+retune=500")
	RUNS+=("song 13 across a 20 ms pause:NAME=song13_pause:13:+pause=300 +pauselen=20")
	python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(d[:128 + int.from_bytes(d[49:53], "big")])' \
		"$GAME" "$WORK/noarsc.a78"
	RUNS+=("the cartridge without its ARSC block, held and silent:NAME=noarsc GAMEFILE=$WORK/noarsc.a78:13:+silent=20")
	PIDS=()
	for r in "${RUNS[@]}"; do
		IFS=: read -r name envs song args <<< "$r"
		while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 5; done
		# shellcheck disable=SC2086
		g="$GAME"
		case "$envs" in *GAMEFILE=*) g="${envs##*GAMEFILE=}"; g="${g%% *}" ;; esac
		(env $envs REF="$REFDIR/song$song.pcm" "$HERE/run_s4.sh" "$g" "$song" "$SECS" $args > /dev/null 2>&1) &
		PIDS+=("$!:$name:${envs%% *}")
	done
	for p in "${PIDS[@]}"; do
		IFS=: read -r pid name nm <<< "$p"
		if wait "$pid"; then RESULTS+=("PASS  $name"); else RESULTS+=("FAIL  $name"); fi
		log="$WORK/${nm#NAME=}.log"
		echo "=== $name ($log)"
		grep -E "^(booted|reload|retune|pause|resume|held|busy|work|audio|fifo|cache|capture|crossing|m10k|PCM|lowest)" "$log" || true
	done
fi

echo
printf '%s\n' "${RESULTS[@]}"
! printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL'
