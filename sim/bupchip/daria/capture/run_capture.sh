#!/bin/bash
# DARIA's image capture (tb_capture.sv; docs/DARIA_CORE.md, "Image capture"):
# bup_capture, the message crossing, bup_asset_wr with its window port, and
# psram.sv on ../../s4/psram_model.sv, fed game-free files this script
# generates (random bytes; A78 headers it builds itself):
#   main     2600 images of 0-13 bytes, 4 KB, 32 KB, 33 KB, odd sizes, 128 KB,
#            129 KB, 512 KB and 513 KB; files whose bytes 1-5 are nearly
#            "ATARI" (bytes 49-52 declaring a ROM, so that before the gate they
#            read as an ARSC block); 5-, 6- and 7-byte "ATARI" files; A78
#            files with and without ARSC blocks (odd lengths and offsets, a
#            block past the end); reloads (an image after an A78 and an A78
#            after an image); a firmware download straight after an image or
#            an A78, its flag rising as the cartridge's falls or a clock
#            before, with the cartridge's last bytes after its flag fell;
#            cartridge downloads back to back (START dropping the head, tail
#            and END of the one before); the loader at 2.5 clk_sys per byte,
#            with jitter, and slow
#   a78lock  random A78 and firmware downloads (as ../../s4/stress/
#            run_capstress.sh makes them, with "ATARI" headers), with the
#            BupChip's capture and receiver from git ($REF_REV, before DARIA)
#            in lockstep: every message and receiver output identical
#   mix      random images (up to 600 KB), A78s and firmware, back to back
#            and interleaved
# each with clk_arm at 38.18 MHz (8 per 3 clk_sys, edge aligned), at about
# 38 MHz asynchronous with jitter, and at 28.64 MHz (2 x clk_sys, the
# BupChip's today); main also with psram.sv's CLOCK_SPEED at 50.0 and
# asynchronous at about 32.7 MHz.
#   ./run_capture.sh
#   ./run_capture.sh mutants    seventeen faults, each of which must fail
# Environment: WORK (default sim/work/bupchip/daria/capture; the files, plans
# and logs go there), REF_REV (default 633faf4, the last commit with the
# BupChip-only capture), JOBS (default 3), SEED (default 1), ONLY (an
# extended regular expression: only the runs it matches), VERILATOR.
# Prints PASS or FAIL per run and the checks per case; exits 0 when every
# run passes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
CORE="$ROOT/src/fpga/core/bupchip"
PU="$ROOT/src/fpga/pocket_utils"
S4="$ROOT/sim/bupchip/s4"
WORK="${WORK:-$ROOT/sim/work/bupchip/daria/capture}"
VERILATOR="${VERILATOR:-$( [ -x /opt/verilator-5.040/bin/verilator ] && echo /opt/verilator-5.040/bin/verilator || echo verilator)}"
REF_REV="${REF_REV:-633faf4}"
JOBS="${JOBS:-3}"
SEED="${SEED:-1}"
mkdir -p "$WORK/files" "$WORK/ref" "$WORK/logs"
WORK="$(cd "$WORK" && pwd)"

# ---- the BupChip's capture and receiver before DARIA, renamed -----------------------------
git -C "$ROOT" show "$REF_REV:src/fpga/core/bupchip/bup_capture.sv" \
	| sed 's/^module bup_capture (/module bup_capture_ref (/' > "$WORK/ref/bup_capture_ref.sv.new"
git -C "$ROOT" show "$REF_REV:src/fpga/core/bupchip/bup_asset_wr.sv" \
	| sed 's/^module bup_asset_wr (/module bup_asset_wr_ref (/' > "$WORK/ref/bup_asset_wr_ref.sv.new"
for f in bup_capture_ref bup_asset_wr_ref; do
	grep -q "^module ${f} (" "$WORK/ref/$f.sv.new" || { echo "run_capture.sh: no $f from $REF_REV" >&2; exit 1; }
	cmp -s "$WORK/ref/$f.sv.new" "$WORK/ref/$f.sv" 2>/dev/null && rm -f "$WORK/ref/$f.sv.new" || mv "$WORK/ref/$f.sv.new" "$WORK/ref/$f.sv"
