; Closed caption test for the 7800 (dasm): MARIA draws an EIA-608 caption
; line, to see whether a TV's caption decoder reads it. On the TV, with
; captions on (CC1, or CC3 for the other field), the caption
; "ATARI 7800 CAPTION n" should appear at the bottom, n counting 0-9, a
; new caption every 2 seconds or so.
;
; The caption line: from the first line MARIA can draw (+ the offset
; below), 320D graphics with kangaroo mode on, so every pixel is a palette
; colour (P0C1 black, P0C3 the high level) and none is background. It holds
; the clock run-in (about 5.7 of its 7 cycles: MARIA's picture starts 18
; clocks after the run-in should), the start bits 0 0 1 and the two bytes
; up to the second byte's bit 5. The last two bits (bit 6 and parity) fall
; in the right border: border control is on for that line and the CPU
; writes BACKGRND there, bit 6's level and then parity's, then black again.
; See cc_tables.py for the bit positions.
;
; Controls (shown at the top left: offset, level, channel):
;   up / down     the caption line's offset, 0-7 lines below the first
;                 line MARIA draws (the TV's line 21 is one of them)
;   left / right  the high level: hue 0, luminance 2-15 (default 7)
;   SELECT        CC1 or CC3 (CC3 sends the misc control codes as $15:
;                 for a TV that takes the 7800's frames as field 2)
; In simulation (tb_load +dmaprobe +ccprobe, 2026-11-08): the caption line
; is MARIA row 18 at offset 0 (row 19 at 1, ...); the picture's first pixel
; is column 93; the run-in pulses start at columns 93, 107, ... 164, the
; start bits' 1 at 203-217, and the bytes read back as sent (ENM $94 $AE,
; PAC $94 $E0); the bit 6 / parity border write lands at column 426 or 428
; (the CPU's half cycle alternates between frames), and black returns at
; column 16-18 of the next line. The TV's line 21 should be row 17 (vsync
; is rows 0-2, NTSC lines 4-6), one above the first line MARIA can draw;
; without equalising pulses, where a TV counts from is not certain.
; Build: python3 cc_tables.py PIX0_COL > cc_tables.inc;
; dasm cc_test.asm -f3 -occ_test.bin; sim/make_a78.py --bin cc_test.bin;
; sign it for an NTSC console.

	processor 6502

INPTCTRL = $01
BACKGRND = $20
P0C1     = $21
P0C2     = $22
P0C3     = $23
WSYNC    = $24
MSTAT    = $28
DPPH     = $2C
DPPL     = $30
P4C1     = $31
CTRL     = $3C
SWCHA    = $280
SWCHB    = $282

CTRL_NORM = $40         ; DMA on, 160A, black border, kangaroo off
CTRL_CC   = $4E         ; DMA on, border control, kangaroo, 320B/D

; Rows: MARIA fetches a line during the two before it (its DMA starts at
; column 440 two lines ahead), so the first line it draws is the frame's
; first DMA line + 2. FIRST_WS WSYNCs from that DMA line release the CPU at
; column 412 of the line before the caption line; the next line's (empty)
; DMA then halts it until about column 12 of the caption line. W1_DELAY and
; W2_DELAY, in CPU cycles, then put the first border write inside the
; picture (after the left border, before column 413) and the second at
; column 429. All three from the simulation (tb_load +dmaprobe +ccprobe).
	ifnconst FIRST_WS
FIRST_WS = 2
	endif
	ifnconst W1_DELAY
W1_DELAY = 41
	endif
	ifnconst W2_DELAY
W2_DELAY = 54
	endif

	mac DELAY               ; exactly {1} CPU cycles (at least 2)
	if {1} & 1
	bit $90                 ; 3
	REPEAT ({1} - 3) / 2
	nop
	REPEND
	else
	REPEAT {1} / 2
	nop
	REPEND
	endif
	endm

off      = $80          ; caption line offset, 0-7
lvl      = $81          ; high level, 2-15
chan     = $82          ; 0 CC1, 1 CC3
seqi     = $83          ; sequence index (SEQ_LEN + SEQ_NULL frames)
cnt      = $84          ; the counter, 0-9
pa       = $85          ; this frame's pair
pb       = $86
tmp      = $87
lvl17    = $88          ; the border writes' values
lvl18    = $89
prevA    = $8A          ; last frame's SWCHA
prevB    = $8B          ; last frame's SWCHB
wsn      = $8C          ; WSYNCs to the caption line
dlp      = $8D          ; DLL write pointer (2 bytes)

BM       = $1800        ; the caption line's 40 bytes
CCDL     = $1840        ; its display list
STDL     = $1860        ; the status line's display list
DLL      = $1900

	org $C000
reset
	sei
	cld
	lda #$07
	sta INPTCTRL
	lda #$60                ; DMA off while setting up
	sta CTRL
	ldx #$FF
	txs
	lda #0
	ldx #$40
clear
	sta $00,x
	inx
	bne clear
	lda #7
	sta lvl
	lda #$FF
	sta prevA
	sta prevB
	lda #$00
	sta BACKGRND
	sta P0C1
	lda #$0F
	sta P4C1
	ldx #0                  ; the caption line's display list
cdl	lda ccdl_rom,x
	sta CCDL,x
	inx
	cpx #12
	bne cdl
	jsr input               ; the level, and the WSYNC count
	jsr build_dll
	jsr build_status
	jsr build_line
	lda #>DLL
	sta DPPH
	lda #<DLL
	sta DPPL
	jsr wait_vb_start
	lda #CTRL_NORM
	sta CTRL

frame
	jsr wait_vb_end         ; the frame's first DMA line
	ldx wsn
	ldy lvl18
	lda #CTRL_CC            ; the lines before the caption line are empty,
	sta CTRL                ; so it can be set this early: before the
ws	sta WSYNC               ; caption line's DMA, two lines ahead
	dex
	bne ws                  ; released at column 412 of the line before
	nop                     ; halted from column 440 for the next line's
	nop                     ; (empty) DMA; resumes in the caption line
	DELAY W1_DELAY
	lda lvl17
	sta BACKGRND            ; bit 6's level, for the right border
	DELAY W2_DELAY
	lda #0
	sty BACKGRND            ; parity's level, at column 429
	nop                     ; halted from column 440 for a DMA, so the
	nop                     ; next write lands in the next line's hblank
	sta BACKGRND            ; black, before its border (column 68)
	lda #CTRL_NORM
	sta CTRL                ; back to 160A before its picture

	jsr input               ; the next frame's work, here: vblank is too
	                        ; short for it (2 frames a caption pair)
	jsr build_dll
	jsr next_pair
	jsr build_line
	jsr build_status
	jmp frame

; Joystick 1 and SELECT, on their presses
input
	lda SWCHA
	tax
	eor #$FF
	and prevA               ; bits newly pressed (SWCHA: 0 = pressed)
	stx prevA
	sta tmp
	lda tmp
	and #$10                ; up: offset - 1
	beq in_dn
	lda off
	beq in_dn
	dec off
in_dn	lda tmp
	and #$20                ; down: offset + 1
	beq in_lt
	lda off
	cmp #7
	beq in_lt
	inc off
in_lt	lda tmp
	and #$40                ; left: level - 1
	beq in_rt
	lda lvl
	cmp #2
	beq in_rt
	dec lvl
in_rt	lda tmp
	and #$80                ; right: level + 1
	beq in_sel
	lda lvl
	cmp #15
	beq in_sel
	inc lvl
in_sel	lda SWCHB
	tax
	eor #$FF
	and prevB
	stx prevB
	and #$02                ; SELECT
	beq in_done
	lda chan
	eor #1
	sta chan
in_done
	lda lvl
	sta P0C3
	clc
	lda off
	adc #FIRST_WS
	sta wsn
	rts

; The display list list: [offset lines][the caption line][fill to 64]
; [the status line, 16][empty to the end]
build_dll
	lda #<DLL
	sta dlp
	lda #>DLL
	sta dlp+1
	ldy #0
	lda off
	beq bd_cc
	sec
	sbc #1                  ; an empty zone of off lines
	jsr dll_empty
bd_cc	lda #$00                ; the caption line: 1 line
	sta (dlp),y
	iny
	lda #>CCDL
	sta (dlp),y
	iny
	lda #<CCDL
	sta (dlp),y
	iny
	lda #15
	jsr dll_empty
	lda #15
	jsr dll_empty
	lda #15
	jsr dll_empty
	lda #14                 ; 15 - off lines
	sec
	sbc off
	jsr dll_empty
	lda #$0F                ; the status line
	sta (dlp),y
	iny
	lda #>STDL
	sta (dlp),y
	iny
	lda #<STDL
	sta (dlp),y
	iny
	ldx #12
bd_rest	lda #15
	jsr dll_empty
	dex
	bne bd_rest
	rts
dll_empty                       ; A = lines - 1
	sta (dlp),y
	iny
	lda #>empty
	sta (dlp),y
	iny
	lda #<empty
	sta (dlp),y
	iny
	rts

; The status line: offset, level (2 digits), channel (1 or 3)
build_status
	ldy #0
	lda off
	ldx #24
	jsr st_digit
	lda lvl
	ldx #0
st_ten	cmp #10
	bcc st_one
	sbc #10
	inx
	bne st_ten
st_one	pha
	txa
	ldx #56
	jsr st_digit
	pla
	ldx #72
	jsr st_digit
	lda chan
	asl
	ora #1                  ; 1 or 3
	ldx #104
	jsr st_digit
	lda #0
	sta STDL,y
	sta STDL+1,y
	rts
st_digit                        ; digit A at x X: a 4-byte header
	sta tmp
	asl
	adc tmp                 ; 3 bytes a glyph
	sta STDL,y
	lda #$9D                ; palette 4, width 3
	sta STDL+1,y
	lda #$E0
	sta STDL+2,y
	txa
	sta STDL+3,y
	tya
	clc
	adc #4
	tay
	rts

; This frame's byte pair
next_pair
	ldx seqi
	cpx #SEQ_LEN
	bcc np_seq
	lda #$80                ; null
	sta pa
	sta pb
	jmp np_adv
np_seq	lda seq_a,x
	ldy seq_misc,x
	beq np_a
	ldy chan
	beq np_a
	lda par_15              ; CC3: misc codes on $15
np_a	sta pa
	lda seq_b,x
	cpx #SEQ_CNT
	bne np_b
	ldy cnt
	lda par_dig,y
np_b	sta pb
np_adv	inx
	cpx #SEQ_LEN + SEQ_NULL
	bne np_done
	ldx #0
	inc cnt
	lda cnt
	cmp #10
	bne np_done
	lda #0
	sta cnt
np_done	stx seqi
	rts

; The caption line's 40 bytes, and the border writes' values
build_line
	ldx #39
bl_cp	lda cc_base,x
	sta BM,x
	dex
	bpl bl_cp
	lda pa
	sta tmp
	ldy #0                  ; data bits 3-16
bl_bit	cpy #8
	bne bl_sh
	lda pb
	sta tmp
bl_sh	lsr tmp
	bcc bl_next
	ldx cc_mi0,y
	lda BM,x
	ora cc_mm0,y
	sta BM,x
	ldx cc_mi1,y
	bmi bl_next
	lda BM,x
	ora cc_mm1,y
	sta BM,x
	ldx cc_mi2,y
	bmi bl_next
	lda BM,x
	ora cc_mm2,y
	sta BM,x
bl_next	iny
	cpy #14
	bne bl_bit
	ldx #0                  ; bit 17: the second byte's bit 6
	lda pb
	and #$40
	beq bl_17
	ldx lvl
bl_17	stx lvl17
	ldx #0                  ; bit 18: its parity
	lda pb
	bpl bl_18
	ldx lvl
bl_18	stx lvl18
	rts

wait_vb_start
	lda MSTAT
	bmi wait_vb_start
wvs	lda MSTAT
	bpl wvs
	rts

wait_vb_end
	lda MSTAT
	bpl wait_vb_end
wve	lda MSTAT
	bmi wve
	rts

; The caption line's display list: two 20-byte 320D objects (5-byte
; headers, write mode 0), palette 3 (P1 = P0 = 1: colours 1 and 3 of
; palette 0), at x 0 and 80
ccdl_rom
	dc.b <BM, $40, >BM, $6C, 0
	dc.b <(BM+20), $40, >(BM+20), $6C, 80
	dc.b 0, 0

	include "cc_tables.inc"

	org $D000
empty	dc.b 0, 0

	include "font_bold.inc"

	org $FFF8
	dc.b $FF, $C7
	dc.w reset
	dc.w reset
	dc.w reset
