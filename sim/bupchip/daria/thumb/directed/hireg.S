@ Format 5 without BX (bx.S has it): ADD, CMP and MOV on r0-r15, in every
@ H combination that runs (H1 H2 = 01, 10, 11; 00 halts, halt_thumb.py),
@ with r8-r12, SP, LR and PC on each side:
@   PC as the source reads the instruction's address + 4, not aligned, at
@   either alignment; CMP with PC on either side, and CMP PC, PC;
@   PC as the destination: MOV pc and ADD pc jump to the value with bit 0
@   cleared and stay in Thumb (T is compared at every retire), to either
@   half of a word, with bit 0 set and clear; MOV pc, pc and ADD pc, pc.
@ ADD and MOV set no flags, CMP sets all four. Values written by the
@ instruction just before are read through the bypass (LATE_RF).
@ GAS refuses CMP with PC, so those are .hword.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	ldr	r0, =0x11111111
	mov	r8, r0
	ldr	r0, =0x7fffffff
	mov	r9, r0
	ldr	r0, =0x80000000
	mov	r10, r0
	ldr	r0, =0xfffffff0
	mov	r12, r0
	ldr	r0, =0x00000123
	mov	lr, r0
	movs	r1, #1
	movs	r2, #2
	movs	r3, #0x80
	SETF	0

	@ ---- ADD, H1 H2 = 01: Rd low, Rs high
	add	r1, r8
	add	r1, r9
	add	r1, r10
	add	r1, r12
	add	r1, sp
	add	r1, lr
	.balign 4
	add	r1, pc			@ address 0 mod 4
	add	r2, pc			@ 2 mod 4
	add	r4, r9			@ r4 = 0 + r9
	@ ---- ADD, 10: Rd high, Rs low
	add	r8, r1
	add	r9, r2
	add	r10, r3
	add	r12, r4
	add	lr, r1
	movs	r3, #16
	add	sp, r3			@ SP + 16, then back
	mov	r5, sp
	negs	r3, r3
	add	sp, r3
	mov	r6, sp
	@ ---- ADD, 11: both high
	add	r8, r9
	add	r9, r8
	add	r10, r12
	add	r12, r12
	add	lr, r8
	add	r8, sp
	.balign 4
	add	r9, pc			@ 0 mod 4
	add	r10, pc			@ 2 mod 4
	mov	r12, sp
	add	sp, r8			@ SP + r8, then back
	mov	r5, sp
	mov	sp, r12
	add	r8, lr

	@ ---- CMP in each combination, flags compared at every retire
	ldr	r0, =0x80000000
	mov	r9, r0
	movs	r1, #1
	cmp	r1, r9			@ 01
	cmp	r1, r8
	cmp	r1, sp
	cmp	r1, lr
	cmp	r9, r1			@ 10
	cmp	r8, r1
	cmp	sp, r1
	cmp	lr, r1
	cmp	r8, r9			@ 11
	cmp	r9, r8
	cmp	r9, r9
	cmp	sp, r8
	cmp	r8, sp
	cmp	lr, sp
	.balign 4
	.hword	0x4578			@ cmp r0, pc (01), 0 mod 4
	.hword	0x4579			@ cmp r1, pc, 2 mod 4
	.hword	0x4587			@ cmp pc, r0 (10), 0 mod 4
	.hword	0x458f			@ cmp pc, r1, 2 mod 4
	.hword	0x45c7			@ cmp pc, r8 (11), 0 mod 4
	.hword	0x45f8			@ cmp r8, pc (11), 2 mod 4
	.hword	0x45ff			@ cmp pc, pc, 0 mod 4: Z, C
	.hword	0x45ff			@ cmp pc, pc, 2 mod 4
	ldr	r0, =0x0000ffff
	mov	r10, r0
	.hword	0x45d7			@ cmp pc, r10 (11)
	.hword	0x45fa			@ cmp r10, pc (11)
	.hword	0x45ef			@ cmp pc, sp (11)
	.hword	0x45fe			@ cmp lr, pc (11)
	POOL

	@ ---- MOV, 01, 10, 11 (no flags: they stay as the CMP left them)
	mov	r1, r8			@ 01
	mov	r2, r9
	mov	r3, sp
	mov	r4, lr
	.balign 4
	mov	r5, pc			@ 0 mod 4
	mov	r6, pc			@ 2 mod 4
	mov	r8, r1			@ 10
	mov	r9, r2
	mov	r10, r5
	mov	r12, r6
	mov	lr, r4
	mov	r8, r9			@ 11
	mov	r9, r10
	mov	r10, r12
	mov	r12, lr
	mov	lr, r8
	mov	r11, r11		@ the signature pointer, unchanged
	.balign 4
	mov	r8, pc			@ 0 mod 4
	mov	r9, pc			@ 2 mod 4
	mov	r10, sp
	mov	r12, sp
	mov	sp, r12

	@ ---- MOV pc, Rm: bit 0 set and clear, to both halves; T stays 1
	ldr	r0, =m1 + 1		@ odd: bit 0 dropped
	mov	pc, r0			@ 10
	.hword	0xde00
	.balign 4
m1:	ldr	r0, =m2			@ even
	mov	pc, r0
	.hword	0xde00
	.hword	0xde00
	.balign 4
	.hword	0xde00
m2:	ldr	r0, =m3 + 1		@ m2 is the high half; m3 too
	mov	r9, r0
	mov	pc, r9			@ 11
	.hword	0xde00
	.balign 4
	.hword	0xde00
m3:	ldr	r1, =m4
	mov	lr, r1
	mov	pc, lr			@ LR as the source
	.hword	0xde00
	.balign 4
m4:	mov	pc, pc			@ 0 mod 4: to address + 4
	.hword	0xde00
	nop
	mov	pc, pc			@ 2 mod 4: to address + 4
	.hword	0xde00
	POOL

	@ ---- ADD pc, Rm: PC reads address + 4; the sum, bit 0 cleared
	.balign 4
	.equ	d_addpc1, addpc1 - addpc1p - 4 + 1
	ldr	r0, =d_addpc1		@ odd sum
addpc1p:	add	pc, r0			@ 2 mod 4
	.hword	0xde00
	.hword	0xde00
	.equ	d_addpc2, addpc2 - addpc2p - 4
addpc1:	ldr	r0, =d_addpc2
	mov	r8, r0
	.balign 4
addpc2p:	add	pc, r8			@ 11, 0 mod 4, to a high half
	.hword	0xde00
	.hword	0xde00
	.hword	0xde00
	.equ	d_addpc3, addpc3 - addpc3p - 4 + 1
addpc2:	ldr	r0, =d_addpc3
	mov	r9, r0
addpc3p:	add	pc, r9
	.hword	0xde00
	.balign 4
	.hword	0xde00
addpc3:	movs	r0, #2			@ by +2 + 4: one halfword skipped
	.balign 4
	add	pc, r0			@ 0 mod 4, to the next one
	.hword	0xde00
	.hword	0xde00
	add	pc, r0			@ 2 mod 4
	.hword	0xde00
	.hword	0xde00
	movs	r0, #0			@ by +0: the next but one
	add	pc, r0
	.hword	0xde00
	ldr	r0, =app
	mov	pc, r0
	POOL

	@ ---- ADD pc, pc at 0xE02 jumps to 2 x (0xE02 + 4) = 0x1C0C
	.org	0xe02 - 0x20
app:	add	pc, pc
	.hword	0xde00
	.org	0x1c0c - 0x20
	movs	r0, #1
	END
