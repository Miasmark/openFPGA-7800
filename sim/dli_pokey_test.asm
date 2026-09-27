; DLI + WSYNC + POKEY test cart, modelled on Ballblazer's siren: a display
; list interrupt handler that waits on WSYNC, writes a MARIA colour, and
; sweeps a POKEY frequency by a small step each time it fires.
;
; Build: dasm dli_pokey_test.asm -f3 -odli_pokey_test.bin  (16 KiB, $C000)
; Expected: the DLI fires once per frame (dli_count counts at ~60 Hz), the
; main loop keeps running (main_count keeps counting), and POKEY channel 1
; plays a tone whose pitch steps every frame.

	processor 6502

INPTCTRL = $01
BACKGRND = $20
WSYNC    = $24
DPPH     = $2C
DPPL     = $30
CTRL     = $3C

POKEY    = $4000
AUDF1    = POKEY+0
AUDC1    = POKEY+1
AUDCTL   = POKEY+8
SKCTL    = POKEY+15

DLL      = $1800        ; display list list, in RAM
DLEMPTY  = $1900        ; an empty display list

dli_count  = $40
main_count = $41        ; two bytes
sweep      = $43
colour     = $44

	org $C000
reset:
	sei
	cld
	lda #$07            ; lock INPTCTRL, MARIA on, BIOS out
	sta INPTCTRL
	ldx #$FF
	txs
	lda #0
	sta CTRL            ; DMA off while building the lists
	ldx #$7F
clear:	sta $40,x
	dex
	bpl clear

	; empty DL: header with byte 1 = 0 terminates it
	lda #0
	sta DLEMPTY
	sta DLEMPTY+1

	; DLL: 16 zones of 16 lines, zone 6 raises a DLI
	ldx #0
	ldy #0
dll:	lda #$0F            ; 16 lines
	cpy #6
	bne nodli
	ora #$80            ; DLI
nodli:	sta DLL,x
	lda #>DLEMPTY
	sta DLL+1,x
	lda #<DLEMPTY
	sta DLL+2,x
	inx
	inx
	inx
	iny
	cpy #16
	bne dll

	lda #>DLL
	sta DPPH
	lda #<DLL
	sta DPPL

	; POKEY: pure tone, volume 15, 64 kHz base clock
	lda #3
	sta SKCTL
	lda #0
	sta AUDCTL
	lda #$AF
	sta AUDC1
	lda #$40
	sta sweep
	sta AUDF1

	lda #$40            ; DMA on, normal display
	sta CTRL

main:	inc main_count
	bne main
	inc main_count+1
	jmp main

dli:	pha
	sta WSYNC           ; wait for the end of the line
	lda colour
	sta BACKGRND
	clc
	adc #$11
	sta colour
	lda sweep           ; sweep the siren
	clc
	adc #3
	sta sweep
	sta AUDF1
	inc dli_count
	pla
	rti

irq:	rti

	org $FFFA
	.word dli
	.word reset
	.word irq
