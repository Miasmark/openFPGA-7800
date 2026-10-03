@ Data dependences through the register file: a loaded register used next
@ as MLA's Rm, Rs and Rn, as BX's target, as store data, as a base, as a
@ shift amount; a register written by a load and then by an ALU result
@ (the S3 case of ports E and W writing one register in one clock); an LDM
@ register used at once; UMULL's halves used at once.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r1, =0x00010003
	ldr	r2, =0x00020005
	ldr	r3, =0x00000007
	stmia	r12, {r1-r3}
	ldr	r4, =target
	str	r4, [r12, #12]
	add	r4, r12, #128
	str	r4, [r12, #16]
	mov	r4, #5
	str	r4, [r12, #20]

	ldr	r1, [r12]
	mla	r0, r1, r2, r3			@ Rm just loaded
	SIG	r0
	ldr	r2, [r12, #4]
	mla	r0, r1, r2, r3			@ Rs
	SIG	r0
	ldr	r3, [r12, #8]
	mla	r0, r1, r2, r3			@ Rn
	SIG	r0
	ldrsh	r1, [r12, #2]
	mul	r0, r1, r1
	SIG	r0
	ldr	r4, [r12, #12]
	bx	r4				@ target just loaded
	b	.
target:
	ldr	r5, [r12, #4]
	str	r5, [r12, #64]			@ store data just loaded
	ldr	r5, [r12, #4]
	strh	r5, [r12, r3]			@ register-offset store of loaded data
	ldr	r6, [r12, #16]
	ldr	r7, [r6, #-128]			@ base just loaded
	SIG	r7
	ldr	r6, [r12, #16]
	str	r7, [r6], #4			@ base just loaded, write-back
	SIG	r6
	ldr	r8, [r12, #20]
	mov	r0, r1, lsl r8			@ shift amount just loaded
	SIG	r0
	ldr	r8, [r12, #20]
	add	r0, r1, r1, ror r8
	SIG	r0
	@ the same register from a load and then an ALU result
	ldr	r0, [r12]
	mov	r0, #9
	SIG	r0
	ldr	r0, [r12]
	add	r0, r0, #1
	SIG	r0
	ldrb	r0, [r12, #1]
	ldrb	r0, [r12, #2]
	SIG	r0
	ldr	r0, [r12, #4]!			@ base and data, then both read
	add	r1, r0, r12
	SIG	r1
	sub	r12, r12, #4
	ldmia	r12, {r0-r2}
	add	r3, r2, r0
	SIG	r3
	umull	r4, r5, r1, r2
	adds	r6, r5, r4
	SIG	r6
	SIGF
	mov	r9, #3
	mov	r9, r9, lsl #2
	ldr	r0, [r12, r9]
	SIG	r0
	END
