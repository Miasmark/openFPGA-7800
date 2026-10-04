#!/bin/bash
# The PCM FIFO's head race and the mute through the whole step 4 wrapper
# (tb_s4.sv; docs/BUPCHIP_CORE.md, "PCM and command FIFOs"): fw_pophead.S,
# loaded through the firmware slot, pushes N frames one at a time into the
# empty FIFO at every phase of the 48 kHz pop. bupchip_peripheral raises
# pcm_available in the clock after a push into an empty FIFO, a clock before
# its M10K presents the frame, and the wrapper's tick must wait that clock
# (tick_hold). CoreTone never lets the FIFO run empty at speed, so this is
# the check.sh case for it. Every count must come out once, in order, as
# pushed and as returned to clk_sys, with no tick taking a collided head
# (tb_s4's rdw), and the natural runs must see at least 3 ticks held a clock.
# Runs:
#   plain           cache_ram.v's M10K models
#   poison          cache_ram_poison.v's (a collided head read is garbage)
#   poison_arm15    the same with clk_arm at 21.281 MHz (1.5 x PAL clk_sys)
#   poison_force    +forcetick: a tick forced into the clock after a push
#                   into the empty FIFO, a sure collision; it must wait
#   mute            fw_pophead.S with FAULTAT: a FAULT write after frame M;
#                   frames 1..M-1 (or M) come out, every one after is 0
#   poison_nohold, poison_nohold_force   bupchip_pocket.sv without tick_hold,
#                   naturally and with the forced tick: each must fail
#   mute_nomute     the mute run on bupchip_pocket.sv without the mute in
#                   its frame register: must fail
# Game-free and firmware-free (the program is the firmware).
#   ./run_pophead.sh
# Environment: N (frames, default 6000), WORK (default
# sim/work/bupchip/s4stress), VERILATOR. Needs arm-none-eabi-gcc. About 3
# minutes.
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
RTL="$ROOT/src/fpga/mister/rtl"
CORE="$ROOT/src/fpga/core/bupchip"
PU="$ROOT/src/fpga/pocket_utils"
LINK="$ROOT/sim/bupchip/verif/isa/link.ld"
WORK="${WORK:-$HERE/../../../work/bupchip/s4stress}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
mkdir -p "$WORK/pophead"
WORK="$(cd "$WORK" && pwd)"
P="$WORK/pophead"
N="${N:-6000}"
# The FAULT after frame M, whose push comes 2 x 50 clocks after the FIFO
# emptied: far from the next tick, so frame M is ticked muted.
M=$(( (N / 2) / 300 * 300 + 51 ))
POPS=$(( N + N / 4 + 200 ))

fw() {          # fw NAME as-defsyms...
	local n="$1"
	shift
	arm-none-eabi-gcc -mcpu=arm7tdmi -marm -nostdlib -nostartfiles -Wl,-T,"$LINK" -Wl,--no-warn-rwx-segments \
		"$@" -o "$P/$n.elf" "$HERE/fw_pophead.S"
	arm-none-eabi-objcopy -O binary -j .vectors -j .text "$P/$n.elf" "$P/$n.bin"
}
fw fw -Wa,--defsym,N="$N"
fw fw_mute -Wa,--defsym,N="$N" -Wa,--defsym,FAULTAT="$M"
python3 - "$P/cart.a78" <<'EOF'
import sys
h = bytearray(128)
h[0] = 3
h[1:10] = b"ATARI7800"
h[49:53] = (4096).to_bytes(4, "big")
h[53] = 0x10                            # cartridge type bit 12: the Souper mapper
h[100:128] = b"ACTUAL CART DATA STARTS HERE"
open(sys.argv[1], "wb").write(bytes(h) + b"\xff" * 4096 + bytes(range(16)))
EOF

