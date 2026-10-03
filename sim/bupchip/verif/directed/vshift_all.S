@ Exhaustive shifter sweep, for Unicorn and lockstep (run_vrand.sh runs it
@ through ../isa/run_isa.sh). The reference core and the new one share
@ arm7tdmi_pkg's shift_register, so lockstep alone cannot see a fault in
@ it; Unicorn can. For 16 values, MOVS with each shift type by every
@ register amount 0-259 (256-259: only Rs[7:0] counts) and by every
@ immediate encoding (LSL #0-31, LSR #1-32, ASR #1-32, ROR #1-31, RRX),
@ with NZCV in as 0000 and 1111 (so C in, and V kept, both ways). Result
@ and CPSR fold into r10; two signature words per value. About 170,000
@ instructions.
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi
	.section .vectors, "ax"
	.global	_start
_start:	b	reset
	.rept	7
	b	.
	.endr
	.text
reset:
	b	start
values:	.word	0x00000000, 0x00000001, 0x80000000, 0xffffffff, 0x7fffffff, 0x55555555
	.word	0xaaaaaaaa, 0x80000001, 0x00008000, 0x12345678, 0xfedcba98, 0x40000000
	.word	0x00000002, 0xc0000003, 0x0f0f0f0f, 0xf0f0f0f1
start:
	mrs	r0, cpsr
	bic	r0, r0, #31
	orr	r0, r0, #0xd3
	msr	cpsr_c, r0
	ldr	sp, =__stack_top
	ldr	r11, =__sig_start
	adr	r8, values
	mov	r9, #16
	b	vloop
	.ltorg

	.macro	FOLD
	mrs	r4, cpsr
	add	r10, r3, r10, ror #27
	add	r10, r4, r10, ror #27
	.endm

vloop:	ldr	r0, [r8], #4
	mov	r10, #0
	mov	r2, #0
aloop:					@ by register, amounts 0-259
	.irp	t, lsl, lsr, asr, ror
	.irp	f, 0x00000000, 0xf0000000
	msr	cpsr_f, #\f
	movs	r3, r0, \t r2
	FOLD
	.endr
	.endr
	add	r2, r2, #1
	cmp	r2, #260
	bne	aloop
	str	r10, [r11], #4

	mov	r10, #0			@ by immediate, every encoding
	.irp	f, 0x00000000, 0xf0000000
	msr	cpsr_f, #\f
	movs	r3, r0			@ LSL #0
	FOLD
	movs	r3, r0, rrx
	FOLD
	movs	r3, r0, lsr #32
	FOLD
	movs	r3, r0, asr #32
	FOLD
	.irp	n, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
	msr	cpsr_f, #\f
	movs	r3, r0, lsl #\n
	FOLD
	msr	cpsr_f, #\f
	movs	r3, r0, lsr #\n
	FOLD
	msr	cpsr_f, #\f
	movs	r3, r0, asr #\n
	FOLD
	msr	cpsr_f, #\f
	movs	r3, r0, ror #\n
	FOLD
	.endr
	.endr
	str	r10, [r11], #4
	subs	r9, r9, #1
	bne	vloop

	ldr	r1, =0xE0009000		@ the end marker: FAULT = 0xAA
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.
	.ltorg
