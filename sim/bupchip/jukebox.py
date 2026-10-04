#!/usr/bin/env python3
"""Build a BupChip jukebox: a game-free Souper cartridge that plays any song
of an ARSC block on demand, to test a BupChip on hardware without playing
through the game.

  jukebox.py OUT.a78 --arsc GAME.a78|BLOCK [--cdf FoxBox.cdf]

--arsc takes the block from a Souper .a78 that carries one (the bytes from
128 + the header's ROM size, as make_arsc.py appends it) or a bare block
(make_synth_arsc.py --arsc). --cdf names the songs on screen from the
CORETONE section of a FoxBox.cdf (docs/BUPCHIP.md); without it the screen
shows numbers only. The output carries the block, so a jukebox built from a
game's music stays out of the repository, as the game does.

Controls, joystick 1:
  left / right   previous / next song, 0-31 (held: repeats)
  fire (A or B)  play the selected song: command $80 | n
  down           stop: command $00
  up             next song, and play it

Run it with Skip BIOS on (the default): the cartridge carries no BIOS
signature. The screen shows the song number in large digits, the song's name
and command byte, and the last command sent. The top-left corner is left
blank for the core's BupChip status overlay (BUP_DEBUG builds).

The image is laid out as souper_test.py's: an A78 header with cartridge type
0x1000 (the Souper mapper), a 512 KiB ROM whose last 16 KiB bank is the one
the mapper fixes at $C000-$FFFF, then the block. The 6502 program there locks
the console in 7800 mode, shows a MARIA display (320A text, 8-line zones; the
display lists are copied to RAM at $1800 so the song can be swapped in during
vertical blank), reads the joystick once a frame and sends each command as
the game does: the byte written twice to $8007, at most one command a frame.

sim/bupchip/run_jukebox.sh runs it in the whole-core simulation.

SPDX-License-Identifier: MIT
"""
import argparse
import os
import re
import struct
import sys

# ---------------------------------------------------------------- assembler
# A two-pass assembler for the subset the program below uses (dasm syntax:
# labels end in ':', 'NAME = expr', '<' and '>' for the low and high byte).
OPS = {}
for _m, _modes in {
    "ADC": "imm 69 zp 65 zpx 75 abs 6D absx 7D absy 79 indx 61 indy 71",
    "AND": "imm 29 zp 25 zpx 35 abs 2D absx 3D absy 39 indx 21 indy 31",
    "ASL": "acc 0A zp 06 zpx 16 abs 0E absx 1E",
    "BIT": "zp 24 abs 2C",
    "CMP": "imm C9 zp C5 zpx D5 abs CD absx DD absy D9 indx C1 indy D1",
    "CPX": "imm E0 zp E4 abs EC", "CPY": "imm C0 zp C4 abs CC",
    "DEC": "zp C6 zpx D6 abs CE absx DE",
    "EOR": "imm 49 zp 45 zpx 55 abs 4D absx 5D absy 59 indx 41 indy 51",
    "INC": "zp E6 zpx F6 abs EE absx FE",
    "JMP": "abs 4C ind 6C", "JSR": "abs 20",
    "LDA": "imm A9 zp A5 zpx B5 abs AD absx BD absy B9 indx A1 indy B1",
    "LDX": "imm A2 zp A6 zpy B6 abs AE absy BE",
    "LDY": "imm A0 zp A4 zpx B4 abs AC absx BC",
    "LSR": "acc 4A zp 46 zpx 56 abs 4E absx 5E",
    "ORA": "imm 09 zp 05 zpx 15 abs 0D absx 1D absy 19 indx 01 indy 11",
    "ROL": "acc 2A zp 26 zpx 36 abs 2E absx 3E",
    "ROR": "acc 6A zp 66 zpx 76 abs 6E absx 7E",
    "SBC": "imm E9 zp E5 zpx F5 abs ED absx FD absy F9 indx E1 indy F1",
    "STA": "zp 85 zpx 95 abs 8D absx 9D absy 99 indx 81 indy 91",
    "STX": "zp 86 zpy 96 abs 8E", "STY": "zp 84 zpx 94 abs 8C",
    **{b: "rel " + o for b, o in zip("BPL BMI BVC BVS BCC BCS BNE BEQ".split(),
                                    "10 30 50 70 90 B0 D0 F0".split())},
    **{i: "imp " + o for i, o in zip(
        "BRK CLC CLD CLI CLV DEX DEY INX INY NOP PHA PHP PLA PLP RTI RTS SEC SED SEI "
        "TAX TAY TSX TXA TXS TYA".split(),
        "00 18 D8 58 B8 CA 88 E8 C8 EA 48 08 68 28 40 60 38 F8 78 AA A8 BA 8A 9A 98".split())},
}.items():
    _f = _modes.split()
    OPS[_m] = {_f[i]: int(_f[i + 1], 16) for i in range(0, len(_f), 2)}
