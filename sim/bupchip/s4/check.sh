#!/bin/bash
# Every check of step 4 of docs/BUPCHIP_CORE.md (the Pocket wrapper, memories,
# asset path and PSRAM around ARIA S1, in simulation), in one run:
#   1. the PSRAM layer (run_psram_ctl.sh): psram.sv is agg23's file
#      unmodified; the model's self-test; psram.sv with CLOCK_SPEED =
#      28.636364 against the model at 28.636, 21.477 and 21.281 MHz, 5 clocks
#      per access, data and timing clean; stress, must-fail and mutation runs;
#   2. the asset cache (run_cache.sh), 8 configurations x 3 seeds: the
#      directed scenarios (the boot's cold-line byte reads, word-load misses,
#      a hit on the line under fill, a demand miss during a prefetch and
#      during a demand fill, holds during a fill, the tag sweep with new
#      PSRAM contents behind every valid line) and 200,000 random loads, then
#      11 mutations that must fail;
#   3. the stress benches (stress/README.md), game-free and firmware-free:
#      run_cstress.sh (the cache on every load pair, holds at every clock of
#      a fill with new contents behind them, PSRAM latencies 1-20, M10K
#      models that poison a mixed-port read-during-write, 10 mutations),
#      run_capstress.sh (random downloads back to back, the firmware slot
#      straight after a cartridge, a firmware byte in the clock its download
#      starts, clk_arm synchronous and asynchronous), run_tick.sh (the 48 kHz
#      tick's crossing), run_bounds.sh (the asset window's bounds through the
#      whole wrapper), run_pophead.sh (pushes into the empty PCM FIFO at every
#      tick phase, a forced tick on that clock, a FAULT write muting the
#      output, and a wrapper without tick_hold that must fail), run_xing.sh
#      (the command, frame, tick and pause crossings, synchronous and
#      asynchronous clk_arm, and three mutants that must fail);
#   4. with the firmware, game-free, on a synthetic ARSC block
#      (../verif/make_synth_arsc.py, its cartridge type set to Souper) and the
#      firmware slot: song 0 for 2 s with PCM identical to the Python model's
#      (../model/armemu.py), and every write value through the watermark
#      remap; the same with an odd-length block and a 7,827-byte firmware
#      file; three reloads (the Souper image again, the image without the
#      Souper bit, held and silent, then the Souper image), the first two
#      holds during a cache fill, one with psram.sv mid-access and one with
#      the halfword arriving, then song 0 identical again; the image without
#      the Souper bit, no firmware and a 4-byte firmware file, each held and
#      silent; the download and boot with clk_arm at 1.5 x clk_sys in PAL
#      (21.281 MHz); stress/run_reload.sh (reloads of blocks with other
#      contents, PCM against the model's);
#   5. with GAME.a78: SONGS (default "13 14 9 30") for SECS seconds (default
#      4) after a full download at 174.6 ns per byte, PCM identical to
#      MiSTer's ($REFDIR/song<N>.pcm) as pushed and as returned to clk_sys,
#      no underflow or overflow, lowest FIFO level at least 600; song 13 also
#      with the loader at 174.6-250 ns per byte, without pre-emption (the
#      stall comparison), with the throttle at 13/16, after three reloads
#      (the game; the game without its ARSC block, held and silent; the game)
#      with the holds during cache fills (one mid-access, one with the
#      halfword arriving), after a PAL retune with the hold mid-access during
#      a cache fill, and across a 20 ms pause; song 14 with clk_arm at 21.281
#      MHz (1.5 x clk_sys, PAL); the game without its ARSC block, held and
#      silent.
#   ./check.sh [GAME.a78]
# Up to JOBS runs at once (default 3), niced. WORK defaults to
# sim/work/bupchip/s4 (the stress benches in $WORK/stress); game data and
# everything made from it stay there. REFDIR (default sim/work/bupchip/ref)
# must hold song<N>.pcm for 13, 14 and every song in SONGS, or check.sh
# stops before starting. Without the firmware (src/fpga/mister/rtl/
# bupchip.hex) only steps 1-3 run, and a GAME argument is an error. Needs
# Verilator, iverilog, python3 and arm-none-eabi-gcc. About 47 minutes with
# the game and JOBS=3 (27 jobs), 27 without it (15 jobs, of which
# stress/run_reload.sh alone takes 10). Exits 0 when everything passes.
#
# bup_cpu.sv is not part of step 4; if it changes, run ../s1/check.sh too.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/s4}"
HEX="$(cd "$HERE/../../../src/fpga/mister/rtl" && pwd)/bupchip.hex"
mkdir -p "$WORK/synth" "$WORK/logs"
WORK="$(cd "$WORK" && pwd)"
export WORK
REFDIR="${REFDIR:-$HERE/../../work/bupchip/ref}"
GAME=
if [ -n "$1" ]; then
	[ -f "$1" ] || { echo "check.sh: no $1" >&2; exit 2; }
	GAME="$(realpath "$1")"
