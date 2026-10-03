#!/bin/bash
# The design study's RTL sketch (proposal B) playing a song: tb_cpu.sv with
# the sketch CPU, its asset stream buffer behind a behavioural PSRAM port, and
# the unmodified peripheral at 8 / 1,024 with the watermark remap, at
# 28.636 MHz. This is the run that measured S1 at CPI 1.383
# (docs/BUPCHIP_CORE.md, with WIDE=1); the core itself is checked in
# ../../../s1/.
#   ./run_sketch.sh GAME.a78 [SONG] [SECONDS]      default song 13, 1 s
# GAME.a78 must carry its ARSC block (make_arsc.py). The PCM is compared with
# MiSTer's, $REF (default sim/work/bupchip/ref/song<SONG>.pcm, from
# run_bupchip.sh) when it exists, aligned at the first nonzero frame of each.
# Prints busy, CPI, the asset path's statistics and the batch figures.
#   ASSET=v1     the first stream buffer (bup_asset_v1.sv) instead of v2
#   WIDE=0       one PSRAM chip, a halfword per read, instead of both chips
#                in lockstep (32 bits per read; the default, as measured)
#   TPS=N        PSRAM clocks per read (default 5)
#   SB=0         a fixed-latency asset memory (+alat, default 2) instead
#   TRACE=N      also write the first N retires and compare them, register by
#                register, with the reference's (../../../verif/tb_ref_trace.sv
#                on the same image, no command): cmp_ref.py
# Work files go to $WORK (default sim/work/bupchip/study/sketch). Needs the
# firmware at src/fpga/mister/rtl/bupchip.hex. About 30 s per second.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../../../../../src/fpga/mister/rtl" && pwd)"
VERIF="$(cd "$HERE/../../../verif" && pwd)"
WORK="${WORK:-$HERE/../../../../work/bupchip/study/sketch}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
[ -f "$RTL/bupchip.hex" ] || { echo "run_sketch.sh: no firmware at $RTL/bupchip.hex (docs/BUPCHIP.md, \"Firmware: bupchip.bin\")" >&2; exit 2; }
GAME="$(realpath "${1:?usage: run_sketch.sh GAME.a78 [SONG] [SECONDS]}")"
SONG="${2:-13}"
SECS="${3:-1}"
ASSET="${ASSET:-v2}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
REF="${REF:-$WORK/../../ref/song$SONG.pcm}"

case "$ASSET" in
	v1) ASRC="$HERE/bup_asset_v1.sv" ;;
	v2) ASRC="$HERE/bup_asset.sv" ;;
	*) echo "ASSET must be v1 or v2" >&2; exit 2 ;;
esac
WIDE="${WIDE:-1}"
OBJ="$WORK/obj_${ASSET}_w$WIDE"
SRCS=("$RTL/cache_ram.v" "$RTL/bupchip_peripheral.sv" "$HERE/bup_cpu.sv" "$ASRC" "$HERE/tb_cpu.sv")
if [ ! -x "$OBJ/vtb" ] || [ -n "$(find "${SRCS[@]}" -newer "$OBJ/vtb")" ]; then
	rm -rf "$OBJ"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
		--top-module tb_cpu -DROMHEX="\"$RTL/bupchip.hex\"" -DWIDE="$WIDE" \
		-Mdir "$OBJ" -o vtb "${SRCS[@]}" > "$OBJ.log" 2>&1 \
		|| { grep -E "^%Error" "$OBJ.log" | head -20 >&2; echo "build failed: $OBJ.log" >&2; exit 1; }
	find "$OBJ" -name '*.gch' -delete
fi

RUN="$WORK/song${SONG}_${ASSET}_w$WIDE"
mkdir -p "$RUN"
(cd "$RUN" && "$OBJ/vtb" +rom="$GAME" +song="$SONG" +secs="$SECS" +sb="${SB:-1}" +tps="${TPS:-5}" \
	${TRACE:++trace=$TRACE}) | grep -v "^- " | tee "$RUN/log.txt"

python3 - "$RUN" "$REF" <<'EOF'
import os, struct, sys
run, ref = sys.argv[1:3]
a = open(os.path.join(run, "pushes.bin"), "rb").read()
A = struct.unpack("<%dI" % (len(a) // 4), a)
if os.path.exists(ref):
    b = open(ref, "rb").read()
    B = struct.unpack("<%dI" % (len(b) // 4), b)
    fa = next(i for i, x in enumerate(A) if x)
    fb = next(i for i, x in enumerate(B) if x)
    A2, B2 = A[fa:], B[fb:]
    n = min(len(A2), len(B2))
    m = sum(1 for i in range(n) if A2[i] != B2[i])
    print("PCM against %s: %d frames compared from the first nonzero one, %d differ" % (ref, n, m))
else:
    print("PCM: no reference at %s" % ref)
bs = [tuple(map(int, l.split())) for l in open(os.path.join(run, "batches.txt"))][1:]
c = [x[0] for x in bs]
i = [x[1] for x in bs]
w = 24
pk = max(sum(c[k:k + w]) for k in range(len(c) - w + 1)) * 240 / w / 1e6 if len(c) >= w else 0
print("batches %d: busiest 0.1 s %.2f MHz-eq; worst batch %.2f MHz-eq; average %.2f MHz-eq; CPI %.3f" %
      (len(c), pk, max(c) * 240 / 1e6, sum(c) * 240 / len(c) / 1e6, sum(c) / sum(i)))
EOF

if [ -n "$TRACE" ]; then
	REFBIN="$(WORK="$WORK/../verif" "$VERIF/build.sh" ref_trace tb_ref_trace)"
	"$REFBIN" +rom="$GAME" +trace="$RUN/ref.trace" +maxcyc="${TRACECYC:-2000000}" | grep "^result"
	python3 "$HERE/cmp_ref.py" "$RUN/ref.trace" "$RUN/cpu.trace"
fi
