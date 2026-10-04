@ LDM/STM: IA, IB, DA, DB, with and without write-back, lists of 1, 2, 4
@ and 11 registers; the base in the list (lowest, middle, highest; with and
@ without write-back) for STM and LDM; an unaligned base (the low bits are
@ ignored for the accesses and kept by the write-back); LDM from the ROM;
@ stmib sp without write-back (firmware 0x888); push/pop; a register
@ loaded by LDM used at once.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r0, =0x11111111
	ldr	r1, =0x22222222
	ldr	r2, =0x33333333
	ldr	r3, =0x44444444
	mov	r4, #0x55
	mov	r5, #0x66
	mov	r6, #0x77
	mov	r7, #0x88
	mov	r8, #0x99
	mov	r9, #0xaa
	mov	r10, #0xbb

	.macro BLK op, list			@ from DATA + 64 in r10, without and with write-back
	add	r10, r12, #64
	\op	r10, \list
	SIG	r10
	add	r10, r12, #64
	\op	r10!, \list
	SIG	r10
	.endm
	.macro BLK2 op, ra, rb
	add	r10, r12, #64
	\op	r10, {\ra, \rb}
	SIG	r10
	add	r10, r12, #64
	\op	r10!, {\ra, \rb}
	SIG	r10
	.endm
	.irp mode, ia, ib, da, db
	BLK	stm\mode, {r0}
	BLK2	stm\mode, r0, r3
	BLK	stm\mode, {r1-r4}
	BLK	stm\mode, {r0-r9}
	BLK	ldm\mode, {r0}
	SIG	r0
	BLK2	ldm\mode, r1, r9
	SIG	r1
	SIG	r9
	BLK	ldm\mode, {r1-r4}
	BLK	ldm\mode, {r0-r9}
	ldr	r0, [r12, #64]
	SIG	r0
	.endr
	POOL

	@ base in the list
	.irp mode, ia, ib, da, db
	add	r2, r12, #128
	stm\mode	r2!, {r0-r3}		@ base in the middle
	SIG	r2
	add	r0, r12, #128
	stm\mode	r0!, {r0-r3}		@ base lowest: the old value is stored
	SIG	r0
	add	r3, r12, #128
	stm\mode	r3!, {r0-r3}		@ base highest
	SIG	r3
	add	r1, r12, #128
	stm\mode	r1, {r0-r3}		@ no write-back
	ldr	r4, [r12, #128]
	ldr	r5, [r12, #132]
	ldr	r6, [r12, #124]
	SIG	r4
	SIG	r5
	SIG	r6
	add	r2, r12, #128
	ldm\mode	r2!, {r0-r3}		@ LDM with write-back, base in list
	SIG	r0
	SIG	r1
	SIG	r2
	SIG	r3
	add	r2, r12, #128
	ldm\mode	r2, {r1-r3}		@ no write-back, base in list
	SIG	r1
	SIG	r2
	SIG	r3
	.endr
	POOL

	@ unaligned base
	add	r2, r12, #194
	stmia	r2!, {r0, r1}
	SIG	r2
	sub	r2, r2, #8
	ldmia	r2, {r3, r4}
	SIG	r3
	SIG	r4
	add	r2, r12, #203
	ldmdb	r2!, {r5-r7}
	SIG	r2
	SIG	r5
	SIG	r7
	@ from the ROM
	ldr	r2, =table
	ldmia	r2, {r0-r3}
	add	r0, r0, r3			@ used at once
	SIG	r0
	SIG	r1
	ldr	r2, =table + 16
	ldmdb	r2!, {r4, r5}
	SIG	r2
	SIG	r4
	@ the firmware's forms
	sub	sp, sp, #16
	stmib	sp, {r0, r1}
	ldmib	sp, {r2, r3}
	SIG	r2
	push	{r4-r11, lr}
	mov	r4, #0
	mov	r11, #0
	pop	{r4-r11, lr}
	SIG	r4
	push	{r0}
	pop	{r1}
	SIG	r1
	b	1f
table:
	.word	0xa5a5a5a5, 0x5a5a5a5a, 0x01020304, 0xf0e0d0c0
1:
	END
