#!/bin/bash
# The BupChip jukebox (jukebox.py) in the whole-core simulation, as run_sim.sh
# runs souper_test.py's cartridge: the firmware through its data slot, the
# PSRAM model on cram0, and tb_load.sv's +joyscript pressing joystick 1. The
# BupChip must receive exactly the commands the presses ask for, its PCM must
# equal the firmware model's (model/armemu.py, fed the same commands at the
# same batches) and come back to clk_sys unchanged, and the dumped frames,
# read back with the jukebox's own font, must show the song and command.
#   ./run_jukebox.sh                       game-free: the synthetic ARSC block
#   ./run_jukebox.sh GAME.a78 [FoxBox.cdf]  a game's block: songs 13 and 14
# Needs ../run_sim.sh's tb_load build (VTB, default ../work/obj_load/vtb) and
# the firmware at src/fpga/mister/rtl/bupchip.hex. Work files, frames as PNG
# included, go to $WORK/jukebox/synth or .../game. About 7 minutes game-free,
# 10 with a game.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$HERE/../../src/fpga/mister/rtl"
WORK="${WORK:-$HERE/../work/bupchip}"
VTB="$(realpath "${VTB:-$HERE/../work/obj_load/vtb}")"
[ -f "$RTL/bupchip.hex" ] || { echo "run_jukebox.sh: no firmware at $RTL/bupchip.hex (docs/BUPCHIP.md)" >&2; exit 2; }
[ -x "$VTB" ] && [ ! "$HERE/../tb_load.sv" -nt "$VTB" ] || { echo "run_jukebox.sh: build tb_load first (../run_sim.sh)" >&2; exit 2; }

if [ -n "$1" ]; then
	D="$WORK/jukebox/game"; mkdir -p "$D"
	python3 "$HERE/jukebox.py" "$D/jukebox.a78" --arsc "$1" ${2:+--cdf "$2"}
	BLOCK="$(realpath "$1")"; CDF="${2:+$(realpath "$2")}"
	# 13 taps right (68 ms each), fire, down, up: songs 13 and 14
	{ echo "100 dump"
	  for k in $(seq 0 12); do echo "$((150 + 68 * k)) 1"; echo "$((184 + 68 * k)) 0"; done
	  echo "1050 dump"; echo "1080 200"; echo "1130 0"; echo "1200 dump"
	  echo "1700 4"; echo "1750 0"; echo "1800 8"; echo "1850 0"; echo "1950 dump"; } > "$D/joy.txt"
	MS=2300; CMDS=8D,00,8E
	FRAMES="0:00:PRESS FIRE TO PLAY 1:13:PRESS FIRE TO PLAY 2:13:SENT \$8D: PLAY 13 3:14:SENT \$8E: PLAY 14"
else
	D="$WORK/jukebox/synth"; mkdir -p "$D"
	python3 "$HERE/verif/make_synth_arsc.py" "$D/synth.a78" --arsc "$D/synth.arsc" > /dev/null
	python3 "$HERE/jukebox.py" "$D/jukebox.a78" --arsc "$D/synth.arsc"
	BLOCK="$D/synth.arsc"; CDF=
	cat > "$D/joy.txt" <<'EOF'
# ms after reset, then joy0 (hex: 1 right, 2 left, 4 down, 8 up, 200 A) or dump
100 dump
150 1
184 0
220 200
270 0
330 dump
500 4
550 0
600 2
634 0
670 2
704 0
760 dump
800 8
850 0
950 dump
# right held 33 frames: a step at once, after 24 frames and after 30
1000 1
1550 0
1600 dump
EOF
	MS=1700; CMDS=81,00,80
	FRAMES="0:00:PRESS FIRE TO PLAY 1:01:SENT \$81: PLAY 01 2:31:SENT \$00: STOP 3:00:SENT \$80: PLAY 00 4:03:SENT \$80: PLAY 00"
fi

cd "$D"
ln -sfn "$(dirname "$VTB")/../rtl" rtl
python3 "$HERE/../../tools/hex2bin.py" "$RTL/bupchip.hex" > bupchip.bin
rm -f frame_*.ppm frame_*.png
"$VTB" +image=jukebox.a78 +bupfw=bupchip.bin +bupfwlast +bupms=$MS +bupout=jb +joyscript=joy.txt +bupcmdlog > sim.log
grep -E "^(LOAD|BUPCMD|BUPCHIP result)" sim.log
python3 - "$HERE" "$BLOCK" "$CDF" "$CMDS" "$FRAMES" <<'EOF'
import os, re, struct, sys, zlib
here, block, cdf, want_cmds, want_frames = sys.argv[1:6]
sys.path[:0] = [here, os.path.join(here, "model")]
from jukebox import FONT, BIG, DOT
import armemu
ok = True
def check(cond, what):
    global ok
    print(("PASS " if cond else "FAIL ") + what)
    ok &= bool(cond)

log = open("sim.log").read()
sent = [c.upper() for c in re.findall(r"^BUPCMD sent  \$(\w\w)", log, re.M)]
taken = [(c.upper(), int(p)) for c, p in re.findall(r"^BUPCMD taken \$(\w\w) at [\d.]+ ms, pushed (\d+)", log, re.M)]
want = want_cmds.upper().split(",")
check(sent == want and [c for c, _ in taken] == want,
      f"commands: sent {' '.join(sent)}, taken {' '.join(c for c, _ in taken)}; expected {' '.join(want)}")
check(re.search(r"^BUPCHIP result: fw_loaded=1 asset_ready=1 cpu_run=1 halted=0 \S+ \S+ fault=00 muted=0 .* under=0 over=0 .* "
                r"out_nz=[1-9]\d* mix_nz=[1-9]\d* arsc_bad=0 psram_viol=0$", log, re.M),
      "BupChip ran clean, and its audio reached the mixer")