SIZE = dict(imp=1, acc=1, imm=2, zp=2, zpx=2, zpy=2, indx=2, indy=2, rel=2, abs=3, absx=3, absy=3, ind=3)


def assemble(src, org, syms):
    """Assemble src at org. syms holds the symbols defined outside (data
    addresses); labels and constants are added to it. Returns the bytes."""
    def value(expr, final):
        e = expr.strip()
        part = None
        if e[:1] in "<>":
            part, e = e[0], e[1:]
        e = re.sub(r"\$([0-9A-Fa-f]+)", r"0x\1", e)
        e = re.sub(r"%([01]+)", r"0b\1", e)
        try:
            v = eval(e, {"__builtins__": {}}, syms)
        except NameError:
            if final:
                raise
            return None
        return v & 0xFF if part == "<" else v >> 8 & 0xFF if part == ">" else v

    lines = []
    for n, text in enumerate(src.splitlines(), 1):
        text = text.split(";")[0].strip()
        m = re.match(r"(\w+):\s*(.*)$", text)
        if m:
            lines.append((n, "label", m.group(1), None))
            text = m.group(2)
        if not text:
            continue
        m = re.match(r"(\w+)\s*=\s*(.+)$", text)
        if m:
            lines.append((n, "equ", m.group(1), m.group(2)))
        else:
            mn, _, arg = text.partition(" ")
            lines.append((n, "op", mn.upper(), arg.strip()))

    def mode_of(mn, arg, final, decided):
        modes = OPS[mn]
        a = arg.replace(" ", "")
        if not a or a.upper() == "A":
            return ("acc" if "acc" in modes else "imp"), None
        if a[0] == "#":
            return "imm", a[1:]
        if "rel" in modes:
            return "rel", a
        m = re.match(r"\((.+),[xX]\)$", a)
        if m:
            return "indx", m.group(1)
        m = re.match(r"\((.+)\),[yY]$", a)
        if m:
            return "indy", m.group(1)
        if a[0] == "(" and a[-1] == ")" and "ind" in modes:
            return "ind", a[1:-1]
        idx = ""
        m = re.match(r"(.+),([xXyY])$", a)
        if m:
            a, idx = m.group(1), m.group(2).lower()
        if decided is None:
            v = value(a, final)
            decided = v is not None and v < 0x100 and ("zp" + idx) in modes
        return ("zp" if decided else "abs") + idx, a

    zp_choice = {}
    for final in (False, True):
        pc, out = org, bytearray()
        for k, (n, kind, name, arg) in enumerate(lines):
            if kind == "label":
                if not final and name in syms:
                    sys.exit(f"line {n}: {name} defined twice")
                syms[name] = pc
            elif kind == "equ":
                syms[name] = value(arg, True)
            else:
                if name not in OPS:
                    sys.exit(f"line {n}: unknown instruction {name}")
                mode, expr = mode_of(name, arg, final, zp_choice.get(k))
                zp_choice[k] = mode.startswith("zp")
                if mode not in OPS[name]:
                    sys.exit(f"line {n}: {name} has no {mode} mode")
                out.append(OPS[name][mode])
                if final and expr is not None:
                    v = value(expr, True)
                    if mode == "rel":
                        v -= pc + 2
                        if not -128 <= v < 128:
                            sys.exit(f"line {n}: branch out of range")
                        out.append(v & 0xFF)
                    elif SIZE[mode] == 2:
                        if not -128 <= v < 256:
                            sys.exit(f"line {n}: {expr} does not fit a byte")
                        out.append(v & 0xFF)
                    else:
                        out += struct.pack("<H", v & 0xFFFF)
                else:
                    out += bytes(SIZE[mode] - 1)
                pc += SIZE[mode]
    return bytes(out)