done

# ---- the files and plans ------------------------------------------------------------------
python3 - "$WORK/files" "$SEED" <<'EOF'
import os, random, sys
out, seed = sys.argv[1], int(sys.argv[2])
rng = random.Random(seed)

def rnd(n):
    return bytearray(rng.randbytes(n))

def img(n):
    """A 2600 image: random bytes, never "ATARI" at bytes 1-5."""
    d = rnd(n)
    if n >= 6 and d[1:6] == b"ATARI":
        d[1] ^= 1
    return d

def a78(R, B, decl=None):
    """An A78 header declaring R bytes of ROM (or decl), the ROM, and B bytes
    of block (random: the capture does not look inside it)."""
    h = bytearray(128)
    h[0] = 3
    h[1:17] = b"ATARI7800".ljust(16, b"\0")
    h[17:49] = b"capture bench".ljust(32, b"\0")
    h[49:53] = (R if decl is None else decl).to_bytes(4, "big")
    h[100:128] = b"ACTUAL CART DATA STARTS HERE"
    return h + rnd(R) + rnd(B)

def model(d):
    """What bup_capture must make of a cartridge file: (is_a78, block offset,
    block length). An A78 has "ATARI" at bytes 1-5; its block starts at 128 +
    the ROM size in bytes 49-52, when that is not 0."""
    n = len(d)
    if n < 6 or d[1:6] != b"ATARI":
        return 0, 0, 0
    if n < 53:
        return 1, 0, 0
    R = int.from_bytes(d[49:53], "big")
    start = ((R & 0x1FFFFFF) + 128) & 0x1FFFFFF
    if R == 0 or n <= start:
        return 1, start, 0
    return 1, start, min(n - start, 8 << 20)

plans = {}
count = [0]
def add(plan, kind, data, label, nxt=0, late=0, pace=0):
    count[0] += 1
    path = os.path.join(out, "f%05d.bin" % count[0])
    with open(path, "wb") as f:
        f.write(bytes(data))
    a, bo, bl = model(data) if kind == 0 else (0, 0, 0)
    plans.setdefault(plan, []).append(f"{kind} {len(data)} {a} {bo} {bl} {nxt} {late} {pace} {label} {path}")

# ---- main: the directed cases
P = "main"
add(P, 1, rnd(7827), "fw:7827")
for n in (4096, 32768, 33792):
    add(P, 0, img(n), f"img:{n}")
for n in range(14):
    add(P, 0, img(n), f"img_small:{n}")
for n in (4097, 32769, 65535, 131071, 131073):
    add(P, 0, img(n), f"img_odd:{n}")
for n in (131072, 132096):
    add(P, 0, img(n), f"img_128k:{n}")
for n in (524287, 524288, 524289, 525312):
    add(P, 0, img(n), f"img_512k:{n}")
# nearly "ATARI" at bytes 1-5, and bytes 49-52 declaring 100 bytes of ROM:
# without the gate, bytes 228 on would be an ARSC block
for name, hdr, at in (("ATARJ", b"ATARJ", 1), ("ATARi", b"ATARi", 1), ("BTARI", b"BTARI", 1),
                      ("ATAR0", b"ATAR\0", 1), ("atari", b"atari", 1), ("ATBRI", b"ATBRI", 1),
                      ("ATAQI", b"ATAQI", 1), ("at_byte0", b"ATARI", 0), ("at_byte2", b"ATARI", 2),
                      ("ATARI_bit7", bytes([0x41, 0x54, 0x41, 0x52, 0xC9]), 1)):
    d = rnd(4096)
    d[at:at + 5] = hdr
    d[49:53] = (100).to_bytes(4, "big")
    assert d[1:6] != b"ATARI"
    add(P, 0, d, f"atari_like:{name}")
add(P, 0, bytearray(b"\x03ATAR"), "atari_short:5_bytes")       # mode never known: an image
add(P, 0, bytearray(b"\x03ATARI"), "atari_short:6_bytes")      # an A78 without a block
add(P, 0, bytearray(b"\x03ATARI\x00"), "atari_short:7_bytes")
for R, B in ((4096, 0), (4096, 1), (4096, 2), (4096, 3), (4096, 4), (4096, 5), (4096, 1000),
             (4096, 1001), (4096, 5000), (4096, 70001), (4097, 1001), (1, 7), (0, 500)):
    add(P, 0, a78(R, B), f"a78:R{R}_B{B}")
add(P, 0, a78(4096, 300, decl=4096 + 300 + 50), "a78:declared_past_end")
add(P, 0, a78(4096, 5000), "reload:a78")
add(P, 0, img(40001), "reload:img_after_a78")
add(P, 0, a78(4096, 3001), "reload:a78_after_img")
add(P, 0, img(7), "reload:img7_after_a78")
add(P, 0, img(8), "reload:img8_after_img7")
add(P, 0, img(50001), "interleave:img_then_fw_same_clock", nxt=2)
add(P, 1, rnd(4099), "interleave:img_then_fw_same_clock")
add(P, 0, img(50003), "interleave:img_3_late_bytes_fw_same_clock", nxt=2, late=3)
add(P, 1, rnd(16384), "interleave:img_3_late_bytes_fw_same_clock")
add(P, 0, img(9999), "interleave:img_2_late_bytes_fw_clock_before", nxt=3, late=2)
add(P, 1, rnd(17000), "interleave:img_2_late_bytes_fw_clock_before")
add(P, 0, img(131075), "interleave:img128k_1_late_byte_fw_clock_before", nxt=3, late=1)
add(P, 1, rnd(9000), "interleave:img128k_1_late_byte_fw_clock_before")
add(P, 0, img(5), "interleave:img5_fw_same_clock", nxt=2)
add(P, 1, rnd(7827), "interleave:img5_fw_same_clock")
add(P, 0, a78(4096, 2001), "interleave:a78_4_late_bytes_fw_same_clock", nxt=2, late=4)
add(P, 1, rnd(5), "interleave:a78_4_late_bytes_fw_same_clock")
add(P, 1, rnd(7827), "fw:7827_again")
add(P, 0, img(3001), "b2b:img_after_img", nxt=1)
add(P, 0, img(40001), "b2b:img_after_img")
add(P, 0, img(20001), "b2b:a78_after_img", nxt=1)
add(P, 0, a78(4096, 777), "b2b:a78_after_img")
add(P, 0, a78(4096, 999), "b2b:img_after_a78", nxt=1)
add(P, 0, img(6001), "b2b:img_after_a78")
add(P, 0, a78(4096, 1001), "b2b:a78_after_a78", nxt=1)
add(P, 0, a78(4096, 2000), "b2b:a78_after_a78")
add(P, 0, img(100001), "b2b:three_images", nxt=1)
add(P, 0, img(5), "b2b:three_images", nxt=1)
add(P, 0, img(132097), "b2b:three_images")
add(P, 0, img(20001), "pace:img_jitter", pace=1)
add(P, 0, img(3001), "pace:img_slow", pace=2)
add(P, 0, a78(4096, 3001), "pace:a78_jitter", pace=1)
add(P, 1, rnd(16385), "fw:16385")

# ---- a78lock: random A78s and firmware, as run_capstress.sh makes them
def pick_block():
    r = rng.randrange(100)
    if r < 30: return rng.randrange(50)
    if r < 45: return 16 * rng.randint(1, 64) + rng.randrange(3) - 1
    if r < 85: return rng.randrange(3001)
    return rng.randrange(70001)

def fw_size():
    r = rng.randrange(100)
    return rng.randrange(13) if r < 20 else 16384 + rng.randrange(3) - 1 if r < 30 else 17000 if r < 35 else rng.randrange(9001)

