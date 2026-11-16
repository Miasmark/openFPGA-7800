; FujiNet mailbox test for the Pocket core (dasm). The cart claims the
; FujiNet mailbox ("FUJI" at $FF70), so the core serves it at $0800-$0FFF
; and puts its FujiBus serial line on the link port (fujinet_mailbox.sv).
; It shows the mailbox's status page, then runs one transaction,
; GET_ADAPTERCONFIG_EXTENDED ($C4) to the FujiNet ($70), as the FujiNet
; firmware's own test ROM does (testrom/fujitest.s), and shows the result:
;   - nothing on the link port: ERR 01 NO LINK after about 1.5 s;
;   - link pins 2 (SO) and 3 (SI) joined: the cart hears its own request,
;     a good frame with command $C4: REPLY C4, LOOPBACK, ERR 00;
;   - a FujiNet on a serial adapter: ERR 00, REPLY 06 (ACK), and its SSID,
;     IP address and firmware version.
; Fire or Reset runs the transaction again.
; Build: python3 fn_font.py > fn_font.inc; dasm fn_test.asm -f3 -ofn_test.bin;
; sim/make_a78.py --bin fn_test.bin > fn_test.a78; sign it for a console.
; SPDX-License-Identifier: MIT

	processor 6502

INPTCTRL = $01
INPT4    = $0C
BACKGRND = $20
P0C1     = $21
P0C2     = $22
P0C3     = $23
MSTAT    = $28
DPPH     = $2C
DPPL     = $30
CHARBASE = $34
CTRL     = $3C
SWCHB    = $0282

; The mailbox (fujinet-firmware pico/atari-7800 fuji_mailbox.h)
FN_DATA    = $0800
FN_ACKSEQ  = $0C00
FN_STATUS  = $0C01
FN_ERR     = $0C02
FN_RCMD    = $0C03
FN_RXLO    = $0C04
FN_RXHI    = $0C05
FN_MAGIC   = $0C09
FN_PROTO   = $0C0B
FN_MODE    = $0C12
FN_LINK    = $0C15
FN_TV      = $0C1E
FN_REGSEL  = $0D00
REG_DEVICE = $00
REG_CMD    = $01
REG_NPARAM = $02
REG_RST    = $05
REG_SEQ    = $10

TEXT     = $1800        ; 24 rows of 32 characters
ROWS     = 24

ptr      = $80
dst      = $82
seq      = $84
frames   = $85          ; 2 bytes
col      = $87
len      = $88

	MAC PRINT               ; row, column, string
	lda #{1}
	ldx #{2}
	jsr at
	lda #<{3}
	ldy #>{3}
	jsr puts
	ENDM

	MAC AT
	lda #{1}
	ldx #{2}
	jsr at
	ENDM

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
clrzp
	sta $00,x
	inx
	bne clrzp
	lda #" "                ; blank screen
	ldx #0
clrtx
	sta TEXT,x
	sta TEXT+$100,x
	sta TEXT+$200,x
	inx
	bne clrtx
	lda #$00
	sta BACKGRND
	lda #$0F
	sta P0C1
	sta P0C2
	sta P0C3
	lda #FONT
	sta CHARBASE
	jsr frame
	lda #>dll
	sta DPPH
	lda #<dll
	sta DPPL
	lda #$43                ; DMA on, 320A/C, one-byte characters
	sta CTRL

	PRINT 1, 4, t_title
	lda FN_MAGIC
	cmp #"F"
	bne nomb
	lda FN_MAGIC+1
	cmp #"N"
	beq havemb
nomb
	PRINT 3, 1, t_nomb
halt
	jmp halt

havemb
	PRINT 3, 1, t_proto
	lda FN_PROTO
	jsr puthex
	PRINT 3, 11, t_mode
	lda FN_MODE
	jsr puthex
	PRINT 3, 20, t_tv
	lda FN_TV
	jsr puthex

