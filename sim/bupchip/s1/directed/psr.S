@ MRS and MSR: MRS CPSR reads {NZCV, 0, 0xD3}; MSR CPSR_f from an
@ immediate and from a register sets NZCV; MSR CPSR_c with 0xD3 (the
@ firmware's start-up) and CPSR_fc change nothing else; conditional MSR.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	SIGF
	msr	cpsr_f, #0xf0000000
	SIGF
	ldr	r1, =0x50000000
	msr	cpsr_f, r1
	SIGF
	mov	r0, #0xd3
	msr	cpsr_c, r0
	SIGF
	ldr	r1, =0xa00000d3
	msr	cpsr_fc, r1
	SIGF
	msr	cpsr_c, #0xd3
	SIGF
	movs	r0, #0				@ Z
	msrne	cpsr_f, #0x80000000		@ fails
	SIGF
	msreq	cpsr_f, #0x30000000
	SIGF
	mrs	r2, cpsr
	bic	r2, r2, #0xf0000000
	msr	cpsr_f, r2
	SIGF
	END