# tb_s4 on cache_ram.v (../build_s4.sh), on cache_ram_poison.v, the latter
# with tick_hold taken out of bupchip_pocket.sv, and the former with the mute
# taken out.
BIN_PLAIN="$(WORK="$WORK/s4" "$HERE/../build_s4.sh")"
sed 's|^\twire         head_ok = !pcm_available \|\| avail_q;.*$|\twire         head_ok = 1'"'"'b1;|' "$CORE/bupchip_pocket.sv" > "$P/bupchip_pocket_nohold.sv"
grep -q "head_ok = 1'b1;" "$P/bupchip_pocket_nohold.sv" || { echo "run_pophead.sh: could not make the mutation" >&2; exit 1; }
sed 's|cpu_run \&\& pcm_available \&\& !paused \&\& !muted ? pcm_frame|cpu_run \&\& pcm_available \&\& !paused ? pcm_frame|' \
	"$CORE/bupchip_pocket.sv" > "$P/bupchip_pocket_nomute.sv"
! cmp -s "$CORE/bupchip_pocket.sv" "$P/bupchip_pocket_nomute.sv" || { echo "run_pophead.sh: could not make the mute mutation" >&2; exit 1; }
build() {       # build OBJ POCKET_SRC [RAM_MODEL]
	local obj="$1" pocket="$2" ram="${3:-$HERE/cache_ram_poison.v}"
	local srcs=("$RTL/arm7tdmi/arm7tdmi_pkg.sv" "$ram" "$RTL/bupchip_peripheral.sv"
		"$CORE/bup_cpu.sv" "$CORE/bup_tick48k.sv" "$CORE/bup_capture.sv" "$CORE/bup_asset_wr.sv" "$CORE/bup_load_probe.sv"
		"$CORE/bup_asset_cache.sv" "$pocket" "$PU/psram.sv" "$HERE/../psram_model.sv" "$HERE/../tb_s4.sv")
	if [ -x "$obj/vtb" ] && [ -z "$(find "${srcs[@]}" "$0" -newer "$obj/vtb" 2>/dev/null)" ]; then return 0; fi
	rm -rf "$obj"
	"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD --top-module tb_s4 \
		-DBUP_DEBUG -DPCM_DEPTH=1024 -DPREEMPT=1 -DPREFETCH=1 -DBUP_THROTTLE=16 -Mdir "$obj" -o vtb "${srcs[@]}" \
		> "$obj.log" 2>&1 || { grep -E "^%Error" "$obj.log" | head -20 >&2; echo "build failed: $obj.log" >&2; exit 1; }
	find "$obj" \( -name '*.gch' -o -name '*.o' \) -delete
}
build "$WORK/obj_s4_poison" "$CORE/bupchip_pocket.sv"
build "$WORK/obj_s4_poison_nohold" "$P/bupchip_pocket_nohold.sv"
build "$WORK/obj_s4_nomute" "$P/bupchip_pocket_nomute.sv" "$RTL/cache_ram.v"

ok=1
run() {         # run NAME BIN FW EXPECT(pass|fail) [plusargs]
	local name="$1" bin="$2" fwb="$3" exp="$4" r=1 dr=1 held res forced=0 mute=0
	shift 4
	nice -n "${NICE:-5}" "$bin" +fw="$P/$fwb.bin" +rom="$P/cart.a78" +song=0 +secs=1 +pops="$POPS" +skiprom \
		+out="$P/$name" "$@" | grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " > "$P/$name.log"
	res="$(grep "^result:" "$P/$name.log" || echo "result: none")"
	held="$(sed -n 's/^pop  *\([0-9]*\) ticks waited.*/\1/p' "$P/$name.log")"
	case "$*" in *+forcetick*) forced=1 ;; esac
	[ "$fwb" = fw_mute ] && mute="$M"
	python3 - "$P/$name" "$N" "$mute" <<'EOF' > "$P/$name.check" || dr=0
