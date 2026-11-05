; Colour register access test for the 7800 (dasm). On a console, a CPU
; access to one of MARIA's 25 colour registers while a visible line is
; drawn shows at the beam: a read puts that register's colour on the pixel
; for 2 MARIA clocks, a write repeats the previous pixel for 1 (from the
; schematics; 7800tools.com's MARIA summary). This cart draws it, to be
; photographed on a console and compared with the core:
;
;   ruler (MARIA rows 34-39): white ticks 2 pixels wide every 16 pixels,
;     from the picture's left edge
;   staircase A (rows 42-90): LDA $31 (P4C1, red): one flash per read
;   ruler (96-101)
;   staircase B (about 106-154): LDA $31,X with X = 0: the dummy read of
;     the base address, then the read, one cycle apart
;   ruler (158-163)
;   staircase C (about 168-216): STA $31 (the colour it already holds):
;     on black, nothing should show
;   ruler (220-225)
; (rows as the core draws them: the DLL's zones start 2 rows below its
; first entry's nominal row 16, and a step boundary can skip a row)
; Each staircase row accesses $31 three times, 16 CPU cycles apart; every
; 3 rows the first access is a cycle later, 16 steps in all, so the dots
; step right 2 pixels at a time. Everything else is black. The background
; is never touched; P4C1 is used by nothing else.
; tb_load +dmaprobe logs each access's row and column (CRAM lines).
; Build: dasm cram_test.asm -f3 -ocram_test.bin, then
; sim/make_a78.py --bin cram_test.bin, and sign it for an NTSC console.

	processor 6502

INPTCTRL = $01
BACKGRND = $20
P0C1     = $21
WSYNC    = $24
MSTAT    = $28
DPPH     = $2C
DPPL     = $30
P4C1     = $31
CTRL     = $3C

RED      = $48

ptr      = $80          ; the clockslide entry
retptr   = $82          ; the body the clockslide returns to
step     = $84

SLIDE_N  = 15           ; D = 0-15 cycles

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
	lda #$00
	sta BACKGRND
	lda #$0F
	sta P0C1
	lda #RED
	sta P4C1
	lda #>dll
	sta DPPH
	lda #<dll
	sta DPPL
	jsr wait_vb_start
	lda #$40                ; DMA on, 160A, black border
	sta CTRL

frame
	jsr wait_vb_end         ; row 16
	ldx #25                 ; releases 1-25: to row 41
	jsr idle
	lda #<body_a
	ldx #>body_a
	jsr stairs              ; rows 42-89
	ldx #14
	jsr idle                ; rows 90-103
	lda #<body_b
	ldx #>body_b
	jsr stairs              ; rows 104-151
	ldx #14
	jsr idle                ; rows 152-165
	lda #<body_c
	ldx #>body_c
	jsr stairs              ; rows 166-213
	jmp frame

idle                            ; X WSYNCs
	sta WSYNC
	dex
	bne idle
	rts

; 16 steps of 3 rows; the clockslide returns to the body at A (low), X
; (high). Between steps only the slide's entry moves (one byte down: one
; cycle more), so the rows keep their WSYNC whatever D is.
stairs
	sta retptr
	stx retptr+1
	lda #<(slide+SLIDE_N)   ; D = 0
	sta ptr
	lda #>(slide+SLIDE_N)
	sta ptr+1
	lda #16
	sta step
	ldx #0                  ; for LDA $31,X
	lda #RED                ; for STA $31
st_step
	ldy #3
row
	sta WSYNC
	jmp (ptr)               ; D + 3 cycles, then jmp (retptr)
next_row                        ; the bodies come back here
	dey
	bne row
	dec ptr                 ; D + 1 (the slide is in one page)
	dec step
	bne st_step
	rts

	align 256               ; the bodies' and slide's code in one page
body_a                          ; LDA $31 every 16 cycles, 3 times
	nop                     ; a fixed lead-in, to put the first access
	nop                     ; in the left half of the picture
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	lda P4C1                ; 3
	nop                     ; 13 to the next
	nop
	nop
	nop
	nop
	lda $90
	lda P4C1
	nop
	nop
	nop
	nop
	nop
	lda $90
	lda P4C1
	lda #RED                ; A back for body C's caller (harmless here)
	jmp next_row

body_b                          ; LDA $31,X (X = 0) every 16 cycles
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	lda P4C1,x              ; 4: dummy read of $31, then $31
	nop                     ; 12 to the next
	nop
	nop
	nop
	nop
	nop
	lda P4C1,x
	nop
	nop
	nop
	nop
	nop
	nop
	lda P4C1,x
	lda #RED
	jmp next_row

body_c                          ; STA $31 every 16 cycles
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	sta P4C1                ; 3
	nop
	nop
	nop
	nop
	nop
	bit $90
	sta P4C1
	nop
	nop
	nop
	nop
	nop
	bit $90
	sta P4C1
	jmp next_row

; Entered SLIDE_N - D bytes in, it takes D + 3 cycles (CMP #$C9 pairs,
; then CMP $EA, or CMP #$C5 and NOP)
slide
	ds SLIDE_N, $C9
	dc.b $C5, $EA
	jmp (retptr)

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

	org $D000
empty	dc.b 0, 0
ruler	dc.b $00, $0C, $F0, 0       ; 20 bytes (80 pixels) at x 0
	dc.b $00, $0C, $F0, 80      ; and at x 80
	dc.b 0, 0
dll	dc.b $0F, >empty, <empty    ; rows 16-31
	dc.b $05, >ruler, <ruler    ; 32-37
	dc.b $03, >empty, <empty    ; 38-41
	dc.b $0F, >empty, <empty    ; 42-89: A
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $03, >empty, <empty    ; 90-93
	dc.b $05, >ruler, <ruler    ; 94-99
	dc.b $03, >empty, <empty    ; 100-103
	dc.b $0F, >empty, <empty    ; 104-151: B
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $03, >empty, <empty    ; 152-155
	dc.b $05, >ruler, <ruler    ; 156-161
	dc.b $03, >empty, <empty    ; 162-165
	dc.b $0F, >empty, <empty    ; 166-213: C
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty
	dc.b $03, >empty, <empty    ; 214-217
	dc.b $05, >ruler, <ruler    ; 218-223
	dc.b $0F, >empty, <empty    ; the rest
	dc.b $0F, >empty, <empty
	dc.b $0F, >empty, <empty

; The ruler's graphics: pages $F0-$F5 (a 6-line zone's offsets), the same
; on each: 2 pixels of colour 1 every 16 pixels (160A: pixel 0 is bits 7-6)
rpage	SET 0
	REPEAT 6
	org $F000 + rpage * 256
	REPEAT 5
	dc.b $50, 0, 0, 0
	REPEND
rpage	SET rpage + 1
	REPEND

	org $FFF8
	dc.b $FF, $C7
	dc.w reset
	dc.w reset
	dc.w reset
