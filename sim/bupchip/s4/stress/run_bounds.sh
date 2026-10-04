#!/bin/bash
# The asset window's bounds through the whole step 4 path (tb_s4.sv, the
# Pocket wrapper; docs/BUPCHIP_CORE.md, "Memory map and timing per region"):
# fw_bounds.S, loaded through the firmware slot as bupchip.bin, reads back an
# ARSC block of N bytes downloaded through the capture, the receiver and
# psram.sv, with every load size and alignment, then loads at offset HOFF.
# At HOFF = asset_size the core must halt with DATA (5) at `probe`, having
# pushed exactly the expected values (ARM7TDMI lane rules: odd LDRH rotated,
# odd LDRSH the signed byte, unaligned LDR rotated); at HOFF = N - 1 it must
# not halt. Blocks: the minimum 4 bytes, odd lengths, blocks ending on a
# 16-byte line and on a 1 KiB tag boundary, 70,000 and 70,001 bytes.
# Game-free and firmware-free: the program is the firmware.
#   ./run_bounds.sh
# Environment: WORK (default sim/work/bupchip/s4stress), VERILATOR (via
# ../build_s4.sh). Needs arm-none-eabi-gcc. About 2 minutes.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINK="$(cd "$HERE/../../verif/isa" && pwd)/link.ld"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
mkdir -p "$WORK/bounds"
WORK="$(cd "$WORK" && pwd)"
B="$WORK/bounds"
BIN="$(WORK="$WORK/s4" "$HERE/../build_s4.sh")"
ok=1
# N HOFF HSZ: the probe at asset_size halts; at N - 1 (a byte) it does not
CASES="${CASES:-4:4:0 5:5:1 37:37:0 37:37:2 37:36:0 48:48:0 48:48:1 1024:1024:2 1023:1023:0 70000:70000:0 70001:70001:1}"
for c in $CASES; do
	IFS=: read -r n hoff hsz <<< "$c"
	t="$B/b_${n}_${hoff}_${hsz}"
	arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -Wl,-T,"$LINK" -Wl,--no-warn-rwx-segments \
		-Wa,--defsym,N="$n" -Wa,--defsym,HOFF="$hoff" -Wa,--defsym,HSZ="$hsz" -o "$t.elf" "$HERE/fw_bounds.S"
	arm-none-eabi-objcopy -O binary -j .vectors -j .text "$t.elf" "$t.bin"
	probe="$(arm-none-eabi-nm "$t.elf" | sed -n 's/^\([0-9a-f]*\) T probe$/\1/p')"
	python3 - "$t" "$n" "$hoff" "$hsz" <<'PY'
import random, struct, sys
t, n, hoff, hsz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rng = random.Random(n * 7 + hsz)
blk = bytes(rng.randrange(256) for _ in range(n))
h = bytearray(128)
h[0] = 3
h[1:10] = b"ATARI7800"
h[49:53] = (4096).to_bytes(4, "big")
h[53] = 0x10                            # cartridge type bit 12: the Souper mapper
h[100:128] = b"ACTUAL CART DATA STARTS HERE"
open(t + ".a78", "wb").write(bytes(h) + b"\xff" * 4096 + blk)
def ror(v, s):
    s %= 32
    return ((v >> s) | (v << (32 - s))) & 0xffffffff
def sx(v, bits):
    return (v - (1 << bits)) & 0xffffffff if v & (1 << (bits - 1)) else v
def word(a):
    return struct.unpack("<I", blk[a:a + 4])[0]
exp = []
for a in range(n):
    exp.append(blk[a])
for a in range(n - 1):
    al = a & ~1
    hw = blk[al] | blk[al + 1] << 8
    exp.append(ror(hw, 8) if a & 1 else hw)                     # LDRH
    exp.append(sx(blk[a], 8) if a & 1 else sx(hw, 16))          # LDRSH
for a in range(n - 3):
    al = a & ~3
    w = struct.unpack("<I", blk[al:al + 4] + bytes(max(0, al + 4 - n)))[0] if al + 4 > n else word(al)
    exp.append(ror(w, 8 * (a & 3)))                             # LDR
    exp.append(sx(blk[a], 8))                                   # LDRSB
exp.append(blk[n - 1])
if hoff < n:                                                    # the probe is inside: it runs
    exp.append(blk[hoff] if hsz == 0 else None)
open(t + ".exp", "w").write("\n".join("-" if v is None else "%08x" % v for v in exp) + "\n")
PY
	# Words read whole past the block (an unaligned LDR near its end) are not
	# in the expected list: fw_bounds.S keeps every LDR's aligned word inside.
	maxms=$(( 30 + n / 400 ))
	nice -n "${NICE:-5}" "$BIN" +fw="$t.bin" +rom="$t.a78" +song=0 +secs=1 +out="$t" +maxms="$maxms" +skiprom \
		| grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " > "$t.log" || true
	res="$(grep "^result:" "$t.log" || true)"
	halt="$(sed -n 's/^HALT at clock [0-9]*: code \([0-9]*\), pc \([0-9a-f]*\)$/\1 \2/p' "$t.log")"
	r=1
	grep -Eq "^result: .* lost=0 rom=0 psram=0 cross=0 shadow=0 .* rdw=0 held=0 .* mute_bad=0 rd_held=0 held_wr=0 " <<< "$res" \
		|| { echo "  testbench checks failed: $res"; r=0; }
	if [ "$hoff" -ge "$n" ]; then
		[ "$halt" = "5 $(printf %08x $((16#$probe)))" ] || { echo "  expected a DATA halt at $probe, got '${halt:-none}'"; r=0; }
	else
		[ -z "$halt" ] || { echo "  halted ($halt), but the probe is inside the block"; r=0; }
	fi
	python3 - "$t.pcm" "$t.exp" <<'PY' || r=0
import struct, sys
d = open(sys.argv[1], "rb").read()
got = struct.unpack("<%dI" % (len(d) // 4), d)
exp = [None if l.strip() == "-" else int(l, 16) for l in open(sys.argv[2])]
bad = [i for i in range(min(len(got), len(exp))) if exp[i] is not None and got[i] != exp[i]]
if len(got) != len(exp) or bad:
    print("  pushes: %d, expected %d; %d differ%s" % (len(got), len(exp), len(bad),
          (", first at %d: %08x, expected %08x" % (bad[0], got[bad[0]], exp[bad[0]])) if bad else ""))
    sys.exit(1)
print("  %d pushed values all as expected" % len(got))
PY
	asz="$(sed -n 's/^PSRAM check: .* asset_size \([0-9]*\), asset_ready \([01]\)$/\1 \2/p' "$t.log" | tail -1)"
	[ "$asz" = "$n 1" ] || { echo "  asset_size/asset_ready '$asz', expected '$n 1'"; r=0; }
	hs="no halt"; [ -z "$halt" ] || hs="halt code ${halt% *} at ${halt#* }"
	if [ "$r" = 1 ]; then echo "PASS N=$n probe at $hoff size $hsz: $hs, asset_size $n"
	else echo "FAIL N=$n probe at $hoff size $hsz: $t.log"; ok=0; fi
done
[ "$ok" = 1 ] && echo "run_bounds.sh: all passed" || echo "run_bounds.sh: FAILED"
[ "$ok" = 1 ]