# ---------------------------------------------------------------- font
# 5 x 7 glyphs, one hex byte per row from the top, bit 4 the left pixel.
FONT = {
    " ": "00 00 00 00 00 00 00", "!": "04 04 04 04 04 00 04", '"': "0A 0A 00 00 00 00 00",
    "#": "0A 0A 1F 0A 1F 0A 0A", "$": "04 0F 14 0E 05 1E 04", "%": "18 19 02 04 08 13 03",
    "&": "0C 12 14 08 15 12 0D", "'": "04 04 08 00 00 00 00", "(": "02 04 08 08 08 04 02",
    ")": "08 04 02 02 02 04 08", "*": "00 04 15 0E 15 04 00", "+": "00 04 04 1F 04 04 00",
    ",": "00 00 00 00 0C 04 08", "-": "00 00 00 1F 00 00 00", ".": "00 00 00 00 00 0C 0C",
    "/": "00 01 02 04 08 10 00", "0": "0E 11 13 15 19 11 0E", "1": "04 0C 04 04 04 04 0E",
    "2": "0E 11 01 02 04 08 1F", "3": "1F 02 04 02 01 11 0E", "4": "02 06 0A 12 1F 02 02",
    "5": "1F 10 1E 01 01 11 0E", "6": "06 08 10 1E 11 11 0E", "7": "1F 01 02 04 08 08 08",
    "8": "0E 11 11 0E 11 11 0E", "9": "0E 11 11 0F 01 02 0C", ":": "00 0C 0C 00 0C 0C 00",
    ";": "00 0C 0C 00 0C 04 08", "<": "02 04 08 10 08 04 02", "=": "00 00 1F 00 1F 00 00",
    ">": "08 04 02 01 02 04 08", "?": "0E 11 01 02 04 00 04", "@": "0E 11 01 0D 15 15 0E",
    "A": "0E 11 11 11 1F 11 11", "B": "1E 11 11 1E 11 11 1E", "C": "0E 11 10 10 10 11 0E",
    "D": "1C 12 11 11 11 12 1C", "E": "1F 10 10 1E 10 10 1F", "F": "1F 10 10 1E 10 10 10",
    "G": "0E 11 10 17 11 11 0F", "H": "11 11 11 1F 11 11 11", "I": "0E 04 04 04 04 04 0E",
    "J": "07 02 02 02 02 12 0C", "K": "11 12 14 18 14 12 11", "L": "10 10 10 10 10 10 1F",
    "M": "11 1B 15 15 11 11 11", "N": "11 11 19 15 13 11 11", "O": "0E 11 11 11 11 11 0E",
    "P": "1E 11 11 1E 10 10 10", "Q": "0E 11 11 11 15 12 0D", "R": "1E 11 11 1E 14 12 11",
    "S": "0F 10 10 0E 01 01 1E", "T": "1F 04 04 04 04 04 04", "U": "11 11 11 11 11 11 0E",
    "V": "11 11 11 11 11 0A 04", "W": "11 11 11 15 15 15 0A", "X": "11 11 0A 04 0A 11 11",
    "Y": "11 11 11 0A 04 04 04", "Z": "1F 01 02 04 08 10 1F", "[": "0E 08 08 08 08 08 0E",
    "\\": "00 10 08 04 02 01 00", "]": "0E 02 02 02 02 02 0E", "^": "04 0A 11 00 00 00 00",
    "_": "00 00 00 00 00 00 1F",
}
BIG = "0E 11 11 11 11 11 0E"     # the big digits' 0, without the small font's slash
DOT = 0x7F                        # the big digits' dot: 7 x 7 lit, a gap right and below

# ---------------------------------------------------------------- layout
FIXED, DATA, CODE = 0xC000, 0xD000, 0xF000   # font, tables, program (fixed bank)
CHBASE = FIXED >> 8
RAM = 0x1800                      # display list list and display lists
DIGIT_GAP = 4                     # big digits: the gap between them, in hpos units
# Colours: NTSC hue << 4 | luminance. 320A shows each palette's colour 2.
BACKGROUND = 0x00
PAL = {"hint": (0, 0x0C), "title": (1, 0x1E), "digits": (2, 0x0F), "name": (3, 0x9C),
       "info": (4, 0x08), "status": (5, 0xCC)}