fi
JOBS="${JOBS:-3}"
SECS="${SECS:-4}"
SONGS="${SONGS:-13 14 9 30}"
if [ ! -f "$HEX" ] && [ -n "$GAME" ]; then
	echo "check.sh: the game checks need the firmware, $HEX (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2
	exit 2
fi
[ -z "$GAME" ] || [ -f "$GAME" ] || { echo "check.sh: no $GAME" >&2; exit 2; }
if [ -n "$GAME" ]; then
	# every reference a game job compares against, before anything starts
	for s in 13 14 $SONGS; do
		[ -f "$REFDIR/song$s.pcm" ] || { echo "check.sh: no reference PCM $REFDIR/song$s.pcm (REFDIR)" >&2; exit 2; }
	done
fi
for t in iverilog python3 arm-none-eabi-gcc arm-none-eabi-objcopy; do
	command -v "$t" > /dev/null || { echo "check.sh: needs $t" >&2; exit 2; }
done
T0=$SECONDS

# The retune job's hold must land while psram.sv is mid-access: 2 clk_arm
# after the trigger at 28.64 MHz, 3 at 38.18 MHz (ARM38=1, where a read takes
# a clock more with PSRAM_CS=50.0).
HOLD_MID=2
[ "${ARM38:-0}" = 0 ] || HOLD_MID=3

# ---- the job pool -------------------------------------------------------------------------
NAMES=(); PIDS=(); LOGS=()
job() {         # job NAME LOG command...
	local name="$1" log="$2"
	shift 2
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 2; done
	echo "start  $name"
	# Each job writes its own exit code: on runs of several hours, wait can
	# lose a finished job's status once its PID has been reused.
	rm -f "$log.rc"
	(rc=0; "$@" || rc=$?; echo "$rc" > "$log.rc") > "$log" 2>&1 &
	NAMES+=("$name"); PIDS+=("$!"); LOGS+=("$log")
}
S4() {          # S4 NAME SONG SECONDS GAME [env...] -- [plusargs...]
	local name="$1" song="$2" secs="$3" game="$4"
	shift 4
	local envs=()
	while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
	[ "$#" -gt 0 ] && shift
	env NAME="$name" "${envs[@]}" "$HERE/run_s4.sh" "$game" "$song" "$secs" "$@"
}

# ---- 1, 2 ---------------------------------------------------------------------------------
job "PSRAM layer (run_psram_ctl.sh)" "$WORK/logs/psram_ctl.log" env WORK="$WORK/psram" "$HERE/run_psram_ctl.sh"
job "asset cache: directed scenarios, random streams, mutations (run_cache.sh)" "$WORK/logs/cache.log" "$HERE/run_cache.sh"

# ---- 3 --------------------------------------------------------------------------------------
# Build every tb_s4 configuration once, before runs share them (the stress
# benches' copy in $WORK/stress/s4 too).
"$HERE/build_s4.sh" > /dev/null
WORK="$WORK/stress/s4" "$HERE/build_s4.sh" > /dev/null
[ -z "$GAME" ] || { PREEMPT=0 "$HERE/build_s4.sh" > /dev/null; THROTTLE=13 "$HERE/build_s4.sh" > /dev/null; }
ST="$HERE/stress"
job "stress: the asset cache, every load pair, holds with new contents, latencies 1-20, poisoned M10Ks (stress/run_cstress.sh)" \
	"$WORK/logs/stress_cstress.log" env WORK="$WORK/stress" "$ST/run_cstress.sh"
