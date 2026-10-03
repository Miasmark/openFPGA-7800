@ Encodings the ARM ARM leaves UNPREDICTABLE but the core runs (it halts
@ on the others), checked against the reference: halfword and signed
@ transfers post-indexed with W set; LDR/LDRB with Rm == Rd; LDRH with Rd
@ == Rm and write-back; STR of the base with register-offset write-back
@ (two-clock store, Rd == Rn); MLA with Rd == Rm and Rn == Rd; UMULL with
@ RdLo == Rs. If the core halts on one of these instead, run.sh reports
@ it (that is allowed, but then this file needs the case removed).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	mov	r3, #6
	.macro XHW word, rnval
	add	r2, r12, #\rnval
	.word	\word
	SIG	r0
	SIG	r2
	.endm
	@ cond 1110, P=0, W=1: 0xe0[ui]2.... with L/S/H bits
	XHW	0xe0f200b2, 64		@ ldrh   r0, [r2], #2   with W
	XHW	0xe07200b2, 64		@ ldrh   r0, [r2], #-2  with W
	XHW	0xe0b200b3, 64		@ ldrh   r0, [r2], r3   with W
	XHW	0xe0f200d1, 64		@ ldrsb  r0, [r2], #1   with W
	XHW	0xe0f200f2, 66		@ ldrsh  r0, [r2], #2   with W
	XHW	0xe03200b3, 64		@ ldrh   r0, [r2], -r3  with W
	mvn	r0, #0
	XHW	0xe0e200b2, 128		@ strh   r0, [r2], #2   with W
	XHW	0xe0a200b3, 128		@ strh   r0, [r2], r3   with W
	ldr	r0, [r12, #128]
	SIG	r0
	ldr	r0, [r12, #132]
	SIG	r0
	POOL

	@ Rd == Rm
	mov	r4, #8
	ldr	r4, [r12, r4]
	SIG	r4
	mov	r4, #9
	ldrb	r4, [r12, r4]
	SIG	r4
	mov	r4, #4
	add	r5, r12, #32
	ldrh	r4, [r5, r4]!
	SIG	r4
	SIG	r5
	@ two-clock store of the base, register offset, write-back
	add	r6, r12, #160
	mov	r7, #4
	str	r6, [r6, r7]!
	SIG	r6
	ldr	r0, [r12, #164]
	SIG	r0
	add	r6, r12, #200
	strb	r6, [r6], -r7
	SIG	r6
	ldr	r0, [r12, #200]
	SIG	r0
	@ multiplies with overlapping registers
	ldr	r1, =0x00012345
	ldr	r2, =0x00000107
	mov	r0, r1
	mla	r0, r0, r2, r0			@ Rd == Rm == Rn
	SIG	r0
	mov	r0, r2
	umull	r0, r5, r1, r0			@ RdLo == Rs
	SIG	r0
	SIG	r5
	mov	r5, r1
	umull	r6, r5, r5, r5			@ RdHi == Rm == Rs
	SIG	r6
	SIG	r5

	ldr	r1, =__sig_start
	mov	r0, #0
1:	ldr	r2, [r1], #4
	add	r0, r0, r2
	cmp	r1, r11
	bne	1b
	SIG	r0
	END
