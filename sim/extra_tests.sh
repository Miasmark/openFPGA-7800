#!/bin/bash
# Game-style tests built from 7800basic samples (GPL tools, built locally; no
# ROMs are stored in this repository). Needs git, a C compiler, libpng-dev,
# flex, python3 with Pillow, and the Verilator build that run_sim.sh makes.
#
#   multisprite  24 holey-DMA sprites crossing zones: frames in work/extra/
#                multisprite_*.png. Every sprite must match gfx/herodown1.png
#                row for row, with nothing drawn above or below it.
#   pokey450     POKEY at $450 (A78 type 0x0040): audio stats + WAV
#   pokey4000    POKEY at $4000 (type 0x0001, the retail location): same
#   savekey      SaveKey on port 2 and its save slot
#   firmware     HSC firmware / Supercharger BIOS data slots
#   supercharger Supercharger loads without the BIOS (POCKET_SUPERCHARGER's
#                stub), from ar_test.py's images; AR_TAPE=1 adds the
#                tape path with the BIOS (long: about 20 simulated seconds)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
X="$WORK/extra"
mkdir -p "$X"
[ -x "$WORK/obj_load/vtb" ] || { echo "run ./run_sim.sh first"; exit 1; }

if [ ! -x "$X/dasm/bin/dasm" ]; then
	git clone -q --depth 1 https://github.com/dasm-assembler/dasm "$X/dasm"
	make -C "$X/dasm" -j4 >/dev/null
fi
if [ ! -x "$X/7800basic/7800basic" ]; then
	git clone -q --depth 1 https://github.com/7800-devtools/7800basic "$X/7800basic"
	make -C "$X/7800basic" -j4 all >/dev/null 2>&1
fi
export PATH="$X/dasm/bin:$X/7800basic:$PATH" bas7800dir="$X/7800basic"

build() {   # build <name> <sample> <sed expression or "">
	rm -rf "$X/$1"; cp -r "$X/7800basic/samples/$2" "$X/$1"
	[ -n "$3" ] && sed -i "$3" "$X/$1/$2.bas"
	(cd "$X/$1" && sh "$X/7800basic/7800basic.native.sh" "$2.bas" >/dev/null 2>&1)
	ln -sfn "$WORK/rtl" "$X/$1/rtl"
}

audio_stats() {
	python3 - "$1" <<'PY'
import struct, sys, wave
d = open(sys.argv[1] + "/audio_raw.pcm", "rb").read()
v = struct.unpack(f"<{len(d)//2}H", d)
step = 12013
for i in range(0, len(v), step):
    seg = v[i:i+step]
    print(f"  t={i/48052:.2f}s min={min(seg)} max={max(seg)} levels={len(set(seg))}")
w = wave.open(sys.argv[1] + "/audio.wav", "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(48052)
w.writeframes(struct.pack(f"<{len(v)}h", *[x - 32768 for x in v])); w.close()
PY
}

echo "-- multisprite (holey DMA)"
ms="$X/multisprite"; build multisprite multisprite ""
(cd "$ms" && "$WORK/obj_load/vtb" +image=multisprite.bas.a78 +audf=0 +dump=3 | grep LOAD)
python3 - "$ms" <<'PY'
import sys
from PIL import Image
for i in range(1, 3):
    im = Image.open(f"{sys.argv[1]}/frame_{i:03d}.ppm")
    im.resize((im.size[0] * 2, im.size[1] * 2), Image.NEAREST).save(f"{sys.argv[1]}/multisprite_{i}.png")
    print(f"  wrote {sys.argv[1]}/multisprite_{i}.png")
PY

echo "-- POKEY at \$450"
build pokey450 pokey 's/ set pokeysupport on/ set pokeysupport $450/'
(cd "$X/pokey450" && "$WORK/obj_load/vtb" +image=pokey.bas.a78 +wav=2000 | grep -E "LOAD")
audio_stats "$X/pokey450"

echo "-- POKEY at \$4000"
build pokey4000 pokey 's/ set pokeysupport on/ set pokeysupport $4000/'
(cd "$X/pokey4000" && "$WORK/obj_load/vtb" +image=pokey.bas.a78 +wav=2000 | grep -E "LOAD")
audio_stats "$X/pokey4000"

echo "-- DLI + WSYNC + POKEY sweep at \$4000 (Ballblazer's siren pattern)"
mkdir -p "$X/dli"; ln -sfn "$WORK/rtl" "$X/dli/rtl"
dasm "$HERE/dli_pokey_test.asm" -f3 -o"$X/dli/dli.bin" >/dev/null
python3 "$HERE/make_a78.py" --bin "$X/dli/dli.bin" --type 0x0001 > "$X/dli/dli.a78"
(cd "$X/dli" && "$WORK/obj_load/vtb" +image=dli.a78 +wav=1000 | grep -E "LOAD|PROBE")
echo "  expect: 60 NMIs, main loop writes in the hundreds of thousands, 61 AUDF1 writes"
audio_stats "$X/dli"

echo "-- SaveKey (24LC256 on port 2) and its save slot"
mkdir -p "$X/savekey"; ln -sfn "$WORK/rtl" "$X/savekey/rtl"
dasm "$HERE/savekey_test.asm" -f3 -I"$X/7800basic/includes" -o"$X/savekey/sk.bin" >/dev/null
python3 "$HERE/make_a78.py" --bin "$X/savekey/sk.bin" --save 2 > "$X/savekey/sk_auto.a78"
python3 "$HERE/make_a78.py" --bin "$X/savekey/sk.bin" --save 3 > "$X/savekey/sk_both.a78"
python3 "$HERE/make_a78.py" --bin "$X/savekey/sk.bin" > "$X/savekey/sk_plain.a78"
python3 -c "import os; open('$X/savekey/random.bin','wb').write(os.urandom(32768))"
cd "$X/savekey"
echo "  Auto, header declares a SaveKey (expect pass tone ~1962 Hz, bytes match):"
"$WORK/obj_load/vtb" +image=sk_auto.a78 +audf=7 +sk_auto +skcheck | grep -E "TONE|SAVEKEY"
echo "  Auto, header declares HSC and SaveKey (byte 58 = 3, as Triple Punch; expect pass tone):"
"$WORK/obj_load/vtb" +image=sk_both.a78 +audf=7 +sk_auto +skcheck | grep -E "TONE|SAVEKEY"
echo "  Auto, header declares none (expect fail tone ~490 Hz):"
"$WORK/obj_load/vtb" +image=sk_plain.a78 +audf=31 +sk_auto | grep TONE
echo "  32 KiB save round trip, APF read protocol (expect exactly the 8 bytes the cart wrote to differ):"
"$WORK/obj_load/vtb" +image=sk_plain.a78 +audf=7 +sk_on +sksave=random.bin | grep -E "SAVEKEY"
cd - >/dev/null

echo "-- Firmware slots: HSC firmware and Supercharger BIOS (not in this repository;"
echo "   MiSTer's copies are fetched at test time, as a user would supply them)"
mkdir -p "$X/fw"; ln -sfn "$WORK/rtl" "$X/fw/rtl"
UP="https://raw.githubusercontent.com/MiSTer-unstable-nightlies/Atari7800_MiSTer/$(cat "$HERE/../src/fpga/mister/UPSTREAM_COMMIT")/rtl"
[ -s "$X/fw/highscor.rom" ] || curl -fsSL "$UP/mem4.hex" | python3 "$HERE/../tools/hex2bin.py" > "$X/fw/highscor.rom"
[ -s "$X/fw/supercharger.bin" ] || curl -fsSL "$UP/ar.hex" | python3 "$HERE/../tools/hex2bin.py" > "$X/fw/supercharger.bin"
python3 "$HERE/make_a78.py" 7 > "$X/fw/tone.a78"
python3 "$HERE/make_a78.py" --bin "$X/fw/highscor.rom" > "$X/fw/hsc.a78"   # the same firmware as an A78
python3 -c "import os; open('$X/fw/random.sav','wb').write(os.urandom(2048))"
cd "$X/fw"
echo "  No firmware file, HSC On (expect HSC_EN 0):"
"$WORK/obj_load/vtb" +image=tone.a78 +audf=7 +hsc_on | grep -E "HSC_EN|TONE"
echo "  Both files loaded (expect 0 bytes differ, HSC_EN 1, save intact):"
"$WORK/obj_load/vtb" +image=tone.a78 +audf=7 +hsc_on +hscfw=highscor.rom +arfw=supercharger.bin +save=random.sav \
	| grep -E "FIRMWARE|HSC_EN|TONE|SAVE after"
echo "  HSC firmware as hsc.a78 (expect its header skipped: 0 bytes differ from the payload, HSC_EN 1):"
"$WORK/obj_load/vtb" +image=tone.a78 +audf=7 +hsc_on +hscfw=hsc.a78 | grep -E "FIRMWARE|HSC_EN"
cd - >/dev/null

echo "-- Supercharger without the BIOS: the core's loader stub (POCKET_SUPERCHARGER)"
mkdir -p "$X/ar"; ln -sfn "$WORK/rtl" "$X/ar/rtl"
cd "$X/ar"
python3 "$HERE/ar_test.py" multi > ar_multi.bin
python3 "$HERE/ar_test.py" tape > ar_tape.bin
python3 "$HERE/ar_test.py" full > ar_full.bin
echo "  Full 24-page load (expect magenta \$54 / AUDF0 5 within about 0.1 s, 0 RAM bytes differ):"
"$WORK/obj_load/vtb" +image=ar_full.bin +arprobe +wav=400 +ardump=ram.bin | grep -E "^AR "
python3 "$HERE/ar_test.py" check ram.bin ar_full.bin
echo "  Multiload (expect red \$44 / AUDF0 7, then at about 1 s the stub's clear and green \$c4 / AUDF0 14):"
"$WORK/obj_load/vtb" +image=ar_multi.bin +arprobe +wav=1500 | grep -E "^AR "
echo "  Two loads numbered 0, reset after the first (expect blue \$84 / AUDF0 3, then after the reset yellow \$1e / AUDF0 20):"
"$WORK/obj_load/vtb" +image=ar_tape.bin +arprobe +wav=1000 +resetat=500 | grep -E "^AR |RESET"
if [ "${AR_TAPE:-0}" = 1 ]; then
	echo "  With the BIOS, from tape: full load (expect 0 RAM bytes differ) and multiload (expect red, then green):"
	"$WORK/obj_load/vtb" +image=ar_full.bin +arfw="$X/fw/supercharger.bin" +arprobe +wav=22000 +ardump=ram_tape.bin | grep -E "^AR "
	python3 "$HERE/ar_test.py" check ram_tape.bin ar_full.bin
	"$WORK/obj_load/vtb" +image=ar_multi.bin +arfw="$X/fw/supercharger.bin" +arprobe +wav=12000 | grep -E "^AR "
fi
cd - >/dev/null