; ------------------------------------------------------------ the transaction
txn
	ldx #6
	jsr clrrows
	PRINT 6, 1, t_send
	lda #$70                ; FujiNet
	ldx #REG_DEVICE
	sta FN_REGSEL,x         ; one store a register; never read-modify-write
	lda #$C4                ; GET_ADAPTERCONFIG_EXTENDED
	ldx #REG_CMD
	sta FN_REGSEL,x
	lda #0
	ldx #REG_NPARAM
	sta FN_REGSEL,x
	ldx #REG_RST
	sta FN_REGSEL,x
	lda FN_ACKSEQ           ; SEQ = ACKSEQ + 1, never 0
	clc
	adc #1
	bne seqok
	lda #1
seqok
	sta seq
	ldx #REG_SEQ
	sta FN_REGSEL,x
	lda #0
	sta frames
	sta frames+1
wait
	jsr frame
	inc frames
	bne wt1
	inc frames+1
wt1
	AT 6, 20
	lda frames+1
	jsr puthex
	lda frames
	jsr puthex
	lda FN_ACKSEQ
	cmp seq
	beq done
	lda frames+1
	cmp #4                  ; 1024 frames: give up
	bcc wait
	PRINT 7, 1, t_noans
	jmp again

done
	PRINT 6, 26, t_frm
	PRINT 8, 1, t_ack
	lda FN_ACKSEQ
	jsr puthex
	PRINT 8, 12, t_err
	lda FN_ERR
	jsr puthex
	lda #" "
	jsr putc
	lda FN_ERR
	cmp #5
	bcc errok
	lda #5
errok
	asl
	tax
	lda errtab,x
	ldy errtab+1,x
	jsr puts

	PRINT 9, 1, t_reply
	lda FN_RCMD
	jsr puthex
	lda #" "
	jsr putc
	lda FN_RCMD
	ldx #<t_ackw
	ldy #>t_ackw
	cmp #$06
	beq rc
	ldx #<t_nak
	ldy #>t_nak
	cmp #$15
	beq rc
	ldx #<t_loop
	ldy #>t_loop
	cmp #$C4
	beq rc
	ldx #<t_blank
	ldy #>t_blank
rc
	txa
	jsr puts
	PRINT 9, 20, t_rxlen
	lda FN_RXHI
	jsr puthex
	lda FN_RXLO
	jsr puthex

	PRINT 10, 1, t_stat
	lda FN_STATUS
	jsr puthex
	PRINT 10, 12, t_link
	lda FN_LINK
	jsr puthex

	lda FN_ERR              ; the adapter config, from a FujiNet's ACK
	bne again
	lda FN_RCMD
	cmp #$06
	bne again
	PRINT 12, 1, t_ssid
	ldx #0                  ; ssid: char[33] at 0
	lda #26
	jsr rstr
	PRINT 13, 1, t_ip
	ldx #140                ; the IP as text: char[16] at 140
	lda #16
	jsr rstr
	PRINT 14, 1, t_fw
	ldx #125                ; firmware version: char[15] at 125
	lda #15
	jsr rstr

again
	PRINT 20, 1, t_again
rel
	jsr frame
	jsr button
	bne rel
press
	jsr frame
	jsr button
	beq press
	jmp txn

; ------------------------------------------------------------ routines
; A = 1 (Z clear) while fire or Reset is held
button
	lda INPT4
	bpl bdown
	lda SWCHB
	and #$01
	beq bdown
	lda #0
	rts
bdown
	lda #1
	rts

; wait for the start of the next vblank
frame
	lda MSTAT
	bmi frame
fr1
	lda MSTAT
	bpl fr1
	rts

; dst = TEXT + 32 * A + X
at
	stx col
	pha
	lsr
	lsr
	lsr
	clc
	adc #>TEXT
	sta dst+1
	pla
	asl
	asl
	asl
	asl
	asl
	clc
	adc col
	sta dst
	rts

; print the string at A (low), Y (high)
puts
	sta ptr
	sty ptr+1
	ldy #0
