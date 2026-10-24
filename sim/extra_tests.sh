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
#   cartram      2600 cartridge RAM on every RAM mapper, Flicker Blend off and
#                on, the Supercharger and a 7800 RAM cart, through
#                tb_cartram's +cartram monitor (cartram2600_test.py), and
#                the directed s19 run; first, as it needs no clone (with
#                AR_TAPE=1 it fetches the Supercharger BIOS first and adds
#                the tape load with +cartram, artape: about an hour more)
# FP=1 writes each run's per-frame fingerprint to $WORK/fp/extra_<case>.csv
# (tb_load +fp), and the cartridge-RAM runs' to $WORK/fp/cartram_<case>.csv,
# for comparing two builds frame by frame. A bench that exits non-zero
# prints "SIMULATOR EXIT N: <command>" (its "%Fatal" line may have gone to a
# grep). The checker sim/check/extra_tests_check.py turns this script's
# output into one exit code (with --ref, the reference build's log, for the
# POKEY and DLI statistics).
#
# In pieces (2026-10-23: a whole run with AR_TAPE=1 took 5.1-5.2 h on the
# DARIA build and 3.7-3.9 h on the plain one, about 80 % of it the three tape
# loads; docs/ENVIRONMENT.md 6 has the table):
#   EXTRA_ONLY=S[,S...]
#        run only those sections, each exactly as in a whole run: cartram
#        multisprite pokey450 pokey4000 dli savekey firmware supercharger (an
#        unknown name: exit 2). The header line then ends ", EXTRA_ONLY ...";
#        extra_tests_check.py fails such a log for the sections left out: a
#        quick look, not a verdict.
#   EXTRA_JOBS=N
#        (default 1) the sections as up to N processes at once, longest
#        first, each under EXTRA_SLOT (a command prefix that runs one
#        simulation in one of the caller's slots, e.g. "flock FILE"; empty:
#        none). The tools and firmware are fetched and built first; the
#        pieces' logs (in $X/pieces) are then printed in the serial order,
#        so the output is a serial run's and extra_tests_check.py gives the
#        same verdict. Exit 1 when a piece exited non-zero (a serial run
#        stops at that section instead). Every piece is a simulation: do not
#        run EXTRA_JOBS>1 inside one slot, and EXTRA_JOBS>1 with no
#        EXTRA_SLOT is refused (exit 2). On the owner's VM use
#        EXTRA_SLOT=~/daria_work/bin/simslot; "flock FILE" with
#        one FILE runs the pieces one at a time. With AR_TAPE=1 and N=3 a build
#        takes about as long as its Supercharger section [estimated: 2.5 h
#        on the DARIA build, 1.9 h on the plain one].
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
X="$WORK/extra"
mkdir -p "$X"
[ -x "$WORK/obj_load/vtb" ] || { echo "run ./run_sim.sh first"; exit 1; }
SECTIONS="cartram multisprite pokey450 pokey4000 dli savekey firmware supercharger"
TOOLSECS="multisprite pokey450 pokey4000 dli savekey"   # these need the dasm and 7800basic clones
EXTRA_ONLY="${EXTRA_ONLY:-}"; EXTRA_ONLY="${EXTRA_ONLY//,/ }"
for s in $EXTRA_ONLY; do
	case " $SECTIONS " in *" $s "*) ;; *) echo "extra_tests.sh: unknown section '$s' in EXTRA_ONLY (sections: $SECTIONS)" >&2; exit 2 ;; esac
done
if [ "${EXTRA_JOBS:-1}" -gt 1 ] && [ -z "${EXTRA_PIECE:-}" ] && [ -z "${EXTRA_SLOT:-}" ]; then
	echo "extra_tests.sh: EXTRA_JOBS=$EXTRA_JOBS needs EXTRA_SLOT, a command prefix that holds one simulation slot (on the owner's VM, EXTRA_SLOT=~/daria_work/bin/simslot); without it every piece runs outside a slot" >&2
	exit 2