# PCM: the model gets each command at the batch the firmware took it in.
def frames(p):
    d = open(p, "rb").read()
    return struct.unpack(f"<{len(d) // 4}I", d[:len(d) // 4 * 4])
ours, out = frames("jb.pcm"), frames("jb.out.pcm")
if taken:
    p0 = taken[0][1]
    sched = {}
    for c, p in taken:
        assert (p - p0) % armemu.BATCH == 0, "a command taken mid-batch"
        sched.setdefault((p - p0) // armemu.BATCH, []).append(int(c, 16))
    m = armemu.ARM(armemu.load_asset(block))
    armemu.boot(m)
    pre = len(m.p.frames)
    armemu.render(m, -(-(len(ours) - p0) // armemu.BATCH), sched)
    ref = m.p.frames[pre:pre + len(ours) - p0]
    bad = [i for i, (x, y) in enumerate(zip(ours[p0:], ref)) if x != y]
    nz = sum(1 for x in ours[p0:] if x)
    check(not any(ours[:p0]) and not bad and len(ref) == len(ours) - p0 and nz,
          f"PCM: {len(ours) - p0} frames pushed from the first command ({nz} nonzero), "
          f"{len(bad)} differ from the model" + (f", first at {bad[0]}" if bad else ""))
    so = int(re.search(r"^BUPCHIP song start: pushed -?\d+, output (-?\d+)", log, re.M).group(1))
    n = len(out) - so
    check(so >= 0 and out[so:] == ours[p0:p0 + n], f"PCM returned to clk_sys: {n} frames equal the pushed ones")
    for c, p in taken:
        s = ours[p:p + 4800]
        print(f"     ${c} taken at frame {p}: next 0.1 s {sum(1 for x in s if x)} of {len(s)} frames nonzero")

# Frames: read the text and the big digits back with the jukebox's font.
glyphs = {tuple(int(r, 16) for r in v.split()): k for k, v in FONT.items()}
digits = {tuple(int(r, 16) for r in (BIG if d == 0 else FONT[str(d)]).split()): d for d in range(10)}
names = [""] * 32
if cdf:
    lines = [l.strip() for l in open(cdf, encoding="latin-1").read().splitlines()]
    k = lines.index("CORETONE")
    for n, p in enumerate([l for l in lines[k + 3:] if l][:32]):
        names[n] = os.path.splitext(p.replace("\\", "/").split("/")[-1])[0].upper()

def read_screen(path):
    data = open(path, "rb").read()
    hdr = data.split(b"\n", 3)
    w, h = map(int, hdr[1].split())
    px = hdr[3]
    # the BUP_DEBUG status overlay owns the top-left 96 x 104 pixels
    lit = [[(x >= 96 or y >= 104) and px[3 * (y * w + x):3 * (y * w + x) + 3] != b"\0\0\0"
            for x in range(w)] for y in range(h)]
    rows = [y for y in range(h) if any(lit[y])]
    bands = []
    for y in rows:
        if bands and y == bands[-1][1] + 1:
            bands[-1][1] = y
        else:
            bands.append([y, y])
    texts, big = [], []
    for y0, y1 in bands:
        best = None
        for phase in range(8):
            s = ""
            for x in range(phase, w - 7, 8):
                cell = tuple(sum(lit[y][x + i] << (7 - i) for i in range(8)) for y in range(y0, y0 + 7))
                if y1 - y0 != 6 or any(v & 0x83 for v in cell) or tuple(v >> 2 for v in cell) not in glyphs:
                    s = None
                    break
                s += glyphs[tuple(v >> 2 for v in cell)]
            if s is not None and (best is None or len(s.strip()) > len(best)):
                best = s.strip()
        if best is not None:
            texts.append(best)
        else:
            big.append(y0)
    number = None
    if len(big) == 7 and all(b - a == 8 for a, b in zip(big, big[1:])):
        total = sum(sum(lit[y]) for y in range(big[0], big[0] + 56))
        for x0 in range(w - 88):
            got = []
            for k in range(2):
                pat = tuple(sum(lit[big[0] + 8 * r + 3][x0 + 48 * k + 8 * c + 3] << (4 - c) for c in range(5))
                            for r in range(7))
                got.append(digits.get(pat))
            if None not in got:
                dots = sum(bin(v).count("1") for d in got
                           for v in (int(r, 16) for r in (BIG if d == 0 else FONT[str(d)]).split()))
                if dots * 49 == total:
                    number = got[0] * 10 + got[1]
                    break
    with open(path[:-4] + ".png", "wb") as f:           # P6 to PNG, standard library only
        raw = b"".join(b"\0" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))
        chunk = lambda t, b: struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    return number, texts

for spec in re.findall(r"(\d+):(\d\d):(.+?)(?= \d+:\d\d:|$)", want_frames):
    i, song, status = int(spec[0]), int(spec[1]), spec[2]
    path = f"frame_{i:03d}.ppm"
    if not os.path.exists(path):
        check(False, f"{path} was not written")
        continue
    number, texts = read_screen(path)
    print(f"     {path[:-4]}.png: [{number if number is None else f'{number:02d}'}] " + " | ".join(texts))
    want_texts = [f"COMMAND ${0x80 | song:02X}", status] + ([names[song]] if names[song] else [])
    check(number == song and all(t in texts for t in want_texts),
          f"{path}: shows song {song:02d}, " + ", ".join(want_texts))
print("JUKEBOX " + ("pass" if ok else "FAIL"))
sys.exit(0 if ok else 1)
EOF
