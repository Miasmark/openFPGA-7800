; MSTAT and frame-window test for the 7800 (dasm). Run on a console and on
; the core; every measurement is made with MARIA's DMA off, so nothing but
; the frame's own timing is in it. The screen then shows six numbers, two
; per row:
;   row 1: the DMA timing series' loop count (INC/BNE/LDA MSTAT/BPL, 14
;          cycles) from the end of vblank to its start, lowest and highest
;          of 8 frames, as the series counts it but with no DMA at all
;   row 2: where MSTAT's vblank bit clears: L, the WSYNCs after the one
;          that follows the start of vblank until a read just after the
;          release sees it clear, and D, the delay (cycles, plus a fixed
;          overhead of about 20) after the release two lines before that
;          at which a read first sees it clear
;   row 3: the same for the bit setting again at the start of vblank,
;          counted from the WSYNC that follows the end of vblank
; Build: dasm mstat_test.asm -f3 -omstat_test.bin, then
; sim/make_a78.py --bin mstat_test.bin (and sign it for an NTSC console).

	processor 6502

INPTCTRL = $01
BACKGRND = $20
P0C1     = $21
WSYNC    = $24
MSTAT    = $28
DPPH     = $2C
DPPL     = $30
CTRL     = $3C

cnt      = $80          ; the series' counter, at the series' address
cmin     = $82
cmax     = $84
ptr      = $86          ; the clockslide entry
dval     = $88
lo       = $89
hi       = $8A
lend     = $8B
dend     = $8C
lstart   = $8D
dstart   = $8E
frames   = $8F
num      = $90
digit    = $92
dl       = $93          ; the display list being written
dly      = $95
xpos     = $96
retptr   = $97          ; where the clockslide returns to

SLIDE_N  = 127          ; delays D of 0-127 cycles

	org $C000
reset
	sei
	cld
	lda #$07
	sta INPTCTRL
	lda #$60                ; DMA off
	sta CTRL
	ldx #$FF
	txs
	lda #0
	ldx #$40
clear
	sta $00,x
	inx
	bne clear

; ---------------------------------------------------------------- 1: count
	lda #$FF
	sta cmin
	sta cmin+1
	lda #8
	sta frames
	jsr wait_vb_start
	jmp frame1

	align 256               ; the loop's branches stay in one page
frame1
	lda MSTAT
	bmi frame1              ; wait for vblank to end
	lda #0
	sta cnt
	sta cnt+1
count
	inc cnt
	bne cskip
	inc cnt+1
cskip
	lda MSTAT
	bpl count
	lda cnt                 ; cmin = min(cmin, cnt)
	cmp cmin
	lda cnt+1
	sbc cmin+1
	bcs nomin
	lda cnt
	sta cmin
	lda cnt+1
	sta cmin+1
nomin
	lda cmax                ; cmax = max(cmax, cnt)
	cmp cnt
	lda cmax+1
	sbc cnt+1
	bcs nomax
	lda cnt
	sta cmax
	lda cnt+1
	sta cmax+1
nomax
	dec frames
	beq edge_end
	jmp frame1

; ---------------------------------------------------------------- 2: vblank ends
edge_end
	jsr wait_vb_start
	sta WSYNC
	ldx #0
e_lines
	sta WSYNC
	inx
	lda MSTAT
	bmi e_lines
	stx lend
	lda #<e_read
	sta retptr
	lda #>e_read
	sta retptr+1
	lda #0
	sta lo
	lda #SLIDE_N
	sta hi
e_search                        ; the smallest D whose read sees it clear
	lda lo
	cmp hi
	bcs e_done
	clc
	adc hi
	lsr
	sta dval
	jsr setptr
	jsr wait_vb_start
	sta WSYNC
	ldx lend
	dex
	dex                     ; from the line before: the read's fixed
	                        ; overhead is more than the edge's offset
e_chain
	sta WSYNC
	dex
	bne e_chain
	jmp (ptr)               ; D + 3 cycles, then back to e_read
e_read
	lda MSTAT
	bmi e_set
	lda dval                ; clear: the answer is D or less
	sta hi
	jmp e_search
e_set
	ldx dval                ; still set: more than D
	inx
	stx lo
	jmp e_search
e_done
	sta dend

; ---------------------------------------------------------------- 3: vblank starts
	jsr wait_vb_end
	sta WSYNC
	ldx #0
