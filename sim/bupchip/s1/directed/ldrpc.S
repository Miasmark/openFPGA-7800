@ Control flow: the firmware's jump table (add r3, pc, #4; ldr pc,
@ [r3, r2, lsl #2]); LDR pc from a literal and with post-index write-back;
@ a condition-failed LDR pc; mov lr, pc (r15 reads as the address + 8);
@ BL and BX lr, conditional BX taken and not; B forward and back;
@ branches to the next instruction.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	mov	r7, #0
	mov	r2, #0
1:	add	r3, pc, #4			@ as at firmware 0x1e4-0x1ec
	and	r1, r2, #3
	ldr	pc, [r3, r1, lsl #2]
	.word	case0, case1, case2, case3
case0:	add	r7, r7, #1
	b	2f
case1:	add	r7, r7, #0x10
	b	2f
case2:	add	r7, r7, #0x100
	b	2f
case3:	add	r7, r7, #0x1000
2:	SIG	r7
	add	r2, r2, #1
	cmp	r2, #6
	bne	1b

	ldr	pc, =3f
	b	.
3:	ldr	r4, =ptrs
	ldr	pc, [r4], #4
	b	.
4:	SIG	r4
	ldr	pc, [r4, #4]!
	b	.
5:	SIG	r4
	movs	r0, #0
	ldrne	pc, =.				@ fails: no jump
	SIG	r0
	mov	lr, pc
	b	6f
	b	7f				@ lr points here
6:	SIG	lr
	bx	lr
7:	bl	sub1
	SIG	r0
	movs	r1, #1
	ldr	r2, =8f
	bxeq	r2				@ not taken
	bxne	r2				@ taken
	b	.
8:	b	9f
9:	add	r0, pc, #0
	SIG	r0
	sub	r0, pc, #-8
	SIG	r0
	b	10f
sub1:	add	r0, pc, lr
	bx	lr
ptrs:	.word	4b, 0, 5b
10:
	END