def random_plan(P, n, images):
    k = 0
    prev = 0
    while k < n:
        k += 1
        pace = 0 if rng.randrange(10) < 6 else 1 if rng.randrange(10) < 9 else 2
        if prev in (2, 3):
            add(P, 1, rnd(fw_size()), "random:cart_then_fw", pace=pace)
            prev = 0
            continue
        fw = prev == 0 and rng.randrange(100) < 25
        if fw:
            add(P, 1, rnd(fw_size()), "random:fw", pace=pace)
            prev = 0
            continue
        if images and rng.randrange(100) < 55:
            r = rng.randrange(100)
            m = rng.randrange(21) if r < 15 else rng.randrange(70001) if r < 75 else \
                131072 + rng.randrange(-40, 41) if r < 90 else rng.randrange(200001) if r < 97 else \
                524288 + rng.randrange(-3000, 70001)
            d, kind = img(m), "image"
        else:
            r = rng.randrange(100)
            R = 0 if r < 10 else 1 + 2 * rng.randrange(301) if r < 25 else 4096 if r < 35 else rng.randrange(601)
            B = pick_block()
            decl = R + B + 1 + rng.randrange(101) if rng.randrange(100) < 5 else None
            d, kind = a78(R, B, decl), "a78"
        r = rng.randrange(100)
        nxt = 1 if r < 15 else 2 if r < 25 else 3 if r < 30 else 0
        if k == n:
            nxt = 0
        late = rng.randrange(5) if nxt != 1 and rng.randrange(100) < 30 else 0
        late = min(late, len(d))
        add(P, 0, d, f"random:{kind}" + ("_b2b" if prev == 1 else ""), nxt=nxt, late=late, pace=pace)
        prev = nxt
    if prev in (2, 3):
        add(P, 1, rnd(fw_size()), "random:cart_then_fw")

random_plan("a78lock", 120, False)
random_plan("mix", 70, True)

for name, lines in plans.items():
    with open(os.path.join(out, name + ".plan"), "w") as f:
        f.write("\n".join(lines) + "\n")
EOF

# ---- builds -------------------------------------------------------------------------------
SRCS=("$CORE/bup_capture.sv" "$CORE/bup_asset_wr.sv" "$PU/psram.sv" "$S4/psram_model.sv"
	"$WORK/ref/bup_capture_ref.sv" "$WORK/ref/bup_asset_wr_ref.sv" "$HERE/tb_capture.sv")
build() {       # build OBJ PSRAM_MHZ [SOURCES...]: rebuilt when a source is newer
	local obj="$1" mhz="$2"
	shift 2
	local srcs=("${SRCS[@]}")
	[ "$#" = 0 ] || srcs=("$@")
	if ! [ -x "$obj/vtb" ] || [ -n "$(find "${srcs[@]}" "$0" -newer "$obj/vtb" 2>/dev/null)" ]; then
		rm -rf "$obj"
		"$VERILATOR" --binary --timing -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
			--top-module tb_capture -DPSRAM_MHZ="$mhz" -Mdir "$obj" -o vtb "${srcs[@]}" > "$obj.log" 2>&1 \
			|| { grep -E "^%Error" "$obj.log" | head -20 >&2; echo "build failed: $obj.log" >&2; return 1; }
		find "$obj" \( -name '*.gch' -o -name '*.o' \) -delete
	fi
}
F="$WORK/files"

# ---- ./run_capture.sh mutants: faults the bench must find ---------------------------------
# Each is one edit to a copy of bup_capture.sv or bup_asset_wr.sv, run on the
# main plan with clk_arm at 38.18 MHz; every one must fail. Two edits are
# left out because they cannot fail at the loader's rate: END not waiting
# for an idle controller (the last write ends at least 8 clk_arm before END
# arrives; BUPCHIP_CORE.md, "Write rate"), and win_we without its img_ready
# term (no WRITE comes while img_ready is high).
if [ "$1" = mutants ]; then
	M="$WORK/mut"
	mkdir -p "$M"
	python3 - "$CORE" "$M" <<'EOF' > "$M/list"
import os, sys
core, out = sys.argv[1], sys.argv[2]
C, W = "bup_capture.sv", "bup_asset_wr.sv"
MUT = (
	("gate_never_a78", C, "g_a78 <= a78_now;", "g_a78 <= 1'b0;"),
	("gate_always_a78", C, "g_a78 <= a78_now;", "g_a78 <= 1'b1;"),
	("gate_byte5_ignored", C, "wire         a78_now = h_match && load_data == \"I\";", "wire         a78_now = h_match;"),
	("no_head", C, "if (h_last && !a78_now) begin", "if (1'b0) begin"),
	("head_high_lane_always", C, "wire         h_hi = {h_idx, 1'b1} < h_n;", "wire         h_hi = 1'b1;"),
	("short_file_no_head", C, "if (!g_known && size != 24'd0) begin", "if (1'b0) begin"),
	("tail_without_image_bit", C, "msg_pl <= {3'd0, img_on, 2'b01, size[22:1], 8'd0, lo};", "msg_pl <= {3'd0, 1'b0, 2'b01, size[22:1], 8'd0, lo};"),
	("no_512k_drop", C, "load_addr[24:19] == 6'd0;", "load_addr[24:23] == 2'd0;"),
	("header_bytes_in_a78_size", C, "size <= h_last && a78_now ? 24'd0 : f_size;", "size <= f_size;"),
	("end_without_image_bit", C, "msg_pl <= {19'd0, !g_a78, size};", "msg_pl <= {19'd0, 1'b0, size};"),
	("window_lanes_swapped", W, "assign win_be = m_pl[16] ? {m_pl[39:38], 2'b00} : {2'b00, m_pl[39:38]};", "assign win_be = m_pl[16] ? {2'b00, m_pl[39:38]} : {m_pl[39:38], 2'b00};"),
	("window_past_128k", W, "m_pl[37:32] == 6'd0 && !img_ready;", "!img_ready;"),
	("window_for_a78_writes", W, "psram_write_en && m_pl[40] &&", "psram_write_en &&"),
	("start_keeps_img_ready", W, "\t\t\t\t\tasset_ready <= 1'b0;\n\t\t\t\t\timg_ready <= 1'b0;", "\t\t\t\t\tasset_ready <= 1'b0;"),
	("img_ready_at_4", W, "img_ready <= m_pl[23:0] >= 24'd8;", "img_ready <= m_pl[23:0] >= 24'd4;"),
	("img_size_uncapped", W, "img_size <= m_pl[23:19] != 5'd0 ? 20'h80000 : {1'b0, m_pl[18:0]};", "img_size <= m_pl[19:0];"),
	("image_end_sets_asset", W, "if (m_pl[24]) begin\t// an image", "if (1'b0) begin"),
)
for name, f, old, new in MUT:
	d = os.path.join(out, name)
	os.makedirs(d, exist_ok=True)
	for g in (C, W):
		t = open(os.path.join(core, g)).read()
		if g == f:
			assert t.count(old) == 1, (name, old)
			t = t.replace(old, new)
		path = os.path.join(d, g)
		if not os.path.exists(path) or open(path).read() != t:	# keep a build that is up to date
			open(path, "w").write(t)
	print(name)
EOF
	mrun() {        # mrun NAME: build and run one mutant
		local d="$M/$1" s=("${SRCS[@]}")
		s[0]="$d/bup_capture.sv"
		s[1]="$d/bup_asset_wr.sv"
		build "$d/obj" 28.636364 "${s[@]}" || return 0
		nice -n "${NICE:-5}" "$d/obj/vtb" +plan="$F/main.plan" +seed="$SEED" +clk=a38 2>&1 \
			| grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " > "$d/run.log" || true
	}
	for m in $(cat "$M/list"); do
		while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
		mrun "$m" &
	done
	wait
	ok=1
	for m in $(cat "$M/list"); do
		res="$(grep "^result:" "$M/$m/run.log" 2>/dev/null || echo "result: none")"
		if [ "$res" = "result: none" ]; then echo "FAIL mutant $m: no result ($M/$m)"; ok=0
		elif grep -Eq "^result: checks=[1-9][0-9]* bad=0 seq=0 lost=0 overrun=0 order=0 start=0 lost_s=0 lost_x=0 win=0 endw=0 viol=0 " <<< "$res"; then
			echo "FAIL mutant $m: passed ($M/$m/run.log)"; ok=0
		else
			echo "PASS mutant $m fails: ${res#result: }"
			grep -m1 -E "BAD" "$M/$m/run.log" | cut -c1-160 | sed 's/^/  /'
		fi
	done
	[ "$ok" = 1 ] && echo "run_capture.sh mutants: every mutant failed" || echo "run_capture.sh mutants: FAILED"
	[ "$ok" = 1 ]
	exit