s_lines
	sta WSYNC
	inx
	lda MSTAT
	bpl s_lines
	stx lstart
	lda #<s_read
	sta retptr
	lda #>s_read
	sta retptr+1
	lda #0
	sta lo
	lda #SLIDE_N
	sta hi
s_search                        ; the smallest D whose read sees it set
	lda lo
	cmp hi
	bcs s_done
	clc
	adc hi
	lsr
	sta dval
	jsr setptr
	jsr wait_vb_end
	sta WSYNC
	ldx lstart
	dex
	dex                     ; from the line before: the read's fixed
	                        ; overhead is more than the edge's offset
s_chain
	sta WSYNC
	dex
	bne s_chain
	jmp (ptr)
s_read
	lda MSTAT
	bpl s_clear
	lda dval
	sta hi
	jmp s_search
s_clear
	ldx dval
	inx
	stx lo
	jmp s_search
s_done
	sta dstart

; ---------------------------------------------------------------- 4: show them
	lda #$18                ; display lists at $1800, $1840, $1880
	sta dl+1
	lda #$00
	sta dl
	lda cmin
	ldx cmin+1
	jsr show_left
	lda cmax
	ldx cmax+1
	jsr show_right
	lda #$40
	sta dl
	lda lend
	ldx #0
	jsr show_left
	lda dend
	ldx #0
	jsr show_right
	lda #$80
	sta dl
	lda lstart
	ldx #0
	jsr show_left
	lda dstart
	ldx #0
	jsr show_right
	lda #$00
	sta BACKGRND
	lda #$0F
	sta P0C1
	lda #>dll
	sta DPPH
	lda #<dll
	sta DPPL
	jsr wait_vb_start
	lda #$40                ; DMA on, 160A
	sta CTRL
forever
	jmp forever

; A at x 40 (show_left, which starts the list) or 72 (show_right, which
; ends it); A low byte, X high byte.
show_left
	sta num
	stx num+1
	lda #0
	sta dly
	lda #40
	sta xpos
	jmp putnum
show_right
	sta num
	stx num+1
	lda #72
	sta xpos
	jsr putnum
	ldy dly                 ; end of the display list
	lda #0
	sta (dl),y
	iny
	sta (dl),y
	rts

; num as 4 decimal digits, one 4-byte header each (width 1, palette 0)
putnum
	ldx #0
pn_place
	lda #0
	sta digit
pn_sub
	sec
	lda num
	sbc tens_lo,x
	tay
	lda num+1
	sbc tens_hi,x
	bcc pn_emit
	sta num+1
	sty num
	inc digit
	jmp pn_sub
pn_emit
	ldy dly
	lda digit
	sta (dl),y
	iny
	lda #$1F
	sta (dl),y
	iny
	lda #$E0
	sta (dl),y
	iny
	lda xpos
	sta (dl),y
	iny
	sty dly
	clc
	lda xpos
	adc #5
	sta xpos
	inx
	cpx #4
	bne pn_place
	rts
tens_lo	dc.b <1000, <100, <10, <1
tens_hi	dc.b >1000, >100, >10, >1

wait_vb_start                   ; returns just after vblank starts
	lda MSTAT
	bmi wait_vb_start
wvs	lda MSTAT
	bpl wvs
	rts

wait_vb_end                     ; returns just after vblank ends
	lda MSTAT
	bpl wait_vb_end
wve	lda MSTAT
	bmi wve
	rts

setptr                          ; ptr = slide + SLIDE_N - dval
	sec
	lda #<(slide+SLIDE_N)
	sbc dval
	sta ptr
	lda #>(slide+SLIDE_N)
	sbc #0
	sta ptr+1
	rts

; Entered SLIDE_N - D bytes in, it takes D + 3 cycles: CMP #$C9 pairs, then
; CMP $EA (3) or CMP #$C5 and NOP (2 + 2).
slide
	ds SLIDE_N, $C9
	dc.b $C5, $EA
	jmp (retptr)

	org $D000
empty	dc.b 0, 0
dll	dc.b $0F, >empty, <empty    ; 4 x 16 lines empty
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $0F, $18, $00          ; row 1
	dc.b $07, >empty, <empty
	dc.b $0F, $18, $40          ; row 2
	dc.b $07, >empty, <empty
	dc.b $0F, $18, $80          ; row 3
	dc.b $0F, >empty, <empty    ; the rest of the frame
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty

	include "font.inc"

	org $FFF8
	dc.b $FF, $C7           ; region byte; the ROM starts at $C000
	dc.w reset              ; NMI (no DLIs here)
	dc.w reset
	dc.w reset
