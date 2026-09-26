; SaveKey test cart: writes 8 bytes to the SaveKey's EEPROM at $1234 over
; I2C on controller port 2, reads them back, and signals the result with a
; TIA tone - AUDF0=7 (about 1962 Hz) if all 8 match, AUDF0=31 (about 490 Hz)
; if not, or if the EEPROM never acknowledges.
;
; The I2C routines are 7800basic's AtariVox/SaveKey driver (i2c7800.inc, by
; Alex Herbert and Mike Saarna, distributed with 7800basic), which is written
; for real hardware. extra_tests.sh assembles this with 7800basic's includes
; on the path:  dasm savekey_test.asm -f3 -I<7800basic>/includes

	processor 6502

INPTCTRL = $01
AUDC0    = $15
AUDF0    = $17
AUDV0    = $19
SWCHA    = $280
SWACNT   = $281

scratch  = $50          ; I2C_SUBS scratchpad
readback = $60          ; 8 bytes

	org $C000
reset:
	sei
	cld
	lda #$07
	sta INPTCTRL
	ldx #$FF
	txs
	lda #0
	sta SWACNT          ; port A all inputs to start

	; --- write 8 bytes at $1234
	jsr i2c_startwrite
	bcs fail            ; no acknowledge: no SaveKey
	lda #$12
	jsr i2c_txbyte
	lda #$34
	jsr i2c_txbyte
	ldx #0
wr:	lda pattern,x
	jsr i2c_txbyte
	inx
	cpx #8
	bne wr
	jsr i2c_stopwrite

	; --- wait out the EEPROM's write cycle: it does not acknowledge until done
	ldx #0
poll:	jsr i2c_startwrite
	php
	jsr i2c_stopwrite
	plp
	bcc ready
	dex
	bne poll
	jmp fail
ready:

	; --- read them back
	jsr i2c_startwrite
	bcs fail
	lda #$12
	jsr i2c_txbyte
	lda #$34
	jsr i2c_txbyte
	jsr i2c_startread
	ldx #0
rd:	jsr i2c_rxbyte
	sta readback,x
	inx
	cpx #8
	bne rd
	jsr i2c_stopread

	ldx #7
cmp:	lda readback,x
	cmp pattern,x
	bne fail
	dex
	bpl cmp

	lda #7              ; pass
	bne tone
fail:	lda #31
tone:	sta AUDF0
	lda #4
	sta AUDC0
	lda #15
	sta AUDV0
idle:	jmp idle

pattern:
	.byte $A5, $5A, $01, $02, $80, $7F, $FF, $00

	include "i2c7800.inc"
	I2C_SUBS scratch

nmi:	rti

	org $FFFA
	.word nmi
	.word reset
	.word nmi
