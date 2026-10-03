@ Every flag source against every condition: all 16 NZCV values through
@ MSR CPSR_f, each tested with the 15 conditions and NV (0xF, never on
@ ARMv4, written as a .word); then ADD/ADC/SUB/SBC/RSB/RSC/CMP/CMN on
@ carry and overflow corners with carry in 0 and 1, and the logical S
@ operations, each followed by every condition.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START

	.macro CONDS				@ one bit per condition that passes
	mov	r0, #0
	orreq	r0, r0, #0x1
	orrne	r0, r0, #0x2
	orrcs	r0, r0, #0x4
	orrcc	r0, r0, #0x8
	orrmi	r0, r0, #0x10
	orrpl	r0, r0, #0x20
	orrvs	r0, r0, #0x40
	orrvc	r0, r0, #0x80
	orrhi	r0, r0, #0x100
	orrls	r0, r0, #0x200
	orrge	r0, r0, #0x400
	orrlt	r0, r0, #0x800
	orrgt	r0, r0, #0x1000
	orrle	r0, r0, #0x2000
	orral	r0, r0, #0x4000
	.word	0xf3800902			@ orrnv r0, r0, #0x8000
	SIG	r0
	.endm

	.irp f, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
	SETF	\f
	CONDS
	.endr

	@ ---- arithmetic corners: (a, b) pairs, carry in 0 and 1
	.macro ARITH op
	ldr	r9, =pairs
	mov	r8, #8
1:	ldmia	r9!, {r1, r2}
	.irp cin, 0, 2
	SETF	\cin
	\op	r3, r1, r2
	SIG	r3
	SIGF
	CONDS
	.endr
	subs	r8, r8, #1
	bne	1b
	.endm
	ARITH	adds
	ARITH	adcs
	ARITH	subs
	ARITH	sbcs
	ARITH	rsbs
	ARITH	rscs
	POOL
	.irp op, cmp, cmn, tst, teq
	ldr	r9, =pairs
	mov	r8, #8
1:	ldmia	r9!, {r1, r2}
	.irp cin, 0, 2
	SETF	\cin
	\op	r1, r2
	SIGF
	CONDS
	.endr
	subs	r8, r8, #1
	bne	1b
	.endr
	.irp op, ands, eors, orrs, bics
	ldr	r9, =pairs
	mov	r8, #8
1:	ldmia	r9!, {r1, r2}
	SETF	11				@ N clear, Z clear, C and V set: logical ops keep V
	\op	r3, r1, r2
	SIG	r3
	SIGF
	.endr
	b	2f
pairs:
	.word	0, 0
	.word	0xffffffff, 1
	.word	0x7fffffff, 1
	.word	0x80000000, 0xffffffff
	.word	0x80000000, 0x80000000
	.word	0x7fffffff, 0x7fffffff
	.word	1, 2
	.word	0, 0x80000000
2:
	END