fi
want() { [ -z "$EXTRA_ONLY" ] || case " $EXTRA_ONLY " in *" $1 "*) true ;; *) false ;; esac; }
want_tools() { local s; for s in $TOOLSECS; do want "$s" && return 0; done; return 1; }
fp() { [ "${FP:-0}" = 1 ] && printf '%s' "+fp=$WORK/fp/extra_$1.csv"; true; }
[ "${FP:-0}" = 1 ] && mkdir -p "$WORK/fp"
# Every bench run goes through sim (as in run_sim.sh): a pipe into grep drops
# the bench's exit status and its "%Fatal" line, so sim prints "SIMULATOR
# EXIT N" past the pipe, on the script's stdout (descriptor 3).
exec 3>&1
sim() { local rc=0; "$@" || rc=$?; [ "$rc" = 0 ] || echo "SIMULATOR EXIT $rc: $*" >&3; return 0; }
# The firmware files (not in this repository; MiSTer's copies are fetched at
# test time, as a user would supply them).
UP="https://raw.githubusercontent.com/MiSTer-unstable-nightlies/Atari7800_MiSTer/$(cat "$HERE/../src/fpga/mister/UPSTREAM_COMMIT")/rtl"
fetch_ar() {
	mkdir -p "$X/fw"
	# written whole, then renamed: a piece running at the same time never
	# reads a half-written file
	[ -s "$X/fw/supercharger.bin" ] || { curl -fsSL "$UP/ar.hex" | python3 "$HERE/../tools/hex2bin.py" > "$X/fw/supercharger.bin.$$" \
		&& mv -f "$X/fw/supercharger.bin.$$" "$X/fw/supercharger.bin"; }
}

