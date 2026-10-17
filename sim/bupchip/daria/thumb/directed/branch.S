@ Formats 16 and 18: B<cond> and B.
@ Every condition (EQ to LE; 1110 and 1111 are the halt tests' and SWI)
@ from all 16 NZCV values, taken and not taken (the next retire's PC shows
@ which). Taken branches to both halves of a word, from both halves. The
@ range limits: B<cond> by +254 and -256 bytes (imm8 0x7F and 0x80), B by
@ +2046 and -2048 (imm11 0x3FF and 0x400), and branches by +0 (to the next
@ instruction but one, the "B .+4" shape) and to themselves only once
@ through (a loop). Filler that must never run is 0xDE00, which halts DARIA
@ and is undefined on the reference.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	.macro CONDS				@ every condition, each over a NOP
	.irp c, eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le
	b\c	1f
	nop
1:
	.endr
	.endm

	.irp f, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
	SETF	\f
	CONDS
	.endr

	@ ---- flags from arithmetic, then each condition taken backwards
	movs	r1, #3
	ldr	r2, =0x7fffffff
	.irp c, eq, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le
	b	2f
1:	adds	r1, #0			@ landed: Z = 0, C = 0, V = 0
	b	3f
2:	cmp	r1, r2			@ 3 - 0x7FFFFFFF: N, C clear, V clear
	b\c	1b
	nop
3:
	.endr
	POOL

	@ ---- taken branches from and to both halves of a word
	.balign 4
	b	h_hi			@ from the low half, to a high half
	.hword	0xde00
	.hword	0xde00
h_hi:	b	h_lo			@ from the high half, to a low half
	.hword	0xde00
	.balign 4
h_lo:	movs	r0, #0
	beq	h_hi2			@ high to high
	.hword	0xde00
h_hi2:	beq	h_lo2			@ high to low
	.hword	0xde00
	.hword	0xde00
h_lo2:	beq	h_lo3			@ low to low
	.hword	0xde00
	.hword	0xde00
	.hword	0xde00
h_lo3:	movs	r0, #1

	@ ---- B<cond> by +254: imm8 0x7F
	movs	r0, #0
	beq	c_fwd
	.fill	128, 2, 0xde00
c_fwd:	nop
	@ ---- B<cond> by -256: imm8 0x80
	cmp	r0, #0
	b	c_src
c_dst:	b	c_done
	.fill	125, 2, 0xde00
c_src:	beq	c_dst
	.hword	0xde00
c_done:
	@ ---- B by +2046: imm11 0x3FF
	b	b_fwd
	.fill	1024, 2, 0xde00
b_fwd:	nop
	@ ---- B by -2048: imm11 0x400
	b	b_src
b_dst:	b	b_done
	.fill	1021, 2, 0xde00
b_src:	b	b_dst
	.hword	0xde00
b_done:
	@ ---- by +0 (the next instruction but one), conditional and not
	b	1f
	.hword	0xde00
1:	movs	r0, #0
	bne	1f
	beq	1f
1:	.hword	0xd000			@ beq .+4: imm8 0, taken
	.hword	0xde00
	.hword	0xd100			@ bne .+4: imm8 0, not taken
	.hword	0xe000			@ b .+4
	.hword	0xde00
	@ ---- a backward loop, 5 times round
	movs	r1, #5
1:	subs	r1, #1
	bne	1b
	@ ---- the conditions after real flag producers
	movs	r1, #0
	subs	r1, #1			@ N, C clear
	CONDS
	adds	r1, #1			@ Z, C
	CONDS
	ldr	r2, =0x7fffffff
	adds	r2, #1			@ N, V
	CONDS
	lsrs	r2, r2, #32		@ Z, C = bit 31
	CONDS
	END