PROGRAM = r"""
INPTCTRL = $01
INPT0    = $08
INPT1    = $09
INPT4    = $0C
BACKGRND = $20
MSTAT    = $28
DPPH     = $2C
DPPL     = $30
CHBASE   = $34
OFFSET   = $38
CTRL     = $3C
SWCHA    = $280
CTLSWA   = $281
AUDCMD   = $8007        ; Souper: the BupChip command, written twice

song     = $80          ; the selected song, 0-31
joy      = $81          ; this frame: 7 right, 6 left, 5 down, 4 up, 0 fire
prev     = $82
newp     = $83          ; pressed since the last frame
held     = $84          ; frames left or right has been held
ti       = $85          ; big digit table indexes, tens and ones
oi       = $86

reset:
        sei
        cld
        lda #$07            ; lock 7800 mode, MARIA on, BIOS out
        sta INPTCTRL
        ldx #$FF
        txs
        lda #$60            ; MARIA DMA off while the lists are built
        sta CTRL
        lda #0
        sta OFFSET
        sta CTLSWA          ; joystick port: all inputs
        ldx #$7F
clear:  sta $80,x
        dex
        bpl clear
        ldx #0
copy:   lda TEMPLATE,x      ; the display list list and lists, to RAM
        sta DLRAM,x
        lda TEMPLATE+$100,x
        sta DLRAM+$100,x
        inx
        bne copy
regs:   ldy REGTAB,x        ; colours, list pointer, character base
        bmi regsdone
        lda REGTAB+1,x
        sta $0000,y
        inx
        inx
        bne regs
regsdone:
        jsr show
vbon:   bit MSTAT           ; DMA on in vertical blank
        bpl vbon
        lda #CTRLON
        sta CTRL

main:
vis:    bit MSTAT           ; once a frame: wait for the picture,
        bmi vis
vbl:    bit MSTAT           ; then for vertical blank
        bpl vbl
        jsr input
        lda newp
        bpl notright        ; right: next song
        inc song
notright:
        asl
        bpl notleft         ; left: previous song
        dec song
notleft:
        lda song
        and #31
        sta song
        lda newp
        and #$20
        beq notdown
        lda #$00            ; down: stop
        jsr send
        lda #<STOPTXT
        sta STATUSDL
        lda #>STOPTXT
        sta STATUSDL+2
        jmp shown
notdown:
        lda newp
        and #$10
        beq notup
        lda song            ; up: next song, and play it
        clc
        adc #1
        and #31
        sta song
        jmp play
notup:
        lda newp
        and #$01
        beq shown
play:   lda song            ; fire: play
        ora #$80
        jsr send
        ldx song
        lda PLAYLO,x
        sta STATUSDL
        lda PLAYHI,x
        sta STATUSDL+2
shown:  jsr show
        jmp main

send:   sta AUDCMD          ; one command: the byte twice, as souper.v wants
        sta AUDCMD
        rts

input:  lda SWCHA
        eor #$FF
        and #$F0
        sta joy
        lda INPT4           ; fire: INPT4 low (one-button mode),
        eor #$80
        ora INPT0           ; or INPT0 / INPT1 high (two-button mode)
        ora INPT1
        bpl nofire
        inc joy
nofire: lda prev
        eor #$FF
        and joy
        sta newp
        lda joy
        sta prev
        and #$C0            ; left or right held: again after 24 frames,
        beq released        ; then every 6
        inc held
        lda held
        cmp #24
        bcc inputdone
        lda #18
        sta held
        lda joy
        and #$C0
        ora newp
        sta newp
        rts
released:
        sta held
inputdone:
        rts

show:   ldx song            ; the selected song's lines and digits
        lda NAMELO,x        ; a display list's first header: address low at
        sta NAMEDL          ; +0, high at +2
        lda NAMEHI,x
        sta NAMEDL+2
        lda INFOLO,x
        sta INFODL
        lda INFOHI,x
        sta INFODL+2
        lda TENS,x
        sta ti
        lda ONES,x
        sta oi
        ldx #0
showrow:
        ldy ti
        lda BIGLO,y
        sta BIGDL,x
        lda BIGHI,y
        sta BIGDL+2,x
        ldy oi
        lda BIGLO,y
        sta BIGDL+5,x
        lda BIGHI,y
        sta BIGDL+7,x
        inc ti
        inc oi
        txa
        clc
        adc #12             ; the next row's list: two headers and the end
        tax
        cpx #7*12
        bne showrow
        rts

nmi:    rti
"""