# The two tool clones are pinned, so every run builds the same carts. dasm
# at c361b82 (2026-07-08). 7800basic at 4b17165 (2025-11-02), the newest
# commit whose 7800basic.native.sh runs the compiler itself: from 398ac79
# (2025-11-04) to its head of 2026-10-10 (e7c18d2) it runs it under
# valgrind, and without valgrind installed every compile fails (the script
# still exits 0). A cached clone at another commit is built again.
DASM_REF=c361b8201320e66c2452c58b248030b34be38495
B78_REF=4b17165b263718d079714303b1f11a536e2e01dd
fetch_at() {   # fetch_at <dir> <url> <commit>: that commit alone, no history
	rm -rf "$1"; git init -q "$1"
	git -C "$1" fetch -q --depth 1 "$2" "$3" && git -C "$1" checkout -q FETCH_HEAD
}
at_ref() { [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" = "$2" ]; }
tools() {   # the clones at their commits, built; sets TOOLS_LINE and PATH
	if [ ! -x "$X/dasm/bin/dasm" ] || ! at_ref "$X/dasm" "$DASM_REF"; then
		fetch_at "$X/dasm" https://github.com/dasm-assembler/dasm "$DASM_REF"
		make -C "$X/dasm" -j4 > "$X/dasm.make.log" 2>&1 \
			|| { echo "dasm: make failed (last lines of $X/dasm.make.log):"; tail -5 "$X/dasm.make.log"; exit 1; }
	fi
	# 7800basic's makefile is serial only: its 7800preprocess and 7800optimize
	# rules both write and delete lex.yy.c in the source directory, so with -j
	# they can compile each other's half-written file and fail (e7c18d2 did
	# with -j4). Its output goes to a log, so that a failure shows; a partial
	# build is removed, so the next run builds again.
	if [ ! -x "$X/7800basic/7800preprocess" ] || ! at_ref "$X/7800basic" "$B78_REF"; then
		fetch_at "$X/7800basic" https://github.com/7800-devtools/7800basic "$B78_REF"
		make -C "$X/7800basic" all > "$X/7800basic.make.log" 2>&1 \
			|| { echo "7800basic: make failed (last lines of $X/7800basic.make.log):"; tail -5 "$X/7800basic.make.log"; rm -rf "$X/7800basic"; exit 1; }
	fi
	TOOLS_LINE="-- tools: dasm $(git -C "$X/dasm" rev-parse --short HEAD 2>/dev/null), 7800basic $(git -C "$X/7800basic" rev-parse --short HEAD 2>/dev/null)"
	export PATH="$X/dasm/bin:$X/7800basic:$PATH" bas7800dir="$X/7800basic"
}

[ -n "${EXTRA_PIECE:-}" ] || echo "-- extra_tests.sh: WORK $WORK, obj_load/vtb md5 $(md5sum < "$WORK/obj_load/vtb" | cut -d' ' -f1), AR_TAPE ${AR_TAPE:-0}${EXTRA_ONLY:+, EXTRA_ONLY $EXTRA_ONLY}"

# EXTRA_JOBS>1: each section is a piece, this script again with EXTRA_ONLY=it and
# EXTRA_PIECE=1 (no header, no tools line, nothing fetched or built that
# another piece uses), its log in $X/pieces; the logs are then printed in the
# serial order, the tools line where a serial run prints it.
if [ "${EXTRA_JOBS:-1}" -gt 1 ] && [ -z "${EXTRA_PIECE:-}" ]; then
	if want_tools; then tools; fi
	if want firmware || { [ "${AR_TAPE:-0}" = 1 ] && { want cartram || want supercharger; }; }; then fetch_ar; fi
	P="$X/pieces"; rm -rf "$P"; mkdir -p "$P"
	for s in supercharger cartram pokey450 pokey4000 savekey dli firmware multisprite; do
		want "$s" || continue
		while [ "$(jobs -rp | wc -l)" -ge "$EXTRA_JOBS" ]; do wait -n || true; done
		( set +e; EXTRA_ONLY="$s" EXTRA_PIECE=1 EXTRA_JOBS=1 $EXTRA_SLOT bash "$HERE/extra_tests.sh" > "$P/$s.out" 2>&1; echo $? > "$P/$s.rc" ) &
	done
	wait
	rc=0; told=0
	for s in $SECTIONS; do
		want "$s" || continue
		case " $TOOLSECS " in *" $s "*) [ $told = 1 ] || echo "$TOOLS_LINE"; told=1 ;; esac
		cat "$P/$s.out"
		[ "$(cat "$P/$s.rc" 2>/dev/null)" = 0 ] || rc=1
	done
	exit $rc
fi

# 2600 cartridge RAM (docs/DARIA_CORE.md, "Fix B"; docs/daria_step7/plan.md
# 1.2 row 6): tb_cartram (tb_load + the +cartram monitor) is built in WORK
# from run_sim.sh's source list when missing. Every RAM mapper's test image
# with Flicker Blend off and on, the Supercharger's full load and multiload
# and a 7800 RAM cart: no fail code, 0 wrong bytes, 0 reads without a fresh
# access, writes = strobes, shadow = SRAM, the per-image read and write
# counts, and each build's latency buckets (cartram2600_test.py's header).
# Then the directed s19 run: another client's access placed at every
# clk_sdram edge of the 6507 cycle in turn.
if want cartram; then
echo "-- 2600 cartridge RAM (cartram2600_test.py: 8 RAM mappers x Flicker Blend, Supercharger, 7800 RAM cart, s19 sweep)"
# (re)built unless it is newer than run_sim.sh's own tb_load build, which
# run_sim.sh makes afresh on every run: a tb_cartram older than that may be
# of other RTL
[ -x "$WORK/obj_cartram/vtb" ] && [ ! "$WORK/obj_load/vtb" -nt "$WORK/obj_cartram/vtb" ] \
	&& [ ! "$HERE/tb_cartram.sv" -nt "$WORK/obj_cartram/vtb" ] \
	|| WORK="$WORK" BUILD_TOP=tb_cartram VL_JOBS="${VL_JOBS:-2}" bash "$HERE/run_sim.sh" | sed 's/^/  /'
CT_FP=(); [ "${FP:-0}" = 1 ] && CT_FP=(--fp)
CT_TAPE=()
if [ "${AR_TAPE:-0}" = 1 ]; then
	# the Supercharger's full load from tape, through the BIOS, with +cartram
	fetch_ar
	CT_TAPE=(--arfw "$X/fw/supercharger.bin")
fi
python3 "$HERE/cartram2600_test.py" matrix --work "$WORK" "${CT_FP[@]}" "${CT_TAPE[@]}" || true
python3 "$HERE/cartram2600_test.py" s19 --work "$WORK" "${CT_FP[@]}" || true
fi

if want_tools; then
	tools
	[ -n "${EXTRA_PIECE:-}" ] || echo "$TOOLS_LINE"
fi

# 7800basic.native.sh exits 0 even when the compile fails, so a cart counts
# as built only when its .a78 is there; otherwise the compile's output (kept
# in <name>/build.log) is shown and the script stops.
build() {   # build <name> <sample> <sed expression or "">
	rm -rf "$X/$1"; cp -r "$X/7800basic/samples/$2" "$X/$1"; rm -f "$X/$1/$2.bas.a78"
	[ -n "$3" ] && sed -i "$3" "$X/$1/$2.bas"
	(cd "$X/$1" && sh "$X/7800basic/7800basic.native.sh" "$2.bas" > build.log 2>&1) || true
	[ -s "$X/$1/$2.bas.a78" ] || { echo "7800basic: $2.bas did not build for $1 (last lines of $X/$1/build.log):"; tail -15 "$X/$1/build.log"; exit 1; }
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

if want multisprite; then
echo "-- multisprite (holey DMA)"
ms="$X/multisprite"; build multisprite multisprite ""
(cd "$ms" && sim "$WORK/obj_load/vtb" +image=multisprite.bas.a78 +audf=0 +dump=3 $(fp multisprite) | grep LOAD)
python3 - "$ms" <<'PY'
import sys
from PIL import Image
for i in range(1, 3):
    im = Image.open(f"{sys.argv[1]}/frame_{i:03d}.ppm")
    im.resize((im.size[0] * 2, im.size[1] * 2), Image.NEAREST).save(f"{sys.argv[1]}/multisprite_{i}.png")
    print(f"  wrote {sys.argv[1]}/multisprite_{i}.png")
PY
# The header's rule, as a check: frame 1 is the background, frame 2 has the
# 24 sprites (sim/check/multisprite_check.py prints MULTISPRITE pass or FAIL).
python3 "$HERE/check/multisprite_check.py" "$ms" | sed -n 's/^\(MULTISPRITE.*\|  FAIL.*\)$/\1/p'
fi

if want pokey450; then
echo "-- POKEY at \$450"
build pokey450 pokey 's/ set pokeysupport on/ set pokeysupport $450/'
(cd "$X/pokey450" && sim "$WORK/obj_load/vtb" +image=pokey.bas.a78 +wav=2000 $(fp pokey450) | grep -E "LOAD")
audio_stats "$X/pokey450"
fi

if want pokey4000; then
echo "-- POKEY at \$4000"
build pokey4000 pokey 's/ set pokeysupport on/ set pokeysupport $4000/'
(cd "$X/pokey4000" && sim "$WORK/obj_load/vtb" +image=pokey.bas.a78 +wav=2000 $(fp pokey4000) | grep -E "LOAD")
audio_stats "$X/pokey4000"
fi

if want dli; then
echo "-- DLI + WSYNC + POKEY sweep at \$4000 (Ballblazer's siren pattern)"
mkdir -p "$X/dli"; ln -sfn "$WORK/rtl" "$X/dli/rtl"
dasm "$HERE/dli_pokey_test.asm" -f3 -o"$X/dli/dli.bin" >/dev/null
python3 "$HERE/make_a78.py" --bin "$X/dli/dli.bin" --type 0x0001 > "$X/dli/dli.a78"
(cd "$X/dli" && sim "$WORK/obj_load/vtb" +image=dli.a78 +wav=1000 $(fp dli) | grep -E "LOAD|PROBE")
echo "  expect: 60 NMIs, main loop writes in the hundreds of thousands, 61 AUDF1 writes"
audio_stats "$X/dli"
fi

if want savekey; then
echo "-- SaveKey (24LC256 on port 2) and its save slot"
mkdir -p "$X/savekey"; ln -sfn "$WORK/rtl" "$X/savekey/rtl"
dasm "$HERE/savekey_test.asm" -f3 -I"$X/7800basic/includes" -o"$X/savekey/sk.bin" >/dev/null
python3 "$HERE/make_a78.py" --bin "$X/savekey/sk.bin" --save 2 > "$X/savekey/sk_auto.a78"
python3 "$HERE/make_a78.py" --bin "$X/savekey/sk.bin" --save 3 > "$X/savekey/sk_both.a78"
python3 "$HERE/make_a78.py" --bin "$X/savekey/sk.bin" > "$X/savekey/sk_plain.a78"
# A fixed save file (it was os.urandom's: now and then a random byte already
# held what the cart writes, and the round trip below showed 7 differences,
# not 8): pseudo-random, with the 8 bytes the cart writes at $1234 changed.
python3 -c "import random; d = bytearray(random.Random(7800).randbytes(32768)); w = bytes.fromhex('a55a0102807fff00'); d[0x1234:0x123c] = bytes(b ^ 0xff for b in w); open('$X/savekey/random.bin','wb').write(d)"
cd "$X/savekey"
echo "  Auto, header declares a SaveKey (expect pass tone ~1962 Hz, bytes match):"
sim "$WORK/obj_load/vtb" +image=sk_auto.a78 +audf=7 +sk_auto +skcheck $(fp sk_auto) | grep -E "TONE|SAVEKEY"
echo "  Auto, header declares HSC and SaveKey (byte 58 = 3, as Triple Punch; expect pass tone):"
sim "$WORK/obj_load/vtb" +image=sk_both.a78 +audf=7 +sk_auto +skcheck $(fp sk_both) | grep -E "TONE|SAVEKEY"
echo "  Auto, header declares none (expect fail tone ~490 Hz):"
sim "$WORK/obj_load/vtb" +image=sk_plain.a78 +audf=31 +sk_auto $(fp sk_plain) | grep TONE
echo "  32 KiB save round trip, APF read protocol (expect exactly the 8 bytes the cart wrote to differ):"
sim "$WORK/obj_load/vtb" +image=sk_plain.a78 +audf=7 +sk_on +sksave=random.bin $(fp sk_roundtrip) | grep -E "SAVEKEY"
cd - >/dev/null
fi

if want firmware; then
echo "-- Firmware slots: HSC firmware and Supercharger BIOS (not in this repository;"
echo "   MiSTer's copies are fetched at test time, as a user would supply them)"
mkdir -p "$X/fw"; ln -sfn "$WORK/rtl" "$X/fw/rtl"
[ -s "$X/fw/highscor.rom" ] || curl -fsSL "$UP/mem4.hex" | python3 "$HERE/../tools/hex2bin.py" > "$X/fw/highscor.rom"
fetch_ar
python3 "$HERE/make_a78.py" 7 > "$X/fw/tone.a78"
python3 "$HERE/make_a78.py" --bin "$X/fw/highscor.rom" > "$X/fw/hsc.a78"   # the same firmware as an A78
python3 -c "import random; open('$X/fw/random.sav','wb').write(random.Random(2048).randbytes(2048))"
cd "$X/fw"
echo "  No firmware file, HSC On (expect HSC_EN 0):"
sim "$WORK/obj_load/vtb" +image=tone.a78 +audf=7 +hsc_on $(fp fw_none) | grep -E "HSC_EN|TONE"
echo "  Both files loaded (expect 0 bytes differ, HSC_EN 1, save intact):"
sim "$WORK/obj_load/vtb" +image=tone.a78 +audf=7 +hsc_on +hscfw=highscor.rom +arfw=supercharger.bin +save=random.sav $(fp fw_both) \
	| grep -E "FIRMWARE|HSC_EN|TONE|SAVE after"
echo "  HSC firmware as hsc.a78 (expect its header skipped: 0 bytes differ from the payload, HSC_EN 1):"
sim "$WORK/obj_load/vtb" +image=tone.a78 +audf=7 +hsc_on +hscfw=hsc.a78 $(fp fw_a78) | grep -E "FIRMWARE|HSC_EN"
cd - >/dev/null
fi

if want supercharger; then
echo "-- Supercharger without the BIOS: the core's loader stub (POCKET_SUPERCHARGER)"
mkdir -p "$X/ar"; ln -sfn "$WORK/rtl" "$X/ar/rtl"
cd "$X/ar"
python3 "$HERE/ar_test.py" multi > ar_multi.bin
python3 "$HERE/ar_test.py" tape > ar_tape.bin
python3 "$HERE/ar_test.py" full > ar_full.bin
echo "  Full 24-page load (expect magenta \$54 / AUDF0 5 within about 0.1 s, 0 RAM bytes differ):"
sim "$WORK/obj_load/vtb" +image=ar_full.bin +arprobe +wav=400 +ardump=ram.bin $(fp ar_full) | grep -E "^AR "
python3 "$HERE/ar_test.py" check ram.bin ar_full.bin || echo "ARCHECK FAIL"
echo "  Multiload (expect red \$44 / AUDF0 7, then at about 1 s the stub's clear and green \$c4 / AUDF0 14):"
sim "$WORK/obj_load/vtb" +image=ar_multi.bin +arprobe +wav=1500 $(fp ar_multi) | grep -E "^AR "
echo "  Two loads numbered 0, reset after the first (expect blue \$84 / AUDF0 3, then after the reset yellow \$1e / AUDF0 20):"
sim "$WORK/obj_load/vtb" +image=ar_tape.bin +arprobe +wav=1000 +resetat=500 $(fp ar_tape) | grep -E "^AR |RESET"
if [ "${AR_TAPE:-0}" = 1 ]; then
	fetch_ar
	echo "  With the BIOS, from tape: full load (expect 0 RAM bytes differ) and multiload (expect red, then green):"
	sim "$WORK/obj_load/vtb" +image=ar_full.bin +arfw="$X/fw/supercharger.bin" +arprobe +wav=22000 +ardump=ram_tape.bin $(fp ar_tape_full) | grep -E "^AR "
	python3 "$HERE/ar_test.py" check ram_tape.bin ar_full.bin || echo "ARCHECK FAIL"
	sim "$WORK/obj_load/vtb" +image=ar_multi.bin +arfw="$X/fw/supercharger.bin" +arprobe +wav=12000 $(fp ar_tape_multi) | grep -E "^AR "
fi
cd - >/dev/null
fi