job "stress: random downloads, firmware after a cartridge, byte 0 at the rise (stress/run_capstress.sh)" \
	"$WORK/logs/stress_capstress.log" env WORK="$WORK/stress" "$ST/run_capstress.sh"
job "stress: the 48 kHz tick's crossing (stress/run_tick.sh)" "$WORK/logs/stress_tick.log" env WORK="$WORK/stress" "$ST/run_tick.sh"
job "stress: the asset window's bounds through the wrapper (stress/run_bounds.sh)" \
	"$WORK/logs/stress_bounds.log" env WORK="$WORK/stress" "$ST/run_bounds.sh"
job "stress: pushes into the empty PCM FIFO, forced tick, FAULT mute, no-tick_hold mutant (stress/run_pophead.sh)" \
	"$WORK/logs/stress_pophead.log" env WORK="$WORK/stress" "$ST/run_pophead.sh"
job "stress: command, frame, tick and pause crossings, three mutants (stress/run_xing.sh)" \
	"$WORK/logs/stress_xing.log" env WORK="$WORK/stress" "$ST/run_xing.sh"

# ---- 4 --------------------------------------------------------------------------------------
if [ -f "$HEX" ]; then
	S="$WORK/synth"
	python3 "$HERE/../verif/make_synth_arsc.py" "$S/synth.a78" > /dev/null
	python3 - "$S/synth.a78" "$S/synth_souper.a78" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
d[53] |= 0x10                       # cartridge type bit 12: the Souper mapper
open(sys.argv[2], "wb").write(d)
EOF
	[ -f "$S/song0_model.pcm" ] && [ "$S/song0_model.pcm" -nt "$S/synth_souper.a78" ] || \
		(cd "$HERE/../model" && python3 armemu.py "$S/synth_souper.a78" --song 0 --secs 1 --pcm "$S/song0_model.pcm" > "$S/armemu.log")
	head -c 4 /dev/urandom > "$S/short4.bin"
	python3 "$HERE/../../../tools/hex2bin.py" "$HEX" > "$S/fw_odd.bin"
	printf '\xa5\x5a\x3c' >> "$S/fw_odd.bin"
	cp "$S/synth_souper.a78" "$S/synth_odd.a78"
	printf '\x5a' >> "$S/synth_odd.a78"
	R0="$S/song0_model.pcm"
	job "synthetic ARSC: song 0 identical to the model, watermark remap sweep" "$WORK/synth_song0.out" \
		S4 synth_song0 0 2 "$S/synth_souper.a78" REF="$R0" WMSWEEP=1 -- +wmsweep
	job "synthetic ARSC: odd-length block, 7,827-byte firmware file" "$WORK/synth_odd.out" \
		S4 synth_odd 0 2 "$S/synth_odd.a78" FW="$S/fw_odd.bin" REF="$R0"
	job "synthetic ARSC: three reloads (Souper; not Souper: held; Souper), holds during fills, song 0 identical" "$WORK/synth_reloads.out" \
		S4 synth_reloads 0 2 "$S/synth_souper.a78" REF="$R0" HOLDFILL=2 HOLDLAND=1 HOLDMID=1 -- \
		+reload=150 +reloads=3 +rom2="$S/synth_souper.a78" +rom3="$S/synth.a78" +rom4="$S/synth_souper.a78" \
		+holdfill +holdstep=2
	job "synthetic ARSC: download and boot at 21.281 MHz (1.5 x clk_sys, PAL)" "$WORK/synth_arm15pal.out" \
		S4 synth_arm15pal 0 0 "$S/synth_souper.a78" REF=none -- +arm15 +pal
	job "not a Souper cartridge: held and silent" "$WORK/synth_notsouper.out" \
		S4 synth_notsouper 0 1 "$S/synth.a78" -- +silent=20
	job "no firmware: held and silent" "$WORK/synth_nofw.out" \
		S4 synth_nofw 0 1 "$S/synth_souper.a78" FW=none -- +silent=20
	job "a 4-byte firmware file: held and silent" "$WORK/synth_short.out" \
		S4 synth_short 0 1 "$S/synth_souper.a78" FW="$S/short4.bin" -- +silent=20
	job "stress: reloads of blocks with other contents, PCM against the model (stress/run_reload.sh)" \
		"$WORK/logs/stress_reload.log" env WORK="$WORK/stress" "$ST/run_reload.sh"
fi

# ---- 5 --------------------------------------------------------------------------------------
if [ -n "$GAME" ]; then
	python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(d[:128 + int.from_bytes(d[49:53], "big")])' \
		"$GAME" "$WORK/noarsc.a78"
	R13="$REFDIR/song13.pcm"
	for s in $SONGS; do
		job "song $s" "$WORK/song$s.out" S4 "song$s" "$s" "$SECS" "$GAME" REF="$REFDIR/song$s.pcm"
	done
	job "song 13, three reloads (game; no ARSC block: held; game), holds during fills" "$WORK/song13_reloads.out" \
		S4 song13_reloads 13 "$SECS" "$GAME" REF="$R13" HOLDFILL=2 HOLDLAND=1 HOLDMID=1 -- \
		+reload=300 +reloads=3 +rom3="$WORK/noarsc.a78" +holdfill +holdstep=2
	job "song 13 after a PAL retune, hold during a fill" "$WORK/song13_retune.out" \
		S4 song13_retune 13 "$SECS" "$GAME" REF="$R13" HOLDFILL=1 HOLDMID=1 -- +retune=500 +holdfill +holddelay="$HOLD_MID"
	job "song 14 at 21.281 MHz (1.5 x clk_sys, PAL)" "$WORK/song14_arm15pal.out" \
		S4 song14_arm15pal 14 "$SECS" "$GAME" REF="$REFDIR/song14.pcm" -- +arm15 +pal
	job "song 13, loader 174.6-250 ns per byte" "$WORK/song13_jit.out" \
		S4 song13_jit 13 "$SECS" "$GAME" REF="$R13" -- +bytejit=75.4 +seed=3
	job "song 13, no pre-emption" "$WORK/song13_nopre.out" S4 song13_nopre 13 "$SECS" "$GAME" REF="$R13" PREEMPT=0
	job "song 13, throttle 13/16" "$WORK/song13_thr13.out" S4 song13_thr13 13 "$SECS" "$GAME" REF="$R13" THROTTLE=13
	job "song 13 across a 20 ms pause" "$WORK/song13_pause.out" \
		S4 song13_pause 13 "$SECS" "$GAME" REF="$R13" -- +pause=300 +pauselen=20
	job "the game without its ARSC block: held and silent" "$WORK/noarsc.out" \
		S4 noarsc 13 1 "$WORK/noarsc.a78" -- +silent=20
fi

# ---- results --------------------------------------------------------------------------------
RESULTS=()
for i in "${!PIDS[@]}"; do
	wait "${PIDS[$i]}" 2> /dev/null || true
	if [ "$(cat "${LOGS[$i]}.rc" 2> /dev/null)" = 0 ]; then r=PASS; else r=FAIL; fi
	RESULTS+=("$r  ${NAMES[$i]}")
	echo "=== $r  ${NAMES[$i]} (${LOGS[$i]})"
	grep -E "^(PASS|FAIL|SKIP|firmware slot|cartridge:|booted|reload|retune|hold at|held|pause|resume|busy|work|audio|fifo|cache|capture|crossing|m10k|holds|pop|watermark|mute|wmsweep|PCM|lowest|directed|G tag|  [0-9]+ (halfwords|tags|word loads)|run_[a-z]*\.sh:|stress)" \
		"${LOGS[$i]}" || true
done
echo
printf '%s\n' "${RESULTS[@]}"
n="${#RESULTS[@]}"
f="$(printf '%s\n' "${RESULTS[@]}" | grep -c '^FAIL' || true)"
echo "$((n - f)) of $n passed in $(( (SECONDS - T0) / 60 )) min $(( (SECONDS - T0) % 60 )) s"
[ "$f" = 0 ]
