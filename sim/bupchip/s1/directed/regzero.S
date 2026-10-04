@ Every register reads 0 before it is first written (the core clears
@ r0-r14 after each hold, as the reference core resets them): the first
@ instructions read all of them, before the usual start-up.
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi
	.section .vectors, "ax"
	.global _start
_start:
	orr	r0, r0, r1
	orr	r0, r0, r2
	orr	r0, r0, r3
	orr	r0, r0, r4
	orr	r0, r0, r5
	orr	r0, r0, r6
	orr	r0, r0, r7
	orr	r0, r0, r8
	orr	r0, r0, r9
	orr	r0, r0, r10
	orr	r0, r0, r11
	orr	r0, r0, r12
	orr	r0, r0, r13
	orr	r0, r0, r14
	ldr	r11, =__sig_start
	str	r0, [r11], #4
	ldr	r1, =0xE0009000
	mov	r0, #4
	str	r0, [r1, #0x10]
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.
	.ltorg
