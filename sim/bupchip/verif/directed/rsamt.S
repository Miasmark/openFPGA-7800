@ Shift by register, beyond s1/directed/shifts.S: only Rs[7:0] counts (Rs
@ = 0x100, 0x120, 0xffffff00, 0xffffff21, 0x1ff), rotations by multiples of
@ 32 (64, 96, 128, 224) where C is bit 31 and the value is unchanged, the
@ carry-using operations (ADC, SBC, RSC) and RSB with a register-shifted
@ operand 2 and both carries in, and Rd == Rm == Rs, Rd == Rs, Rn == Rm.
@ Ends by summing the signature, so that a store the core missed or added
@ shows up in a register.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r4, =0x80000001
	ldr	r5, =0x7ffffffe
	ldr	r6, =0xc0000000

	.macro RS rsval
	ldr	r2, =\rsval
	.irp sh, lsl, lsr, asr, ror
	.irp cin, 0, 2
	SETF	\cin
	movs	r0, r4, \sh r2
	SIG	r0
	SIGF
	SETF	\cin
	adcs	r0, r5, r4, \sh r2
	SIG	r0
	SIGF
	SETF	\cin
	sbcs	r0, r5, r6, \sh r2
	SIG	r0
	SIGF
	SETF	\cin
	rscs	r0, r4, r5, \sh r2
	SIG	r0
	SIGF
	SETF	\cin
	rsbs	r0, r6, r4, \sh r2
	SIG	r0
	SIGF
	.endr
	.endr
	.endm
	RS	0x100
	RS	0x120
	POOL
	RS	0xffffff00
	RS	0xffffff21
	POOL
	RS	0x1ff
	RS	64
	POOL
	RS	96
	RS	128
	POOL
	RS	224
	RS	30
	POOL

	@ register aliasing: Rd == Rm == Rs, Rd == Rs, Rn == Rm == Rs
	.irp sh, lsl, lsr, asr, ror
	mov	r1, #3
	SETF	2
	movs	r1, r1, \sh r1			@ 3 shifted by 3
	SIG	r1
	SIGF
	ldr	r1, =0x80000021
	SETF	0
	movs	r1, r1, \sh r1			@ amount 0x21 = 33
	SIG	r1
	SIGF
	mov	r2, #4
	ldr	r3, =0xf000000f
	adds	r2, r3, r3, \sh r2		@ Rd == Rs
	SIG	r2
	SIGF
	mov	r3, #5
	subs	r0, r3, r3, \sh r3		@ Rn == Rm == Rs
	SIG	r0
	SIGF
	.endr
	POOL

	@ sum of the signature
	ldr	r1, =__sig_start
	mov	r0, #0
1:	ldr	r2, [r1], #4
	add	r0, r0, r2
	cmp	r1, r11
	bne	1b
	SIG	r0
	END
