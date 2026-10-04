@ MUL, MLA and UMULL corners: 0, 1, -1, 0x80000000, 0x7fffffff and mixed
@ patterns in every pairing; MLA wrapping; flags untouched (no S); MLA with
@ Rd == Rn and Rd == Rs; MUL with Rd == Rm and UMULL with RdLo or RdHi ==
@ Rm or Rs, which ARMv4 leaves UNPREDICTABLE and the core implements as the
@ ARM7TDMI does (the plain product); operands loaded in the clock before.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r9, =vals
	mov	r7, #0
1:	ldr	r1, [r9, r7, lsl #2]
	mov	r6, #0
2:	ldr	r2, [r9, r6, lsl #2]
	ldr	r3, [r9, #8]
	SETF	9
	mul	r0, r1, r2
	SIG	r0
	mla	r0, r1, r2, r3
	SIG	r0
	umull	r4, r5, r1, r2
	SIG	r4
	SIG	r5
	SIGF
	add	r6, r6, #1
	cmp	r6, #8
	bne	2b
	add	r7, r7, #1
	cmp	r7, #8
	bne	1b

	ldr	r1, =0x12345678
	ldr	r2, =0x9abcdef1
	ldr	r3, =0xfffffff0
	mov	r4, r3
	mla	r4, r1, r2, r4			@ Rd == Rn
	SIG	r4
	mov	r4, r2
	mla	r4, r1, r4, r3			@ Rd == Rs
	SIG	r4
	mov	r4, r2
	mul	r4, r1, r4			@ Rd == Rs
	SIG	r4
	mov	r4, r1
	mul	r4, r4, r2			@ Rd == Rm
	SIG	r4
	mov	r4, r1
	mla	r4, r4, r2, r3			@ Rd == Rm
	SIG	r4
	mov	r4, r1
	umull	r4, r5, r4, r2			@ RdLo == Rm
	SIG	r4
	SIG	r5
	mov	r5, r1
	umull	r4, r5, r5, r2			@ RdHi == Rm
	SIG	r4
	SIG	r5
	mov	r4, r2
	umull	r4, r5, r1, r4			@ RdLo == Rs
	SIG	r4
	SIG	r5
	mov	r5, r2
	umull	r4, r5, r1, r5			@ RdHi == Rs
	SIG	r4
	SIG	r5
	@ operands straight from loads
	str	r1, [r12, #0]
	str	r2, [r12, #4]
	str	r3, [r12, #8]
	ldr	r6, [r12, #0]
	mul	r0, r6, r2
	SIG	r0
	ldr	r6, [r12, #4]
	mul	r0, r1, r6
	SIG	r0
	ldr	r6, [r12, #8]
	mla	r0, r1, r2, r6
	SIG	r0
	ldr	r6, [r12, #4]
	umull	r7, r8, r1, r6
	add	r0, r8, r7			@ both halves used at once
	SIG	r0
	b	3f
vals:
	.word	0, 1, 0xffffffff, 0x80000000, 0x7fffffff, 0x12345678, 0xfedcba98, 0x0000ffff
3:
	END
