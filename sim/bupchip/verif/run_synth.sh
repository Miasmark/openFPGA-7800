#!/bin/bash
# Game-free checks of the CoreTone firmware with synthetic ARSC blocks
# (make_synth_arsc.py):
#   1. the existing tb_bupchip (../run_bupchip.sh) boots the default block
#      and plays song 0 (16 looped voices) for SECS seconds (default 1): the
#      PCM must have nonzero frames, and no underrun or fault;
#   2. the fault paths on the reference RTL: no ARSC tag gives fault 2, a bad
#      CSMP tag fault 3;
#   3. Unicorn replays a reference trace of boot and song 0 (iss_fw_replay.py)
#      and must agree at every retire;
#   4. lockstep (run_lockstep.sh; DUT=ref unless set) through boot and every
#      command class, and over random-content blocks (RANDOM_SEEDS, default
#      "1 2 3 4"), which may abort as long as both cores agree.
#   ./run_synth.sh [--no-lockstep]
# Work files go to $WORK/synth; exits 0 when every check passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/../../work/bupchip/verif}"
mkdir -p "$WORK/synth"
WORK="$(cd "$WORK" && pwd)"
export WORK
S="$WORK/synth"
VENV="${VENV:-$HERE/../../work/bupchip/venv}"
PYTHON="${PYTHON:-$VENV/bin/python}"
LOCKSTEP=1
[ "$1" = "--no-lockstep" ] && LOCKSTEP=
ok=1
check() { if [ "$1" = 1 ]; then echo "PASS $2"; else echo "FAIL $2"; ok=0; fi; }

python3 "$HERE/make_synth_arsc.py" "$S/synth.a78"
python3 "$HERE/make_synth_arsc.py" "$S/badtag.a78" --break tag > /dev/null
python3 "$HERE/make_synth_arsc.py" "$S/badcsmp.a78" --break csmp > /dev/null

# 1. tb_bupchip: boot, song 0, PCM.
rm -f "$S/tb_bupchip/song0.pcm"
WORK="$S/tb_bupchip" "$HERE/../run_bupchip.sh" "$S/synth.a78" 0 "${SECS:-1}" > "$S/tb_bupchip.log" 2>&1 || true
grep -E "^(booted|song|busy|work|audio)" "$S/tb_bupchip.log" || true
nz="$(python3 - "$S/tb_bupchip/song0.pcm" <<'EOF'
import os, struct, sys
d = open(sys.argv[1], "rb").read() if os.path.exists(sys.argv[1]) else b""
f = struct.unpack("<%dI" % (len(d) // 4), d[:len(d) // 4 * 4])
print(sum(1 for x in f if x), len(f))
EOF
)"
echo "tb_bupchip PCM: ${nz% *} of ${nz#* } frames nonzero"
grep -q "fault 00, PCM enabled 1" "$S/tb_bupchip.log" && ! grep -q "fault [0-9a-f][1-9a-f]$" "$S/tb_bupchip.log" && \
	grep -q "^audio .* 0 underruns" "$S/tb_bupchip.log" && [ "${nz% *}" -gt 0 ] && r=1 || r=0
check $r "synthetic ARSC on tb_bupchip: boots, renders nonzero PCM, no underrun"

# 2. Fault paths.
BIN="$("$HERE/build.sh" ref_trace tb_ref_trace)"
for t in "badtag 02" "badcsmp 03"; do
	read -r name code <<< "$t"
	"$BIN" +rom="$S/$name.a78" +maxcyc=1000000 > "$S/$name.log" 2>&1 || true
	grep -q "^result: fault=$code " "$S/$name.log" && r=1 || r=0
	n="$(sed -n 's/^result: fault=[0-9a-f]* retired=\([0-9]*\).*/\1/p' "$S/$name.log")"
	check $r "$name.a78: fault $code after ${n:-?} instructions"
done

# 3. Unicorn against a reference trace: boot, then song 0 from clock 300,000.
"$BIN" +rom="$S/synth.a78" +song=0 +songcyc=300000 +maxcyc=1500000 +trace="$S/synth.trace" > "$S/trace.log" 2>&1 || true
if "$PYTHON" -c "import unicorn" 2>/dev/null; then
	"$PYTHON" "$HERE/iss_fw_replay.py" "$S/synth.a78" "$S/synth.trace" > "$S/replay.log" 2>&1 || true
	cat "$S/replay.log"
	grep -q "^MATCH" "$S/replay.log" && r=1 || r=0
	check $r "Unicorn replay of $(grep -c . "$S/synth.trace") reference instructions"
else
	check 0 "Unicorn replay: no unicorn in $PYTHON (run sim/bupchip/setup_dev.sh)"
fi
rm -f "$S/synth.trace"

# 4. Lockstep: every command class (play $80-$9F and $A0-$BF, $00-$3F, $40-$7F,
# $C0-$FF; songs with a bad tag, no channels, no entry), then random blocks.
if [ -n "$LOCKSTEP" ]; then
	CMDS="81@300000,82@1500000,83@2500000,84@2700000,80@2900000,c5@4000000,03@4300000,02@4500000"
	CMDS="$CMDS,40@4700000,a1@4900000,00@5500000,01@5700000,3f@5900000,ff@6100000,9f@6300000,80@6600000"
	LOG="$S/lockstep_cmds.log" "$HERE/run_lockstep.sh" "$S/synth.a78" +cmds="$CMDS" +maxcyc=8000000 \
		+maxret=100000000 > /dev/null || true
	grep -E "^(MISMATCH|stop|compared|mism)" "$S/lockstep_cmds.log" || true
	grep -q "^LOCKSTEP PASS" "$S/lockstep_cmds.log" && r=1 || r=0
	check $r "lockstep, synthetic ARSC, every command class"
	for seed in ${RANDOM_SEEDS-1 2 3 4}; do
		python3 "$HERE/make_synth_arsc.py" "$S/random$seed.a78" --random "$seed" > /dev/null
		LOG="$S/lockstep_random$seed.log" "$HERE/run_lockstep.sh" "$S/random$seed.a78" +cmds="80@300000,81@600000" \
			+maxcyc=1500000 +maxret=100000000 +abort_ok=1 > /dev/null || true
		grep -E "^(MISMATCH|stop|mism)" "$S/lockstep_random$seed.log" || true
		grep -q "^LOCKSTEP PASS" "$S/lockstep_random$seed.log" && r=1 || r=0
		check $r "lockstep, random-content ARSC seed $seed"
	done
fi
[ "$ok" = 1 ]
