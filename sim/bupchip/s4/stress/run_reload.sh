#!/bin/bash
# Reloads with different ARSC contents through the whole step 4 path
# (tb_s4.sv via ../run_s4.sh; docs/BUPCHIP_CORE.md, "Reset and hold"): the
# cache's tags survive a reload unless the 64-clock sweep clears them, and
# ../check.sh's reloads put the same block back each time, so stale lines
# would still hold the right bytes there. Here the blocks differ (game-free,
# ../../verif/make_synth_arsc.py): A (16 looped voices), B (7 voices,
# reverse), C (12 voices, one-shot), N (A with every sample byte inverted:
# the same layout, so A's cached sample lines are exactly where N's differ).
# Each reload's hold lands during a cache fill (+holdfill), and the song after
# the last reload must equal the Python model's PCM for that block
# (../../model/armemu.py), as pushed and as returned to clk_sys:
#   B alone (the reference check), A then B, B then C then A, A then N,
#   N then A.
# These do not catch a cache without its tag sweep: with the sweep taken out,
# A then N still gives N's PCM exactly. 63 of the 64 tags are still valid at
# the release, but the firmware's boot and song touch none of those lines
# before refilling their index (a monitor counted 0 such loads).
# tb_cstress.sv's holds, which change the PSRAM behind every valid line, are
# the check of the sweep.
#   ./run_reload.sh
# Needs the firmware (src/fpga/mister/rtl/bupchip.hex). Environment: WORK
# (default sim/work/bupchip/s4stress; the tb_s4 build goes to $WORK/s4).
# About 10 minutes.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HEX="$(cd "$HERE/../../../../src/fpga/mister/rtl" && pwd)/bupchip.hex"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
[ -f "$HEX" ] || { echo "run_reload.sh: no firmware at $HEX: skipped"; exit 0; }
mkdir -p "$WORK/reload"
WORK="$(cd "$WORK" && pwd)"
S="$WORK/reload"
mk() {          # mk NAME args...: a Souper image from make_synth_arsc.py and its model PCM
	local n="$1"
	shift
	python3 "$HERE/../../verif/make_synth_arsc.py" "$S/$n.a78" "$@" > /dev/null
	python3 - "$S/$n.a78" "$S/${n}_s.a78" <<'EOF'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
d[53] |= 0x10                       # cartridge type bit 12: the Souper mapper
open(sys.argv[2], "wb").write(d)
EOF
	[ -f "$S/${n}_song0.pcm" ] && [ "$S/${n}_song0.pcm" -nt "$S/${n}_s.a78" ] || \
		(cd "$HERE/../../model" && nice -n "${NICE:-5}" python3 armemu.py "$S/${n}_s.a78" --song 0 --secs 1 --pcm "$S/${n}_song0.pcm" > "$S/armemu_$n.log")
}
mk a
mk b --mode reverse --voices 7
mk c --mode oneshot --voices 12
# n: a with every sample byte inverted. Same layout as a, so after a reload
# from a the cache's stale sample lines sit exactly where n's samples are,
# with different bytes: a cache that kept its tags across the reload plays
# a's samples.
python3 - "$S/a_s.a78" "$S/n_s.a78" <<'EOF2'
import struct, sys
d = bytearray(open(sys.argv[1], "rb").read())
base = 128 + int.from_bytes(d[49:53], "big")
assert d[base:base + 4] == b"ARSC"
p = base + struct.unpack_from("<I", d, base + 4)[0]
assert d[p:p + 4] == b"CSMP"
for i in range(struct.unpack_from("<I", d, p + 4)[0]):
    off, n = struct.unpack_from("<II", d, p + 8 + 16 * i)
    for j in range(p + off, p + off + n):
        d[j] ^= 0xFF
open(sys.argv[2], "wb").write(d)
EOF2
[ -f "$S/n_song0.pcm" ] && [ "$S/n_song0.pcm" -nt "$S/n_s.a78" ] || \
	(cd "$HERE/../../model" && nice -n "${NICE:-5}" python3 armemu.py "$S/n_s.a78" --song 0 --secs 1 --pcm "$S/n_song0.pcm" > "$S/armemu_n.log")
python3 - "$S" <<'EOF'
import sys
S = sys.argv[1]
blk = {n: open("%s/%s_s.a78" % (S, n), "rb").read()[128 + 4096:] for n in "abcn"}
for x, y in (("a", "b"), ("b", "c"), ("c", "a"), ("a", "n")):
    n = min(len(blk[x]), len(blk[y]))
    print("blocks %s and %s: %d and %d bytes, %d of the first %d differ" % (x, y, len(blk[x]), len(blk[y]),
          sum(blk[x][i] != blk[y][i] for i in range(n)), n))
EOF
export WORK="$WORK/s4"
ok=1
r() {           # r NAME REF HOLDFILL GAME plusargs...
	local name="$1" ref="$2" hf="$3" game="$4"
	shift 4
	if NAME="$name" REF="$ref" HOLDFILL="$hf" "$HERE/../run_s4.sh" "$game" 0 2 "$@" > "$S/$name.out" 2>&1; then
		echo "PASS $name: $(grep -c '^PCM IDENTICAL: all' "$S/$name.out") streams identical; $(grep '^holds ' "$S/$name.out" | sed 's/  */ /g')"
	else
		echo "FAIL $name ($S/$name.out)"; ok=0
	fi
}
r rl_b   "$S/b_song0.pcm" "" "$S/b_s.a78"
r rl_ab  "$S/b_song0.pcm" 1  "$S/a_s.a78" +reload=150 +rom2="$S/b_s.a78" +holdfill
r rl_bca "$S/a_song0.pcm" 1  "$S/b_s.a78" +reload=120 +reloads=2 +rom2="$S/c_s.a78" +rom3="$S/a_s.a78" +holdfill
r rl_an  "$S/n_song0.pcm" 1  "$S/a_s.a78" +reload=150 +rom2="$S/n_s.a78" +holdfill
r rl_na  "$S/a_song0.pcm" 1  "$S/n_s.a78" +reload=150 +rom2="$S/a_s.a78" +holdfill
[ "$ok" = 1 ] && echo "run_reload.sh: all passed" || echo "run_reload.sh: FAILED"
[ "$ok" = 1 ]