def text_entry(addr, width, pal, hpos):
    """A 5-byte display list header: 320A, indirect (character) mode."""
    assert 1 <= width <= 31 and 0 <= hpos < 160
    return bytes([addr & 0xFF, 0x60, addr >> 8, pal << 5 | (-width & 31), hpos])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("out")
    ap.add_argument("--arsc", required=True, help="a Souper .a78 with its ARSC block, or a bare block")
    ap.add_argument("--cdf", help="FoxBox.cdf: song names from its CORETONE section")
    a = ap.parse_args()

    f = open(a.arsc, "rb").read()
    if f[1:10] == b"ATARI7800":
        block = f[128 + int.from_bytes(f[49:53], "big"):]
    else:
        block = f
    if block[:4] != b"ARSC" or len(block) < 140:
        sys.exit(f"{a.arsc}: no ARSC block (expected at 128 + the header's ROM size, or a bare block)")
    offs = struct.unpack("<32I", block[12:140])
    songs = [o != 0 and block[o:o + 4] == b"CMUS" for o in offs]

    names, title = [""] * 32, ""
    if a.cdf:
        lines = [l.strip() for l in open(a.cdf, encoding="latin-1").read().splitlines()]
        if "CORETONE" not in lines:
            sys.exit(f"{a.cdf} has no CORETONE section")
        k = lines.index("CORETONE")
        title = lines[2] if k > 2 else ""
        for n, p in enumerate([l for l in lines[k + 3:] if l][:32]):
            names[n] = os.path.splitext(p.replace("\\", "/").split("/")[-1])[0]

    def txt(s, width=None):
        """s in the font's characters, centred in width."""
        s = "".join(c if c in FONT else "?" for c in s.upper())
        if width:
            s = s[:width].center(width)
        return s

    # Font: page CHBASE + k holds glyph row 7 - k (MARIA counts the zone's
    # line offset down to 0, and adds it to the high byte).
    rom = bytearray([0xFF] * 0x4000)                 # the fixed bank
    for k in range(8):
        page = bytearray(256)
        for ch, rows in FONT.items():
            r = 7 - k
            page[ord(ch)] = int(rows.split()[r], 16) << 2 if r < 7 else 0
        page[DOT] = 0xFE if k else 0
        rom[k * 256:(k + 1) * 256] = page

    # Data, from DATA on
    data = bytearray()
    syms = {}

    def put(b, name=None):
        at = DATA + len(data)
        data.extend(b.encode() if isinstance(b, str) else b)
        if name:
            syms[name] = at
        return at

    def table(name, addrs):
        put(bytes(x & 0xFF for x in addrs), name + "LO")
        put(bytes(x >> 8 for x in addrs), name + "HI")

    # The big digits: per digit, 7 rows of 5 characters (a dot or a blank);
    # BIGLO/BIGHI index them by digit * 8 + row
    bigrows = bytearray()
    for d in range(10):
        for row in (BIG if d == 0 else FONT[str(d)]).split():
            bigrows += bytes(DOT if int(row, 16) >> (4 - c) & 1 else 0x20 for c in range(5))
    big = put(bigrows)
    table("BIG", [big + (d * 7 + min(r, 6)) * 5 for d in range(10) for r in range(8)])
    put(bytes(n // 10 * 8 for n in range(32)), "TENS")
    put(bytes(n % 10 * 8 for n in range(32)), "ONES")

    W_NAME, W_INFO, W_STATUS = 24, 13, 22
    table("NAME", [put(txt(names[n] if songs[n] else "(NO SONG)" if offs[n] == 0 else "(NOT A SONG)",
                           W_NAME)) for n in range(32)])
    table("INFO", [put(txt(f"COMMAND ${0x80 | n:02X}", W_INFO)) for n in range(32)])
    table("PLAY", [put(txt(f"SENT ${0x80 | n:02X}: PLAY {n:02d}", W_STATUS)) for n in range(32)])
    put(txt("SENT $00: STOP", W_STATUS), "STOPTXT")
    count = sum(songs)

    # The display list list and the lists, as they sit in RAM: (lines, text
    # or big digits or None for blank, palette, the list's name for the
    # program). MARIA shows 243 lines (NTSC) or 292 (PAL); the 40 blank ones
    # at the top keep the text below the BUP_DEBUG status overlay (the
    # picture's top-left 96 x 32 pixels), with overscan on or off.
    def line(s, width=None):
        return txt(s, width), width or len(txt(s))
    zones = [(40, None),
             (8, line("BUPCHIP JUKEBOX"), "title"),
             (4, None),
             (8, line(f"{title}: {count} SONGS" if title else f"{count} SONGS IN THE BLOCK"), "info"),
             (12, None)]
    zones += [(8, "big", "digits", "BIGDL" if r == 0 else None) for r in range(7)]
    zones += [(8, None),
              (8, (txt(names[0], W_NAME), W_NAME), "name", "NAMEDL"),
              (4, None),
              (8, (txt("COMMAND $80", W_INFO), W_INFO), "info", "INFODL"),
              (12, None),
              (8, (txt("PRESS FIRE TO PLAY", W_STATUS), W_STATUS), "status", "STATUSDL"),
              (16, None),
              (8, line("LEFT/RIGHT: SONG   FIRE: PLAY"), "hint"),
              (4, None),
              (8, line("DOWN: STOP   UP: NEXT AND PLAY"), "hint"),
              (92, None)]
    split = []
    for z in zones:                       # a zone is at most 16 lines
        n = z[0]
        while n > 16:
            split.append((16,) + z[1:]); n -= 16
        split.append((n,) + z[1:])
    assert sum(z[0] for z in split) >= 292

    dll, lists = bytearray(), bytearray(2)     # the empty list first, shared
    base = RAM + 3 * len(split)
    for n, what, *rest in split:
        at = base
        if what is not None:
            at = base + len(lists)
            pal = PAL[rest[0]][0]
            if what == "big":                  # set by the program
                x = 80 - (40 + DIGIT_GAP) // 2
                lists += text_entry(big, 5, pal, x) + text_entry(big, 5, pal, x + 20 + DIGIT_GAP)
            else:
                s, width = what
                width = min(width, 31)          # centred: a character is 4 hpos units
                lists += text_entry(put(s[:width]), width, pal, 80 - 2 * width)
            lists += bytes(2)
            if len(rest) > 1 and rest[1]:
                syms[rest[1]] = at
        dll += bytes([n - 1, at >> 8, at & 0xFF])
    template = dll + lists
    assert len(template) <= 0x200, len(template)
    put(template + bytes(0x200 - len(template)), "TEMPLATE")
    syms["DLRAM"] = RAM

    regs = [(0x20, BACKGROUND)]
    for pal, colour in PAL.values():
        regs += [(0x21 + 4 * pal + c, colour) for c in range(3)]
    regs += [(0x2C, RAM >> 8), (0x30, RAM & 0xFF), (0x34, CHBASE)]
    put(bytes(b for r in regs for b in r) + b"\xFF", "REGTAB")
    syms["CTRLON"] = 0x43             # DMA on, 1-byte characters, 320A/C
    assert DATA + len(data) <= CODE, "tables overflow into the program"
    rom[DATA - FIXED:DATA - FIXED + len(data)] = data

    code = assemble(PROGRAM, CODE, syms)
    assert CODE + len(code) <= 0xFFFA
    rom[CODE - FIXED:CODE - FIXED + len(code)] = code
    rom[0x3FFA:0x4000] = struct.pack("<3H", syms["nmi"], syms["reset"], syms["nmi"])

    hdr = bytearray(128)
    hdr[0] = 3                               # header version
    hdr[1:17] = b"ATARI7800".ljust(16, b"\0")
    hdr[17:49] = b"BupChip jukebox".ljust(32, b"\0")
    hdr[49:53] = (0x80000).to_bytes(4, "big")   # ROM size: the block starts after it
    hdr[53:55] = (0x1000).to_bytes(2, "big")    # cartridge type: bit 12, Souper
    hdr[55] = 1; hdr[56] = 1                 # joysticks
    hdr[57] = 0                              # NTSC
    hdr[100:128] = b"ACTUAL CART DATA STARTS HERE"
    image = bytes(hdr) + bytes([0xFF]) * (0x80000 - 0x4000) + bytes(rom) + block
    with open(a.out, "wb") as fo:
        fo.write(image)
    print(f"{a.out}: {len(image)} bytes; {count} of 32 songs in the block"
          f"{', names from ' + a.cdf if a.cdf else ''}; program {len(code)} bytes at ${CODE:04X}")


if __name__ == "__main__":
    main()