import struct, sys
p, n, m = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def frames(f):
    d = open(f, "rb").read()
    return struct.unpack("<%dI" % (len(d) // 4), d)
ok = True
pushed = frames(p + ".pcm")
if list(pushed) != list(range(1, n + 1)):
    print("pushed: %d frames, not 1..%d" % (len(pushed), n)); ok = False
allout = frames(p + ".out.pcm")
out = [x for x in allout if x]
if m == 0:
    if out != list(range(1, n + 1)):
        bad = next((i for i in range(min(len(out), n)) if out[i] != i + 1), min(len(out), n))
        print("out: %d nonzero frames; first wrong at %d: %s" % (len(out), bad, hex(out[bad]) if bad < len(out) else "missing"))
        ok = False
    else:
        print("out: frames 1..%d once each, in order" % n)
else:
    # FAULT after frame m: 1..m-1 (or m, if its tick came before the write), then only 0
    if out not in (list(range(1, m)), list(range(1, m + 1))):
        print("out: %d nonzero frames, last %s; expected 1..%d or 1..%d, then 0" % (len(out), hex(out[-1]) if out else "-", m - 1, m))
        ok = False
    else:
        last = allout.index(out[-1])
        print("out: frames 1..%d once each, in order, then %d frames all 0 (FAULT after frame %d)" % (len(out), len(allout) - last - 1, m))
sys.exit(0 if ok else 1)
EOF
	grep -Eq "^result: .* fault=$([ "$mute" = 0 ] && echo 00 || echo 5a) halted=0 clear=1 lost=0 rom=0 psram=0 cross=0 shadow=0 " <<< "$res" || r=0
	grep -Eq " mute_bad=0 rd_held=0 held_wr=0 " <<< "$res" || r=0
	grep -Eq " rdw=0 " <<< "$res" || dr=0
	[ "$dr" = 1 ] || r=0
	if [ "$forced" = 1 ]; then
		grep -Eq " forced=1 " <<< "$res" || r=0
		[ "${held:-0}" -ge 1 ] || r=0
	elif [ "$mute" = 0 ]; then
		[ "${held:-0}" -ge 3 ] || r=0
	else
		grep -Eq "^mute  *[1-9][0-9]* ticks while muted, 0 of them not 0" "$P/$name.log" || r=0
	fi
	local rdw
	rdw="$(sed -n 's/.* rdw=\([0-9]*\) .*/\1/p' <<< "$res")"
	if [ "$exp" = pass ]; then
		[ "$r" = 1 ] && echo "PASS $name: $(cat "$P/$name.check"); $held ticks held a clock$([ "$forced" = 1 ] && echo ", one forced")" \
			|| { echo "FAIL $name: $(cat "$P/$name.check"); ${held:-0} ticks held, rdw ${rdw:-?} ($P/$name.log)"; ok=0; }
	else
		[ "$dr" = 0 ] && echo "PASS $name (must fail): $(cat "$P/$name.check"); ${held:-0} ticks held, ${rdw:-?} ticks took a collided head" \
			|| { echo "FAIL $name (must fail) passed"; ok=0; }
	fi
}
run plain               "$BIN_PLAIN"                     fw      pass
run poison              "$WORK/obj_s4_poison/vtb"        fw      pass
run poison_arm15        "$WORK/obj_s4_poison/vtb"        fw      pass +arm15 +pal
run poison_force        "$WORK/obj_s4_poison/vtb"        fw      pass +forcetick +forcetick_after=5 +poison_tdp=0
run mute                "$BIN_PLAIN"                     fw_mute pass
run poison_nohold       "$WORK/obj_s4_poison_nohold/vtb" fw      fail
run poison_nohold_force "$WORK/obj_s4_poison_nohold/vtb" fw      fail +forcetick +forcetick_after=5 +poison_tdp=0
run mute_nomute         "$WORK/obj_s4_nomute/vtb"        fw_mute fail
[ "$ok" = 1 ] && echo "run_pophead.sh: all passed" || echo "run_pophead.sh: FAILED"
[ "$ok" = 1 ]
