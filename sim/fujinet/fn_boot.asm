; FujiNet game loading, end to end (docs/FUJINET_GAME_LOADING.md, step 4):
; the program side of a boot, as FujiNet's CONFIG does it (fujinet-config
; atari7800/st_boot.c), with no screen. tb_load.sv's FujiNet model
; (fn_model.sv, +fnpush=FILE) answers the MOUNT_IMAGE by pushing FILE.
;   1. claim the mailbox ("FUJI" at $FF70);
;   2. MOUNT_IMAGE ($F8 to $70, host slot 0, device slot 1), and wait for
;      ACKSEQ to echo SEQ (the mailbox waits 60 s for a slow command);
;   3. if BOOT_STATE is READY: BOOTLOCK ($B5 to register $11), SEI, CTRL =
;      $7F, JMP $0600 (the cartridge's loader: the hot swap).
; Markers, in RAM, for the bench: $2200 = $11 started, $22 READY and
; jumping, $EE not READY (then $2202 ERR, $2203 BOOT_STATE, $2204
; BOOT_ERR); the pushed game (fn_game.asm) writes $2201.
; Build: dasm fn_boot.asm -f3 -ofn_boot.bin; ../make_a78.py --bin fn_boot.bin > fn_boot.a78
; SPDX-License-Identifier: MIT

	processor 6502

INPTCTRL = $01
CTRL     = $3C

FN_ACKSEQ  = $0C00
FN_ERR     = $0C02
FN_BSTATE  = $0C06
FN_BERR    = $0C08
FN_REGSEL  = $0D00
FN_TXDATA  = $0F00
REG_DEVICE = $00
REG_CMD    = $01
REG_NPARAM = $02
REG_RST    = $05
REG_SEQ    = $10
REG_BLOCK  = $11

MARK     = $2200

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
	lda #$11
	sta MARK

	lda #$70                ; MOUNT_IMAGE to the FujiNet
	sta FN_REGSEL+REG_DEVICE
	lda #$F8
	sta FN_REGSEL+REG_CMD
	lda #2
	sta FN_REGSEL+REG_NPARAM
	lda #0
	sta FN_REGSEL+REG_RST
	lda #1                  ; host slot 0, device slot 1: {size, value} each
	sta FN_TXDATA
	lda #0
	sta FN_TXDATA
	lda #1
	sta FN_TXDATA
	sta FN_TXDATA
	ldx FN_ACKSEQ           ; SEQ = ACKSEQ + 1, never 0
	inx
	bne seqok
	inx
seqok
	stx FN_REGSEL+REG_SEQ
wait
	cpx FN_ACKSEQ
	bne wait

	lda FN_ERR
	sta MARK+2
	lda FN_BSTATE
	sta MARK+3
	lda FN_BERR
	sta MARK+4
	lda FN_BSTATE
	cmp #2                  ; READY
	beq boot
	lda #$EE
	sta MARK
stop
	jmp stop

boot
	lda #$22
	sta MARK
	lda #$B5
	sta FN_REGSEL+REG_BLOCK
	sei
	lda #$7F
	sta CTRL
	jmp $0600

; The FujiNet claim: "FUJI", claim version 1, kind 0 (auto), flags 0
	org $FF70
	dc.b "FUJI", 1, 0, 0, 0, 0, 0

	org $FFF8
	dc.b $FF, $C7
	dc.w reset, reset, reset
