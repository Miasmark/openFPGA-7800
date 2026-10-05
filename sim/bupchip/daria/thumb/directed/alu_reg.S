@ Format 4, all 16 operations: AND EOR LSL LSR ASR ADC SBC ROR TST NEG CMP
@ CMN ORR MUL BIC MVN.
@ The ALU operations (and MUL) run on a table of operand pairs, each from
@ four NZCV values (0000, 0110, 1001, 1111): ADC and SBC see C in 0 and 1,
@ the logical operations, TST and MVN pass C and V through, NEG 0 gives
@ C = 1 and NEG 0x80000000 N and V. A MUL leaves C unknown; the SETF that
@ follows it writes C (LSLS #28) before anything reads it.
@ The shifts by register run on a table of (value, amount) pairs: 0 (C
@ kept), 1, 2, 16, 31, 32 (LSL: C = bit 0; LSR, ASR, ROR: C = bit 31, and
@ ROR keeps the value), 33, 64, 255, 256 and 0x12345600 (bits 7:0 are 0:
@ no shift, C kept), 0xFFFFFF20 (32).
@ Then every register in each role (Rd, Rs), a shift with Rd = Rs, and
@ operands written by the instruction just before (the bypass; LATE_RF).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	@ ---- the ALU operations and MUL on the pairs
	ldr	r7, =pairs
	movs	r6, #(pairs_end - pairs) / 8
1:	ldmia	r7!, {r1, r2}
	.irp op, ands, eors, adcs, sbcs, tst, negs, cmp, cmn, orrs, muls, bics, mvns
	.irp f, 0, 6, 9, 15
	movs	r3, r1
	SETF	\f
	\op	r3, r2
	.endr
	.endr
	SIG	r3
	subs	r6, #1
	beq	2f
	b	1b
2:
	@ ---- the shifts by register on (value, amount)
	ldr	r7, =shifts
	movs	r6, #(shifts_end - shifts) / 8
1:	ldmia	r7!, {r1, r2}
	.irp op, lsls, lsrs, asrs, rors
	.irp f, 0, 6, 9, 15
	movs	r3, r1
	SETF	\f
	\op	r3, r2
	.endr
	.endr
	SIG	r3
	subs	r6, #1
	beq	2f
	b	1b
2:
	POOL

	@ ---- every register as Rd and as Rs
	ldr	r0, =0x0f0f0f0f
	ldr	r1, =0x12345678
	ldr	r2, =0x80000003
	movs	r3, #3
	ldr	r4, =0xfedcba98
	movs	r5, #31
	ldr	r6, =0x55aa55aa
	movs	r7, #1
	ands	r0, r7
	eors	r1, r6
	adcs	r2, r5
	sbcs	r3, r4
	tst	r4, r3
	negs	r5, r2
	cmp	r6, r1
	cmn	r7, r0
	orrs	r7, r0
	bics	r6, r1
	mvns	r5, r2
	muls	r4, r3
	lsls	r3, r4			@ by the product's low byte: C written or still unknown
	lsrs	r2, r5
	asrs	r1, r6
	rors	r0, r7
	ldr	r0, =0x80000001
	movs	r1, #1
	movs	r2, #8
	movs	r3, #33
	movs	r4, #32
	movs	r5, #0
	movs	r6, #7
	movs	r7, #255
	lsls	r0, r1
	lsrs	r1, r2
	asrs	r2, r3
	rors	r3, r4
	lsls	r4, r5
	lsrs	r5, r6
	asrs	r6, r7
	rors	r7, r0

	@ ---- Rd = Rs, and an amount or value from the instruction before
	ldr	r0, =0x00000021
	movs	r3, r0
	lsls	r3, r3			@ 0x21 << 33: 0, C = 0
	movs	r3, #5
	lsls	r3, r3
	movs	r3, #24
	rors	r3, r3
	movs	r3, #31
	asrs	r3, r3
	ldr	r1, =0x87654321
	movs	r2, #4
	lsrs	r1, r2
	movs	r2, #36
	lsrs	r1, r2
	ldr	r1, =0x87654321
	asrs	r1, r2
	movs	r2, r1
	rors	r2, r2
	adds	r4, r1, #1
	adcs	r4, r4
	sbcs	r4, r1
	negs	r4, r4
	mvns	r4, r4
	ands	r4, r4
	bics	r4, r4
	END

	.balign 4
pairs:	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x80000000
	.word	0x00000001, 0xffffffff
	.word	0xffffffff, 0x00000001
	.word	0x7fffffff, 0x00000001
	.word	0x80000000, 0x80000000
	.word	0x80000000, 0x00000001
	.word	0x7fffffff, 0x80000000
	.word	0xffffffff, 0xffffffff
	.word	0x12345678, 0x9abcdef0
	.word	0xf0f0f0f0, 0x0ff00ff0
	.word	0x7fffffff, 0x7fffffff
	.word	0x80000001, 0xfffffffe
	.word	0x00010000, 0x00010000
pairs_end:
shifts:	.word	0x80000001, 0
	.word	0x80000001, 1
	.word	0x80000001, 2
	.word	0x80000001, 16
	.word	0x80000001, 31
	.word	0x80000001, 32
	.word	0x80000001, 33
	.word	0x80000001, 64
	.word	0x80000001, 255
	.word	0x80000001, 256
	.word	0x80000001, 0x12345600
	.word	0x80000001, 0xffffff20
	.word	0x40000002, 0
	.word	0x40000002, 1
	.word	0x40000002, 31
	.word	0x40000002, 32
	.word	0x40000002, 33
	.word	0x40000002, 255
	.word	0xc0000003, 1
	.word	0xc0000003, 30
	.word	0xc0000003, 31
	.word	0xc0000003, 32
	.word	0xc0000003, 34
	.word	0xc0000003, 0xffffff20
	.word	0x00000000, 0
	.word	0x00000000, 32
	.word	0x7fffffff, 31
	.word	0x7fffffff, 32
shifts_end:
