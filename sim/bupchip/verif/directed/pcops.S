@ r15 as an operand where it reads as the instruction's address + 8 (and
@ the core does not halt): Rm with an immediate shift, Rn of data
@ processing, flag-setting forms with C and V from the PC value, Rn of a
@ load with immediate and register offsets (no write-back), Rn of halfword
@ and signed loads. The forms that read PC + 12 or are UNPREDICTABLE halt
@ instead (s1/halt_tests.py). Ends by summing the signature into a
@ register.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	mov	r1, #8
	ldr	r2, =0x80000000
	add	r0, r1, pc
	SIG	r0
	add	r0, pc, r1, lsl #2
	SIG	r0
	mov	r0, pc, ror #4
	SIG	r0
	SETF	2
	movs	r0, pc, rrx
	SIG	r0
	SIGF
	adds	r0, pc, r2
	SIG	r0
	SIGF
	subs	r0, pc, #0x10000
	SIG	r0
	SIGF
	rsbs	r0, pc, #0
	SIG	r0
	SIGF
	cmp	pc, #0x100
	SIGF
	teq	r2, pc, lsl #31
	SIGF
	bic	r0, pc, #0xff
	SIG	r0
	mvns	r0, pc
	SIG	r0
	SIGF
	ldr	r0, [pc, r1]
	SIG	r0
	ldr	r0, [pc, -r1, lsl #1]
	SIG	r0
	ldr	r0, [pc, #4]
	SIG	r0
	ldrb	r0, [pc, #-3]
	SIG	r0
	ldrh	r0, [pc, #6]
	SIG	r0
	ldrsh	r0, [pc, #2]
	SIG	r0
	ldrsb	r0, [pc, r1]
	SIG	r0
	ldrh	r0, [pc, -r1]
	SIG	r0
	mov	r3, pc
	mov	r4, pc, lsl #0
	sub	r3, r4, r3
	SIG	r3

	ldr	r1, =__sig_start
	mov	r0, #0
1:	ldr	r2, [r1], #4
	add	r0, r0, r2
	cmp	r1, r11
	bne	1b
	SIG	r0
	END