ps1
	lda (ptr),y
	beq ps2
	sta (dst),y
	iny
	bne ps1
ps2
	tya
	clc
	adc dst
	sta dst
	rts

putc
	ldy #0
	sta (dst),y
	inc dst
	rts

puthex
	pha
	lsr
	lsr
	lsr
	lsr
	jsr hex1
	pla
	and #$0F
hex1
	tax
	lda hexd,x
	jmp putc

; print reply bytes from offset X, at most A of them, up to a 0
rstr
	sta len
rs1
	lda FN_DATA,x
	beq rs3
	cmp #$60
	bcc rs2
	sbc #$20                ; lower case as upper
rs2
	cmp #$20
	bcc rsdot
	cmp #$60
	bcc rsput
rsdot
	lda #"."
rsput
	stx col
	jsr putc
	ldx col
	inx
	dec len
	bne rs1
rs3
	rts

; blank rows X to 23
clrrows
	txa
	pha
	ldx #0
	jsr at
	ldy #0
	lda #" "
cr1
	sta (dst),y
	iny
	cpy #32
	bne cr1
	pla
	tax
	inx
	cpx #ROWS
	bne clrrows
	rts

hexd	dc.b "0123456789ABCDEF"
t_title	dc.b "FUJINET MAILBOX TEST", 0
t_nomb	dc.b "NO MAILBOX AT $0C09", 0
t_proto	dc.b "PROTO ", 0
t_mode	dc.b "MODE ", 0
t_tv	dc.b "TV ", 0
t_send	dc.b "ADAPTER CONFIG..", 0
t_frm	dc.b "FRMS", 0
t_noans	dc.b "NO ACKSEQ ECHO", 0
t_ack	dc.b "ACKSEQ ", 0
t_err	dc.b "ERR ", 0
t_reply	dc.b "REPLY ", 0
t_rxlen	dc.b "RXLEN ", 0
t_stat	dc.b "STATUS ", 0
t_link	dc.b "LINK ", 0
t_ssid	dc.b "SSID ", 0
t_ip	dc.b "IP   ", 0
t_fw	dc.b "FW   ", 0
t_again	dc.b "FIRE OR RESET: AGAIN", 0
t_ackw	dc.b "ACK", 0
t_nak	dc.b "NAK", 0
t_loop	dc.b "LOOPBACK", 0
t_blank	dc.b 0
e_ok	dc.b "OK", 0
e_nolink dc.b "NO LINK", 0
e_tmo	dc.b "TIMEOUT", 0
e_bad	dc.b "BAD FRAME", 0
e_big	dc.b "TOO BIG", 0
e_unk	dc.b "?", 0
errtab	dc.w e_ok, e_nolink, e_tmo, e_bad, e_big, e_unk

; ------------------------------------------------------------ display
; Row R's display list: two indirect headers of 16 characters, 320A
	org $D000
R	SET 0
	REPEAT ROWS
	dc.b <(TEXT+R*32), $60, >(TEXT+R*32), $10, 16
	dc.b <(TEXT+R*32+16), $60, >(TEXT+R*32+16), $10, 80
	dc.b 0, 0, 0, 0, 0, 0
R	SET R+1
	REPEND

	org $D200
dll
	REPEAT 2
	dc.b $0F, >empty, <empty
	REPEND
R	SET 0
	REPEAT ROWS
	dc.b $07, >($D000+R*16), <($D000+R*16)
R	SET R+1
	REPEND
	REPEAT 4
	dc.b $0F, >empty, <empty
	REPEND
empty	dc.b 0, 0

	include "fn_font.inc"

; The FujiNet claim: "FUJI", claim version 1, kind 0 (auto), flags 0
	org $FF70
	dc.b "FUJI", 1, 0, 0, 0, 0, 0

	org $FFF8
	dc.b $FF, $C7
	dc.w reset
	dc.w reset
	dc.w reset
