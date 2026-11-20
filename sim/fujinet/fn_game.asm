; FujiNet game loading, end to end: the game the bench's FujiNet model
; pushes (tb_load.sv +fnpush=fn_game.a78, or the bare 16K fn_game.bin for
; the generated header). An ordinary cartridge, no FujiNet claim: once it
; runs it writes $5A to $2201 and counts frames' worth of loops in $2205,
; which the bench reads as the swap's success. Its first bytes differ from
; fn_boot.asm's, so a console still running the old program never writes
; the marker.
; Build: dasm fn_game.asm -f3 -ofn_game.bin; ../make_a78.py --bin fn_game.bin > fn_game.a78
; SPDX-License-Identifier: MIT

	processor 6502

INPTCTRL = $01
CTRL     = $3C
MARK     = $2200

	org $C000
	; a block of data the image check can see (and SLIP's two special
	; bytes, $C0 and $DB, to be escaped on the way)
	dc.b $C0, $DB, $C0, $C0, $DB, $DB, $00, $FF
reset
	sei
	cld
	lda #$07
	sta INPTCTRL
	lda #$60
	sta CTRL
	ldx #$FF
	txs
	lda #$5A
	sta MARK+1
	lda #0
	sta MARK+5
loop
	ldx #0
spin
	dex
	bne spin
	inc MARK+5
	jmp loop

	org $FFF8
	dc.b $FF, $C7
	dc.w reset, reset, reset