fi

build "$WORK/obj_cs28" 28.636364 || exit 1
build "$WORK/obj_cs50" 50.0 || exit 1

# ---- runs ---------------------------------------------------------------------------------
RUNS=(
	"main_a38       cs28 main    +clk=a38"
	"main_async38   cs28 main    +clk=async +arm_ps=13100 +armjit=300"
	"main_async38j  cs28 main    +clk=async +arm_ps=12600 +armjit=1500"
	"main_a38_cs50  cs50 main    +clk=a38"
	"main_async33   cs28 main    +clk=async +arm_ps=15280 +armjit=500"
	"main_x2        cs28 main    +clk=x2"
	"a78lock_a38    cs28 a78lock +clk=a38 +lockstep"
	"a78lock_async  cs28 a78lock +clk=async +arm_ps=13100 +armjit=800 +lockstep"
	"a78lock_x2     cs28 a78lock +clk=x2 +lockstep"
	"mix_a38        cs28 mix     +clk=a38"
	"mix_async38    cs28 mix     +clk=async +arm_ps=13300 +armjit=600"
)
run() {         # run NAME OBJ PLAN plusargs...
	local name="$1" obj="$2" plan="$3"
	shift 3
	nice -n "${NICE:-5}" "$WORK/obj_$obj/vtb" +plan="$F/$plan.plan" +seed="$SEED" "$@" 2>&1 \
		| grep -v "^\[0\] -Info: psram.sv" | grep -v "^- " > "$WORK/logs/$name.log" || true
}
SEL=()
for r in "${RUNS[@]}"; do
	set -- $r
	[ -z "$ONLY" ] || grep -Eq "$ONLY" <<< "$1" && SEL+=("$r")
done
for r in "${SEL[@]}"; do
	set -- $r
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
	run "$@" &
done
wait
ok=1
for r in "${SEL[@]}"; do
	set -- $r
	log="$WORK/logs/$1.log"
	res="$(grep "^result:" "$log" || echo "result: none")"
	pass=0
	if grep -Eq "^result: checks=[1-9][0-9]* bad=0 seq=0 lost=0 overrun=0 order=0 start=0 lost_s=0 lost_x=0 win=0 endw=0 viol=0 ls=[0-9]+ lsdiff=0$" <<< "$res"; then
		pass=1
		case "$*" in *+lockstep*) grep -Eq " ls=[1-9][0-9]* " <<< "$res" || pass=0 ;; esac
	fi
	if [ "$pass" = 1 ]; then echo "PASS $1: ${res#result: }"; else echo "FAIL $1: ${res#result: } ($log)"; ok=0; fi
	# checks per case: the label's part before the colon
	grep -E "^check " "$log" | sed -E 's/^check ([^:]*):[^ ]* (ok|BAD).*/\1 \2/' | sort | uniq -c \
		| awk '{ c[$2] += $1; if ($3 == "ok") p[$2] += $1 } END { for (k in c) printf "  %-12s %3d of %3d ok\n", k, p[k], c[k] }' | sort
	grep -E "^capture bench: [0-9]|^  lockstep" "$log" | sed 's/^/  /'
done
[ "$ok" = 1 ] && echo "run_capture.sh: all passed" || echo "run_capture.sh: FAILED"
[ "$ok" = 1 ]
