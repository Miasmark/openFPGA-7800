@ Formats 14 and 15: PUSH/POP and STMIA/LDMIA.
@   STMIA Rb! with Rb in the list: first (the old base is stored), middle
@   and last (the new, written-back base); alone.
@   LDMIA Rb! with Rb in the list: first, middle, last, alone (the loaded
@   value wins over the write-back).
@   Lists of 1 to 8 registers, with gaps, every register as the base;
@   LDMIA from the ROM as well as the RAM.
@   PUSH {r0-r7, lr} and POP {r0-r7, pc}; PUSH {lr} and POP {pc}; POP {pc}
@   with bit 0 of the value set and clear: ARMv4T stays in Thumb either
@   way (the target's address with bit 0 cleared).
@   Values used straight after the last beat, also at the first
@   instruction of a POP {pc}'s target (the bypass; LATE_RF).
@ GAS refuses LDMIA with the base in the list, so those are .hword.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	@ ---- STMIA, base in the list
	ldr	r1, =DATA + 0x100
	movs	r2, #0x22
	movs	r3, #0x33
	stmia	r1!, {r1, r2, r3}	@ first: the old base
	ldr	r2, =DATA + 0x120
	movs	r1, #0x11
	movs	r3, #0x33
	.hword	0xc20e			@ stmia r2!, {r1, r2, r3}: middle, the new base
	ldr	r3, =DATA + 0x140
	movs	r1, #0x11
	movs	r2, #0x22
	.hword	0xc30e			@ stmia r3!, {r1, r2, r3}: last
	ldr	r0, =DATA + 0x160
	.hword	0xc001			@ stmia r0!, {r0}: alone
	ldr	r7, =DATA + 0x170
	movs	r4, #4
	movs	r5, #5
	movs	r6, #6
	.hword	0xc7f0			@ stmia r7!, {r4-r7}: last of four
	@ read them back
	ldr	r7, =DATA + 0x100
	ldmia	r7!, {r0-r6}
	ldmia	r7!, {r0-r6}
	ldmia	r7!, {r0-r6}
	ldmia	r7!, {r0-r6}
	POOL

	@ ---- LDMIA, base in the list
	ldr	r1, =DATA + 0x40
	.hword	0xc907			@ ldmia r1!, {r0, r1, r2}: middle
	ldr	r0, =DATA + 0x50
	.hword	0xc807			@ ldmia r0!, {r0, r1, r2}: first
	ldr	r2, =DATA + 0x60
	.hword	0xca07			@ ldmia r2!, {r0, r1, r2}: last
	ldr	r3, =DATA + 0x70
	.hword	0xcb08			@ ldmia r3!, {r3}: alone
	ldr	r7, =DATA + 0x80
	.hword	0xcfff			@ ldmia r7!, {r0-r7}: last of eight
	ldr	r4, =DATA + 0x90
	.hword	0xcc30			@ ldmia r4!, {r4, r5}: first of two
	adds	r6, r4, #0		@ the loaded r4, straight away

	@ ---- every register as the base, lists of 1-8 with gaps
	ldr	r0, =DATA + 0x200
	movs	r1, #1
	movs	r2, #2
	movs	r3, #3
	movs	r4, #4
	movs	r5, #5
	movs	r6, #6
	movs	r7, #7
	stmia	r0!, {r1}
	stmia	r0!, {r1, r7}
	stmia	r0!, {r2, r4, r6}
	stmia	r0!, {r1-r7}
	mov	r8, r0
	ldr	r1, =DATA + 0x200
	ldmia	r1!, {r2}
	ldmia	r1!, {r3, r5}
	ldmia	r1!, {r0, r4, r7}
	ldmia	r1!, {r0, r2-r7}
	.irp b, r0, r1, r2, r3, r4, r5, r6, r7
	ldr	\b, =DATA + 0x280
	stmia	\b!, {r0-r7}		@ base first, middle or last: GAS warns
	ldr	\b, =DATA + 0x280
	.endr
	POOL
	.irp b, 0, 1, 2, 3, 4, 5, 6, 7
	ldr	r\b, =DATA + 0x300
	.hword	0xc8ff | (\b << 8)	@ ldmia r\b!, {r0-r7}
	.endr
	@ LDMIA from the ROM
	ldr	r6, =romtab
	ldmia	r6!, {r0-r3}
	ldmia	r6!, {r4, r5}
	adds	r7, r5, r4
	POOL

	@ ---- PUSH and POP
	ldr	r0, =0x10101010
	movs	r1, #1
	movs	r2, #2
	movs	r3, #3
	movs	r4, #4
	movs	r5, #5
	movs	r6, #6
	movs	r7, #7
	ldr	r0, =pr1 + 1
	mov	lr, r0
	push	{r0-r7, lr}
	movs	r1, #0
	movs	r2, #0
	pop	{r0-r7, pc}		@ to pr1, the other registers restored
	.hword	0xde00
	.balign 4
pr1:	push	{r1, r3, r5, r7}
	pop	{r0, r2, r4, r6}
	push	{r7}
	pop	{r0}
	push	{r0, lr}
	pop	{r1, r2}
	ldr	r0, =0x5555aaaa
	mov	lr, r0
	push	{lr}
	pop	{r3}
	adds	r3, #1			@ straight after the last beat

	@ ---- POP {pc} with bit 0 set and clear: still Thumb
	ldr	r0, =pp1 + 1
	push	{r0}
	pop	{pc}
	.hword	0xde00
	.balign 4
pp1:	ldr	r0, =pp2		@ bit 0 clear: ARMv4T stays in Thumb
	push	{r0}
	pop	{pc}
	.hword	0xde00
	.balign 4
	.hword	0xde00
pp2:	ldr	r1, =0x4444		@ to a high half, bit 0 clear
	ldr	r2, =pp3
	push	{r1, r2}		@ r2 at the higher address
	pop	{r4, pc}		@ r4 = 0x4444, PC = pp3
	.hword	0xde00
	.balign 4
	.hword	0xde00
pp3:	movs	r1, #9
	ldr	r2, =pp4 + 1
	push	{r1, r2}
	pop	{r3, pc}		@ r3 = 9, PC = pp4 (bit 0 set)
	.hword	0xde00
	POOL
	.balign 4
pp4:	adds	r4, r3, #1		@ r3 from the POP, at the target's first instruction
	ldr	r5, =pp5 + 1
	movs	r6, #0x66
	push	{r5, r6}		@ r6 above r5
	ldr	r7, =pp5
	movs	r0, #0x70
	push	{r0, r7}
	pop	{r6, pc}		@ r6 = 0x70, PC = pp5 (bit 0 clear)
	.hword	0xde00
	.balign 4
	.hword	0xde00
pp5:	adds	r6, #1			@ straight after the last beat
	pop	{r0, r1}		@ r0 = pp5 + 1, r1 = 0x66
	adds	r1, r1, r0
	END

	.balign 4
romtab:	.word	0x00000001, 0x80000002, 0xfffffffc, 0x7ffffff8, 0x12345678, 0x9abcdef0
