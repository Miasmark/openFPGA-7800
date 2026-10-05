@ SP-relative and PC-relative code mixed, as compiled Thumb is:
@   F12 ADD Rd, PC, #imm8 << 2 (the PC reads word-aligned at either
@   alignment) and ADD Rd, SP, #imm8 << 2, at offsets 0 and 1020;
@   F13 ADD/SUB SP, #imm7 << 2, at 0 (0xB000, 0xB080), 4 and 508;
@   F11 locals in a stack frame, F6 constants, F12 table addresses;
@   a recursive function (factorial, with MUL; every path writes C before
@   it reads it) with PUSH {r4, r5, lr}, SUB SP, locals, POP {r4, r5, pc};
@   a loop summing a table found with ADR (F12 PC) through LDR [Rb, Ro],
@   with the running sum kept in a stack slot.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	@ ---- F12 and F13 at their limits
	.balign 4
	add	r0, pc, #0		@ 0 mod 4
	add	r1, pc, #0		@ 2 mod 4: the same value
	add	r2, pc, #1020
	add	r3, pc, #1020
	add	r4, sp, #0
	add	r5, sp, #1020
	add	r6, sp, #4
	.hword	0xb000			@ add sp, #0
	.hword	0xb080			@ sub sp, #0
	add	sp, #-4
	mov	r7, sp
	add	sp, #4
	sub	sp, #508
	mov	r7, sp
	add	sp, #508
	mov	r7, sp
	add	r0, sp, #8		@ SP written by the instruction before (bypass)

	@ ---- factorial of 1..10, recursive
	movs	r6, #1
1:	movs	r0, r6
	bl	fact
	SIG	r0
	adds	r6, #1
	cmp	r6, #11
	bne	1b

	@ ---- a table summed through ADR and a stack slot
	sub	sp, #8
	movs	r0, #0
	str	r0, [sp, #0]		@ the sum
	str	r0, [sp, #4]		@ the index
	.balign 4
	adr	r7, table		@ 0 mod 4
	adr	r6, table		@ 2 mod 4
2:	ldr	r1, [sp, #4]
	lsls	r2, r1, #2
	ldr	r3, [r7, r2]
	ldr	r0, [sp, #0]
	adds	r0, r3
	str	r0, [sp, #0]
	ldr	r4, kconst		@ F6
	eors	r0, r4
	adds	r1, #1
	str	r1, [sp, #4]
	cmp	r1, #8
	bne	2b
	ldr	r0, [sp, #0]
	add	sp, #8
	b	3f

	.balign 4
kconst:	.word	0x5a5aa5a5
table:	.word	1, 2, 3, 5, 8, 13, 21, 0x80000000

	@ fact(r0): r0! (r0 >= 1); a frame of 16 bytes of locals
fact:	push	{r4, r5, lr}
	sub	sp, #16
	str	r0, [sp, #4]
	add	r1, sp, #8
	str	r0, [r1, #4]		@ [sp, #12], through F12 SP
	ldr	r2, [sp, #4]
	cmp	r2, #1
	bls	1f			@ C written by the CMP
	subs	r0, r2, #1
	bl	fact
	ldr	r2, [sp, #12]
	muls	r0, r2			@ C unknown until the caller writes it
	b	2f
1:	movs	r0, #1
2:	add	sp, #16
	pop	{r4, r5, pc}

3:	END
