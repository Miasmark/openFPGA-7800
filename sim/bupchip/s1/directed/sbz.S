@ Should-be-zero fields the core ignores, as the ARM7TDMI does: Rd of
@ TST/TEQ/CMP/CMN, Rn of MOV/MVN and of MUL, bits 11:8 of a halfword
@ transfer with a register offset. (Fields whose misuse the core does not
@ define - the BX, MRS and MSR patterns - halt instead; see halt_tests.py.)
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r1, =0x80000001
	mov	r2, #3
	mov	r3, #0x55
	mov	r5, #7
	.word	0xe1553001			@ cmp r5, r1 with Rd = r3
	SIGF
	SIG	r3
	.word	0xe1153001			@ tst r5, r1 with Rd = r3
	SIGF
	.word	0xe1b30001			@ movs r0, r1 with Rn = r3
	SIG	r0
	SIGF
	.word	0xe1e30001			@ mvn r0, r1 with Rn = r3
	SIG	r0
	.word	0xe0003291			@ mul r0, r1, r2 with Rn = r3
	SIG	r0
	mov	r1, #6
	.word	0xe19c0fb1			@ ldrh r0, [r12, r1], bits 11:8 = 0xf
	SIG	r0
	.word	0xe18c0fb1			@ strh r0, [r12, r1], bits 11:8 = 0xf
	ldr	r0, [r12, #4]
	SIG	r0
	END
