@ An instruction whose condition fails has no effect and takes one clock,
@ whatever it is, including every encoding the core would otherwise halt
@ on: SWI, SWP, coprocessor, undefined, SPSR access, MSR of the mode,
@ S-bit and signed long multiplies, writes to PC, LDM/STM with PC or S,
@ BX to Thumb, stores of PC and loads outside the memory map.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r1, =0x00000101			@ a Thumb address
	ldr	r2, =0x10000000			@ outside every window
	movs	r0, #0				@ Z set: NE fails
	swine	0
	swpne	r0, r1, [r12]
	mrcne	p15, 0, r0, c0, c0, 0
	cdpne	p1, 0, c0, c0, c0, 0
	ldcne	p1, c0, [r12]
	.word	0x16000010			@ undefined (NE)
	mrsne	r0, spsr
	msrne	spsr_f, r0
	msrne	cpsr_c, #0x10
	mulsne	r0, r1, r1
	smullne	r3, r4, r1, r1
	umlalne	r3, r4, r1, r1
	movne	pc, lr
	addne	r0, pc, r1, lsl r1
	ldmne	r12, {r0, pc}
	ldmne	r12, {r0}^
	bxne	r1
	strne	pc, [r12]
	ldrne	r0, [r2]
	strne	r0, [r2]
	strne	r0, [r12, #-4]			@ RAM: a one-clock store that must not happen
	.word	0x149f0004			@ ldrne r0, [pc], #4: write-back to PC
	SIG	r0
	SIGF
	END
