; DMA profile test for the 7800 (dasm): what MARIA's DMA costs the CPU on
; each line of the frame, measured with the RIOT timer, which keeps
; counting while MARIA holds the CPU. Run on a console and on the core.
;
; The DMA load is the DMA timing series' "empty zones" case: 12 zones of 16
; lines whose display lists are empty, a 16-line zone with 12 objects of 2
; bytes (the series' digits), then 1-line zones whose display list is at
; $0000, to the end of the frame. One line is measured per frame: after
; the start of vblank, WSYNC i times (i = 1-263, so every line once), then
; TIM1T, a fixed delay, INTIM. A line's value is the cycles that took, the
; delay plus the DMA in it; the CPU's cycles alone come to the same on
; every line. Each value is also written to $90, which tb_load +dmaprobe
; logs. The screen then shows ten 5-digit numbers, two per row:
;   row 1: the sum over all 263 lines, and line 21's value
;   row 2: lines 22 and 23
;   row 3: lines 37 and 38
;   row 4: lines 229 and 230
;   row 5: lines 263 and 1
; On the core, line i is MARIA's row 257 + i, wrapping at 263: line 21 is
; row 15, whose window holds only the frame's first DMA (its zone fetch,
; at the start of row 16); 22 the first visible line; 37 and 38 the end of
; the first zone; 229 the end of the digit zone; 230 the first 1-line
; zone; 263 the last visible line, whose DMA is for the first line of
; vblank; 1 the first line of vblank, with no DMA.
; Build: dasm dma_profile.asm -f3 -odma_profile.bin, then
; sim/make_a78.py --bin dma_profile.bin, and sign it for an NTSC console.

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

TABLE    = $1A00        ; line i's value at TABLE + i

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
	lda #$18
	sta dl+1
	lda #$00
	sta dl
	lda sum
	ldx sum+1
	jsr show_left
	ldy #21
	jsr show_line_right
	lda #$40
	sta dl
	ldy #22
	jsr show_line_left
	ldy #23
	jsr show_line_right
	lda #$80
	sta dl
	ldy #37
	jsr show_line_left
	ldy #38
	jsr show_line_right
	lda #$C0
	sta dl
	ldy #229
	jsr show_line_left
	ldy #230
	jsr show_line_right
	lda #$19
	sta dl+1
	lda #$00
	sta dl
	lda TABLE+$107          ; line 263
	ldx #0
	jsr show_left
	ldy #1
	jsr show_line_right
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

show_line_left                  ; line Y's value (lines 1-255)
	lda TABLE,y
	ldx #0
	jmp show_left
show_line_right
	lda TABLE,y
	ldx #0
	jmp show_right

; A low byte, X high byte, at x 40 (show_left, which starts the list) or
; 72 (show_right, which ends it); 5 digits, 5 pixels apart
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
	ldy dly
	lda #0
	sta (dl),y
	iny
	sta (dl),y
	rts

putnum                          ; num as 5 digits, one 4-byte header each
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
	ds 120, 0               ; then 1-line zones, display list at $0000

	org $D100
ddll                            ; the results
	REPEAT 4
	dc.b $0F, >empty, <empty
	REPEND
	dc.b $0F, $18, $00
	dc.b $07, >empty, <empty
	dc.b $0F, $18, $40
	dc.b $07, >empty, <empty
	dc.b $0F, $18, $80
	dc.b $07, >empty, <empty
	dc.b $0F, $18, $C0
	dc.b $07, >empty, <empty
	dc.b $0F, $19, $00
	REPEAT 5
	dc.b $0F, >empty, <empty
	REPEND

	include "font.inc"

	org $FFF8
	dc.b $FF, $C7
	dc.w reset
	dc.w reset
	dc.w reset
