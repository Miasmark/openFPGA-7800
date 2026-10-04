; Supercharger loader stub for the Pocket core (POCKET_SUPERCHARGER).
;
; With no supercharger.bin, mapper_AR's 2 KiB BIOS ROM holds this instead.
; It loads a game the way the BIOS does, but straight from the .bin file
; through a port in mapper_AR, not from a tape signal: about 0.1 s for a
; full load. It is our own code, written from the BIOS's behaviour as
; documented in docs/SUPERCHARGER_FASTLOAD.md. MIT licence, as the rest of
; the Pocket's own sources.
;
; The game sees what the BIOS leaves:
;   - the load number in $80;
;   - the load's pages in the Supercharger RAM;
;   - TIA registers $04-$2C and RAM $81-$9D cleared;
;   - the header's control byte set (bank layout, write enable);
;   - A from the RIOT timer, X = $FF, Y = 0, SP = $FF;
;   - a jump to the header's start address.
; At power-up and reset it loads load 0; a multiload game asks for a load by
; putting its number in $FA and jumping to $F800.
;
; Build (the assembled file is committed, so a core build needs no dasm):
;   dasm ar_stub.asm -f3 -oar_stub.bin && python3 ../../../tools/bin2mem.py ar_stub.bin

	processor 6502

; Zero page. $81-$9D are cleared before the game starts; nothing above
; them is touched until then, because a multiload game keeps its state
; there. $FA-$FF hold the last few instructions (see "go").
LOADNUM	= $80
INFO	= $81
LAST	= $82		; last image in the file (0-3)
IMG	= $83		; image being looked at / loaded
TRIES	= $84
CTL	= $85		; header: control byte
STLO	= $86		; header: start address
STHI	= $87
COUNT	= $88		; header: page count
PAGE	= $89
IMG6	= $8A		; IMG << 6, for the image select port
PTR	= $8B		; and $8C: the RAM page being written
MAP	= $8D

; TIA and RIOT
VSYNC	= $00
VBLANK	= $01
WSYNC	= $02
COLUBK	= $09
INTIM	= $0284

; Supercharger
RAMSEL	= $F000		; read $F0xx: the data hold register takes xx
CTRL	= $FFF8		; read: the control register takes the data hold register

; mapper_AR's port, in the ROM's address space, only without a BIOS file.
; These pages hold no code.
SELHI	= $F900		; read $F9xx: image xx >> 6, pointer bits 13:8 = xx & $3F
SELLO	= $FA00		; read $FAxx: pointer bits 7:0 = xx
DATA	= $FB00		; read: the image byte at the pointer; the pointer steps on
INFOP	= $FB01		; read: bits 5:4 the tape position, bits 1:0 the last image
SETPOS	= $FC00		; read $FC0x: the tape position becomes x

	seg code
	org $F800

; ---------------------------------------------------------------- multiload
; The game has put the load number in $FA and switched this ROM in.
multiload:
	cld
	lda $FA
	sta LOADNUM
	jmp load

	org $FD00

; ---------------------------------------------------------------- reset
reset:
	sei
	cld
	ldx #0
	txa
.clear	sta 0,x			; TIA and RAM, LOADNUM = 0
	inx
	bne .clear

; ---------------------------------------------------------------- load
; Find the load: start at the tape position (the image after the last one
; loaded) and take the first image with this load number, wrapping at the
; end of the file, as a tape would. Party Mix and Sweat number every image
; 0 and rely on this order.
load:
	lda INFOP
	sta INFO
	and #3
	sta LAST
	sta TRIES
	lda INFO
	lsr
	lsr
	lsr
	lsr
	and #3
	sta IMG

find:
	lda IMG
	asl
	asl
	asl
	asl
	asl
	asl
	sta IMG6
	ora #$20		; pointer $2005: the header's load number
	tay
	lda SELHI,y
	lda SELLO+5
	nop			; give the port time to fetch the byte
	nop
	lda DATA
	cmp LOADNUM
	beq found
	ldx IMG			; next image, wrapping
	cpx LAST
	bne .next
	ldx #$FF
.next	inx
	stx IMG
	dec TRIES
	bpl find
	jmp notfound

found:
	lda SELLO		; pointer $2000: start address, control byte, page count
	nop
	nop
	lda DATA
	sta STLO
	lda DATA
	sta STHI
	lda DATA
	sta CTL
	lda DATA
	sta COUNT

	lda #0
	sta PAGE
page:
	lda IMG6		; pointer $2010 + PAGE: this page's map byte
	ora #$20
	tay
	lda SELHI,y
	lda PAGE
	clc
	adc #$10
	tay
	lda SELLO,y
	nop
	nop
	lda DATA		; bank in bits 1:0, page in bits 4:2
	sta MAP
	and #3
	tax
	ldy ctltab,x		; that bank at $F000, this ROM at $F800, writes on
	cmp RAMSEL,y
	cmp CTRL
	lda MAP
	lsr
	lsr
	and #7
	ora #$F0
	sta PTR+1
	lda #0
	sta PTR
	lda IMG6		; pointer PAGE * 256: the page's data
	ora PAGE
	tay
	lda SELHI,y
	lda SELLO
	ldy #0
	nop
.copy	lda DATA		; 4 cycles
	tax			; 2
	cmp RAMSEL,x		; 4: the data hold register takes the byte
	cmp (PTR),y		; 5: its fifth access, the target, is written
	iny
	bne .copy
	inc PAGE
	lda PAGE
	cmp COUNT
	bne page

	ldx IMG			; the tape now stands at the next image
	cpx LAST
	bne .pos
	ldx #$FF
.pos	inx
	lda SETPOS,x

; ---------------------------------------------------------------- go
; Switching the control byte can take this ROM away, so the last two
; instructions run from RAM: CMP $FFF8 / JMP start, at $FA-$FF.
	lda #$CD
	sta $FA
	lda #<CTRL
	sta $FB
	lda #>CTRL
	sta $FC
	lda #$4C
	sta $FD
	lda STLO
	sta $FE
	lda STHI
	sta $FF
	ldy CTL			; Y keeps the control byte through the clearing
	lda #0
	ldx #$9D-$81
.ram	sta $81,x
	dex
	bpl .ram
	ldx #$2C-$04
.tia	sta $04,x
	dex
	bpl .tia
	cmp RAMSEL,y		; data hold register = control byte
	ldx #$FF
	txs
	ldy #0
	lda INTIM
	jmp $00FA

; ---------------------------------------------------------------- not found
; The file has no image with this load number: a red screen.
notfound:
	lda #0
	sta VBLANK
	lda #$44
	sta COLUBK
.frame	lda #2
	sta VSYNC
	sta WSYNC
	sta WSYNC
	sta WSYNC
	lda #0
	sta VSYNC
	ldx #259-256
.top	sta WSYNC
	dex
	bne .top
.rest	sta WSYNC		; X = 0: 256 lines
	dex
	bne .rest
	jmp .frame

; Control bytes for writing bank 0, 1 or 2: bank configuration 1, 5 or 0
; (that bank at $F000, the ROM at $F800), write enable on, ROM on.
ctltab	.byte $06, $16, $02

	org $FFFA
	.word reset		; NMI (the 6507 has none)
	.word reset		; reset
	.word reset		; IRQ
