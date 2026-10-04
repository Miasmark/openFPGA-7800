@ Shared frame of the directed tests (run_directed.sh): the vectors, the
@ firmware's own start-up (SVC mode, IRQ/FIQ masked), r11 = signature
@ pointer (RAM 0x40000000, 8 KiB), r12 = data area 0x40002000, sp at the top
@ of RAM, and the end marker (a FAULT write of 0xAA) that both cores stop
@ at. Results go to the signature with SIG / SIGF, but every retire, store
@ and peripheral access is compared in lockstep anyway.
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi

	.equ	MMIO, 0xE0009000
	.equ	DATA, 0x40002000
	.equ	ASSET, 0x02000000

	.macro SIG reg
	str	\reg, [r11], #4
	.endm
	.macro SIGF				@ NZCV and the fixed mode bits
	mrs	r10, cpsr
	str	r10, [r11], #4
	.endm
	.macro SETF nzcv			@ NZCV from a 4-bit constant
	msr	cpsr_f, #(\nzcv << 28)
	.endm

	.macro POOL				@ a literal pool here, jumped over
	b	9f
	.ltorg
9:
	.endm

	.macro START
	.section .vectors, "ax"
	.global _start
_start:
	b	reset
	.rept 7
	b	.
	.endr
	.text
reset:
	mrs	r0, cpsr
	bic	r0, r0, #31
	orr	r0, r0, #0xd3
	msr	cpsr_c, r0
	ldr	sp, =__stack_top
	ldr	r11, =__sig_start
	ldr	r12, =DATA
	@ a known pattern in the data area: word i = 0x80 + 0x04040404 * i + 0x03020100
	ldr	r0, =0x83828180
	ldr	r1, =0x04040404
	mov	r2, #0
1:	str	r0, [r12, r2]
	add	r0, r0, r1
	add	r2, r2, #4
	cmp	r2, #256
	bne	1b
	POOL
	.endm

	.macro END
	ldr	r0, =__sig_start
	sub	r0, r11, r0
	ldr	r1, =MMIO
	str	r0, [r1, #0x10]
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.
	.ltorg
	.endm
