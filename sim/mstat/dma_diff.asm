; DMA profile, compared (dasm): dma_profile.asm's measurement, then the
; cart compares each line with the 2.2.5 core's value for it
; (expected.inc, from tb_load) and shows only what differs, in a bold
; font that survives RF:
;   row 1:  the sum over all 263 lines, and how many lines differ
;   rows 2-10: the first 9 lines that differ: the line, and its value
; On the core the sum is 16203 and no line differs. Line i is MARIA's row
; 257 + i, wrapping at 263 (1 is the first line of vblank, 21 holds the
; frame's first DMA, 22 the first visible line, 263 the last); a line's
; value is 55 plus the CPU cycles its DMA took (see dma_profile.asm).
; -DROMDL builds it with the 1-line zones' display list in ROM instead,
; which reads the same on the core.
; Build: dasm dma_diff.asm -f3 -odma_diff.bin, then
; sim/make_a78.py --bin dma_diff.bin, and sign it for an NTSC console.

		processor 6502

INPTCTRL = $01
BACKGRND = $20
P0C1     = $21
WSYNC    = $24
MSTAT    = $28
DPPH     = $2C
DPPL     = $30
CTRL     = $3C
INTIM    = $284
TIM1T    = $294

logv     = $90          ; tb_load +dmaprobe logs writes here
sum      = $A2
ilo      = $A4
ihi      = $A5
tptr     = $A6
val      = $A8
num      = $A9
digit    = $AB
dl       = $AC
dly      = $AE
xpos     = $AF
eptr     = $B0
ndiff    = $B2          ; lines that differ (16 bits)
ndig     = $B4
rowk     = $B5

DLINE_LO = $1E00        ; the first 9 lines that differ, and their values
DLINE_HI = $1E10
DVAL     = $1E20

TABLE    = $1C00        ; line i's value at TABLE + i

	org $C000
reset
	sei
	cld
	lda #$07
	sta INPTCTRL
	lda #$60                ; DMA off while RAM is set up
	sta CTRL
	ldx #$FF
	txs
	lda #0
	ldx #$40
clear
	sta $00,x
	inx
	bne clear
	ldx #0                  ; the series' digit zone at $2200
copy
	lda digits,x
	sta $2200,x
	inx
	cpx #digits_end-digits
	bne copy
	lda #>mdll
	sta DPPH
	lda #<mdll
	sta DPPL
	jsr wait_vb_start
	lda #$40                ; DMA on, 160A
	sta CTRL
	jsr wait_vb_start       ; a whole frame of DMA before the first one

	lda #1
	sta ilo
	ifconst QUICK          ; -DQUICK: the screen alone, for checking it
	jmp show
	endif
measure
	jsr wait_vb_start
	lda #255
	ldx ihi
	beq short
	ldy #255                ; line 256 on: 255 WSYNCs, then i - 255
long
	sta WSYNC
	dey
	bne long
	ldx ilo
	inx
	jmp chain
short
	ldx ilo
chain
	sta WSYNC
	dex
	bne chain
	sta TIM1T               ; release + 4 cycles, before the line's DMA
	ldx #10                 ; 49 cycles: short enough that the window ends
delay                           ; before the next line's DMA even on the
	dex                     ; digit zone's lines
	bne delay
	lda INTIM
	eor #$FF                ; 255 - INTIM
	sta val
	sta logv
	clc
	lda ilo
	adc #<TABLE
	sta tptr
	lda ihi
	adc #>TABLE
	sta tptr+1
	ldy #0
	lda val
	sta (tptr),y
	clc
	adc sum
	sta sum
	lda sum+1
	adc #0
	sta sum+1
	inc ilo
	bne next
	inc ihi
next
	lda ihi
	beq more
	lda ilo
	cmp #8                  ; i = 264: done
	beq show
more
	jmp measure

show
	lda #0
	sta ndiff
	sta ndiff+1
	sta ihi
	lda #1
	sta ilo
cmp_loop
	clc
	lda ilo
	adc #<TABLE
	sta tptr
	lda ihi
	adc #>TABLE
	sta tptr+1
	clc
	lda ilo
	adc #<expected
	sta eptr
	lda ihi
	adc #>expected
	sta eptr+1
	ldy #0
	lda (tptr),y
	cmp (eptr),y
	beq same
	ldx ndiff+1             ; keep the first 9
	bne count
	ldx ndiff
	cpx #9
	bcs count
	lda ilo
	sta DLINE_LO,x
	lda ihi
	sta DLINE_HI,x
	lda (tptr),y
	sta DVAL,x
count
	inc ndiff
	bne same
	inc ndiff+1
same
	inc ilo
	bne c2
	inc ihi
c2
	lda ihi
	beq cmp_next
	lda ilo
	cmp #8                  ; i = 264: done
	beq render
cmp_next
	jmp cmp_loop

render
	lda #$18                ; the rows' display lists: $1800, $1840, ...
	sta dl+1
	lda #$00
	sta dl
	sta dly
	lda #8
	sta xpos
	lda sum
	sta num
	lda sum+1
	sta num+1
	lda #5
	sta ndig
	jsr putnum
	lda #104
	sta xpos
	lda ndiff
	sta num
	lda ndiff+1
	sta num+1
	lda #3
	sta ndig
	jsr putnum
	jsr enddl
	lda #0
	sta rowk
row
	clc                     ; the next row's display list
	lda dl
	adc #$40
	sta dl
	lda dl+1
	adc #0
	sta dl+1
	lda #0
	sta dly
	ldx rowk
	lda ndiff+1
	bne shown               ; 256 or more: all 9 rows are filled
	cpx ndiff
	bcs empty_row
shown
	lda DLINE_LO,x
	sta num
	lda DLINE_HI,x
	sta num+1
	lda #24
	sta xpos
	lda #3
	sta ndig
	jsr putnum
	ldx rowk
	lda DVAL,x
	sta num
	lda #0
	sta num+1
	lda #88
	sta xpos
	lda #3
	sta ndig
	jsr putnum
empty_row
	jsr enddl
	inc rowk
	lda rowk
	cmp #9
	bne row

	lda #$00
	sta BACKGRND
	lda #$0F
	sta P0C1
	jsr wait_vb_start
	lda #>ddll
	sta DPPH
	lda #<ddll
	sta DPPL
forever
	jmp forever

enddl                           ; end the display list being written
	ldy dly
	lda #0
	sta (dl),y
	iny
	sta (dl),y
	rts

putnum                          ; num as ndig digits at xpos, 16 pixels apart
	lda #5
	sec
	sbc ndig
	tax
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
	lda digit               ; 3 bytes a glyph
	asl
	adc digit
	sta (dl),y
	iny
	lda #$1D                ; palette 0, width 3
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
	adc #16
	sta xpos
	inx
	cpx #5
	bne pn_place
	rts
tens_lo	dc.b <10000, <1000, <100, <10, <1
tens_hi	dc.b >10000, >1000, >100, >10, >1

wait_vb_start                   ; returns just after vblank starts
	lda MSTAT
	bmi wait_vb_start
wvs	lda MSTAT
	bpl wvs
	rts

; The series' digit zone: 12 objects, 2 bytes wide, palette 0, graphics at
; page $F0 plus the zone's offset (what they show does not matter here)
digits	dc.b $00, $1E, $F0, $14,  $00, $1E, $F0, $1C,  $00, $1E, $F0, $24
	dc.b $00, $1E, $F0, $2C,  $00, $1E, $F0, $40,  $00, $1E, $F0, $48
	dc.b $00, $1E, $F0, $50,  $00, $1E, $F0, $58,  $00, $1E, $F0, $6C
	dc.b $00, $1E, $F0, $74,  $00, $1E, $F0, $7C,  $00, $1E, $F0, $84
	dc.b $00, $00
digits_end

	org $D000
empty	dc.b 0, 0
mdll                            ; the series' empty-zones frame
	REPEAT 12
	dc.b $0F, >empty, <empty
	REPEND
	dc.b $0F, $22, $00
	ifconst ROMDL          ; -DROMDL: the 1-line zones' display list in ROM
	REPEAT 40
	dc.b $00, >empty, <empty
	REPEND
	else
	ds 120, 0               ; then 1-line zones, display list at $0000, as
	endif                   ; the series has them: MARIA reads the TIA's
	                        ; addresses for it

	org $D100
ddll                            ; the results: 10 rows of 16 lines
	REPEAT 2
	dc.b $0F, >empty, <empty
	REPEND
	dc.b $0F, $18, $00
	dc.b $0F, $18, $40
	dc.b $0F, $18, $80
	dc.b $0F, $18, $C0
	dc.b $0F, $19, $00
	dc.b $0F, $19, $40
	dc.b $0F, $19, $80
	dc.b $0F, $19, $C0
	dc.b $0F, $1A, $00
	dc.b $0F, $1A, $40
	REPEAT 4
	dc.b $0F, >empty, <empty
	REPEND

	org $D200
	include "expected.inc"

	include "font_bold.inc"

	org $FFF8
	dc.b $FF, $C7
	dc.w reset
	dc.w reset
	dc.w reset
