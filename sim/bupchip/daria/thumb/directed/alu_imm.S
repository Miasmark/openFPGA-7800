@ Formats 1-3: shifts by an immediate (F1), ADD/SUB with a register or a
@ 3-bit immediate (F2), MOV/CMP/ADD/SUB with an 8-bit immediate (F3).
@ F1: LSL #0, 1, 2, 15, 31 and LSR/ASR #1, 15, 31, 32 (#32 is encoded as #0,
@ ARIA's normalisation), on operands with bit 31 and bit 0 set and clear,
@ each from NZCV = 0000 and 0011: LSL #0 keeps C, every shift keeps V.
@ (SETF clobbers r0 and lr, so the operand is in r7.)
@ F2 and F3: every form on carry and overflow corners (a table of pairs
@ read with LDMIA from the ROM), ADDS #0 (C = V = 0) and SUBS #0 (C = 1),
@ CMP against 0, 1, 128, 255. MOVS #imm8 from six NZCV values: it sets N
@ and Z and keeps C and V.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	@ ---- F1
	.macro F1 op, amt
	SETF	0
	\op	r1, r7, #\amt
	SETF	3
	\op	r2, r7, #\amt
	.endm

	.irp v, 0x80000001, 0x7ffffffe, 0x40000000, 0xffffffff, 0x00000000, 0x00000001
	ldr	r7, =\v
	.irp a, 0, 1, 2, 15, 31
	F1	lsls, \a
	.endr
	.irp a, 1, 15, 31, 32
	F1	lsrs, \a
	F1	asrs, \a
	.endr
	SIG	r1
	POOL
	.endr

	@ every register as source and destination once
	ldr	r0, =0x81234567
	lsls	r7, r0, #4
	lsrs	r6, r7, #3
	asrs	r5, r6, #2
	lsls	r4, r5, #1
	lsrs	r3, r4, #5
	asrs	r2, r3, #6
	lsls	r1, r2, #7
	lsrs	r0, r1, #8
	asrs	r0, r0, #9

	@ ---- F2 and F3 on the corners
	ldr	r7, =pairs
	movs	r6, #(pairs_end - pairs) / 8
1:	ldmia	r7!, {r1, r2}
	adds	r3, r1, r2
	subs	r3, r1, r2
	subs	r4, r2, r1
	adds	r5, r2, r1
	adds	r3, r1, #0
	subs	r3, r1, #0
	adds	r3, r1, #7
	subs	r3, r1, #7
	adds	r3, r1, #1
	subs	r3, r1, #1
	adds	r3, r2, #4
	subs	r3, r2, #3
	movs	r3, r1
	adds	r3, #255
	movs	r3, r1
	subs	r3, #255
	movs	r3, r1
	adds	r3, #1
	movs	r3, r1
	subs	r3, #1
	movs	r3, r1
	adds	r3, #0
	movs	r3, r1
	subs	r3, #0
	cmp	r1, #0
	cmp	r1, #1
	cmp	r1, #128
	cmp	r1, #255
	cmp	r2, #0
	SIG	r3
	subs	r6, #1
	bne	1b

	@ every low register in each F2/F3 position
	movs	r0, #1
	movs	r1, #2
	movs	r2, #3
	movs	r3, #4
	movs	r4, #5
	movs	r5, #6
	movs	r6, #7
	movs	r7, #8
	adds	r0, r7, r6
	subs	r1, r6, r5
	adds	r2, r5, r4
	subs	r3, r4, r3
	adds	r4, r3, r2
	subs	r5, r2, r1
	adds	r6, r1, r0
	subs	r7, r0, r7
	adds	r7, r6, #5
	subs	r6, r5, #6
	adds	r7, #200
	subs	r6, #100
	cmp	r5, #2
	cmp	r4, #7
	cmp	r3, #9
	cmp	r2, #250

	@ ---- MOVS #imm8 keeps C and V; ADDS #0 clears them
	.irp f, 0, 1, 2, 3, 12, 15
	SETF	\f
	movs	r3, #0
	SETF	\f
	movs	r4, #0x80
	SETF	\f
	movs	r5, #255
	SETF	\f
	adds	r6, r5, #0
	SETF	\f
	subs	r6, r5, #0
	SETF	\f
	adds	r6, #0
	.endr
	END

	.balign 4
pairs:	.word	0x00000000, 0x00000000
	.word	0x00000000, 0x00000001
	.word	0x00000001, 0xffffffff
	.word	0xffffffff, 0x00000001
	.word	0x7fffffff, 0x00000001
	.word	0x80000000, 0x80000000
	.word	0x80000000, 0x00000001
	.word	0x7fffffff, 0x80000000
	.word	0xffffffff, 0xffffffff
	.word	0x12345678, 0x9abcdef0
	.word	0x000000ff, 0x00000001
	.word	0xffffff01, 0x7fffffff
	.word	0x00000007, 0x00000007
	.word	0x80000006, 0x00000007
	.word	0x00000080, 0x00000080
	.word	0xfffffffd, 0x00000003
pairs_end:
