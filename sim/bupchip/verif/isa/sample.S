@ Hand-written ISA test for the BupChip CPU subset (ARMv4, ARM state): carry
@ chains, the shifter's edge cases, MUL/MLA/UMULL, every halfword/byte
@ addressing mode, push/pop, STMIB/LDMIA!, BL/BX and the firmware's LDR PC
@ jump table. Linked by link.ld at 0 (ROM), RAM at 0x40000000. Results go to
@ a signature in RAM from 0x40000000 (r11 = pointer); a FAULT write of 0xAA
@ to 0xE000901C ends the test. run_isa.sh runs it on the reference RTL and
@ on Unicorn and compares the signatures.
	.syntax unified
	.arm
	.cpu arm7tdmi

	.macro SIG reg
	str	\reg, [r11], #4
	.endm
	@ NZCV into r10 with conditional execution only (no MRS needed).
	.macro SIGF
	mov	r10, #0
	orrmi	r10, r10, #8
	orreq	r10, r10, #4
	orrcs	r10, r10, #2
	orrvs	r10, r10, #1
	str	r10, [r11], #4
	.endm

	.section .vectors, "ax"
	.global _start
_start:
	b	reset
	b	.		@ undefined
	b	.		@ SWI
	b	.		@ prefetch abort
	b	.		@ data abort
	b	.
	b	.		@ IRQ
	b	.		@ FIQ

	.text
reset:
	mrs	r0, cpsr		@ the firmware's own start-up sequence
	bic	r0, r0, #31
	orr	r0, r0, #0xd3
	msr	cpsr_c, r0
	ldr	sp, =__stack_top
	ldr	r11, =__sig_start

	@ ---- data processing: carry chains, overflow, reverse subtract
	ldr	r0, =0xffffffff
	ldr	r1, =0x00000001
	adds	r2, r0, r1		@ 0, Z C
	SIG	r2
	SIGF
	adcs	r3, r1, r1		@ 1 + 1 + C = 3
	SIG	r3
	SIGF
	ldr	r4, =0x7fffffff
	adds	r5, r4, r1		@ signed overflow: N V
	SIG	r5
	SIGF
	subs	r6, r1, r0		@ 1 - (-1) = 2, C clear (borrow)
	SIG	r6
	SIGF
	sbcs	r7, r1, r1		@ 1 - 1 - !C = -1
	SIG	r7
	SIGF
	rsbs	r8, r1, #0		@ -1
	SIG	r8
	SIGF
	rscs	r9, r1, #5		@ 5 - 1 - !C
	SIG	r9
	SIGF
	@ 64-bit add, the way compilers emit it
	ldr	r0, =0x89abcdef
	ldr	r1, =0x01234567
	ldr	r2, =0x80000000
	ldr	r3, =0xfedcba98
	adds	r4, r0, r2
	adc	r5, r1, r3
	SIG	r4
	SIG	r5
	bics	r6, r0, #0xff000000	@ logical: C from the immediate rotate
	SIG	r6
	SIGF
	mvns	r7, r0
	SIG	r7
	SIGF
	teq	r0, r0
	SIGF
	cmn	r0, r2
	SIGF
	tst	r1, #1
	SIGF

	@ ---- barrel shifter: immediate and register amounts, edge cases
	ldr	r0, =0x80000001
	movs	r1, r0, lsl #1
	SIG	r1
	SIGF
	movs	r1, r0, lsr #32		@ encodes as lsr #0 -> 32
	SIG	r1
	SIGF
	movs	r1, r0, asr #31
	SIG	r1
	SIGF
	movs	r1, r0, ror #4
	SIG	r1
	SIGF
	movs	r1, r0, rrx
	SIG	r1
	SIGF
	mov	r2, #0
	movs	r1, r0, lsl r2		@ register amount 0: no shift, C unchanged
	SIG	r1
	SIGF
	mov	r2, #32
	movs	r1, r0, lsl r2		@ 32: result 0, C = bit 0
	SIG	r1
	SIGF
	mov	r2, #33
	movs	r1, r0, lsr r2		@ 33: result 0, C = 0
	SIG	r1
	SIGF
	mov	r2, #200
	movs	r1, r0, asr r2		@ >= 32: all sign
	SIG	r1
	SIGF
	mov	r2, #36
	movs	r1, r0, ror r2		@ ror by 36 == ror by 4
	SIG	r1
	SIGF
	mov	r3, #3
	orr	r1, r0, r0, lsl r3	@ the firmware's "orr rX, rX, rY, lsl rZ"
	SIG	r1
	add	r1, r0, r0, asr #3
	SIG	r1

	@ ---- multiplies (MUL/MLA as the mixer uses them, and UMULL)
	ldr	r0, =0x12345678
	ldr	r1, =0xfffffff3		@ -13
	mul	r2, r0, r1
	SIG	r2
	ldr	r3, =0x00007fff
	mla	r4, r1, r3, r0
	SIG	r4
	ldr	r5, =0xffff8000
	mul	r6, r5, r3		@ the PCM scaling shape: s16 * s16
	SIG	r6
	umull	r7, r8, r0, r1
	SIG	r7
	SIG	r8
	umull	r7, r8, r1, r1
	SIG	r7
	SIG	r8

	@ ---- loads and stores: halfword, signed, byte, all index modes
	ldr	r0, =scratch
	ldr	r1, =0x8081f2f3
	str	r1, [r0]
	ldrh	r2, [r0]
	SIG	r2
	ldrh	r2, [r0, #2]
	SIG	r2
	ldrsh	r2, [r0]
	SIG	r2
	ldrsh	r2, [r0, #2]
	SIG	r2
	ldrsb	r2, [r0, #1]
	SIG	r2
	ldrsb	r2, [r0, #3]
	SIG	r2
	ldrb	r2, [r0, #2]
	SIG	r2
	mov	r3, #2
	ldrsh	r2, [r0, r3]		@ register offset
	SIG	r2
	ldrh	r2, [r0, #2]!		@ pre-index with writeback
	SIG	r2
	SIG	r0
	ldrsh	r2, [r0], #-2		@ post-index
	SIG	r2
	SIG	r0
	ldr	r4, =0x1234abcd
	strh	r4, [r0, #4]
	strb	r4, [r0, #7]
	ldr	r2, [r0, #4]
	SIG	r2
	strh	r4, [r0, #-2]!
	SIG	r0
	ldrh	r2, [r0]		@ word accesses stay aligned, as in the firmware
	SIG	r2
	add	r0, r0, #2
	ldr	r2, [r0, r3, lsl #1]	@ scaled register offset
	SIG	r2
	str	r4, [r0], #4
	SIG	r0

	@ ---- block transfers: push/pop, stmib/stmia as the firmware has them
	mov	r0, #0x10
	mov	r1, #0x11
	mov	r2, #0x12
	mov	r3, #0x13
	mov	lr, #0x77
	push	{r0-r3, lr}
	mov	r0, #0
	mov	r1, #0
	pop	{r4-r7, r12}
	SIG	r4
	SIG	r7
	ldr	r0, =scratch
	stmib	r0, {r1, r2, r3}
	ldmia	r0!, {r4-r7}
	SIG	r5
	SIG	r7
	SIG	r0

	@ ---- control flow: BL/BX, conditional branches, LDR PC jump table
	mov	r0, #5
	bl	triple
	SIG	r0
	mov	r1, #0
	adr	r3, jtab
	mov	r2, #2
	ldr	pc, [r3, r2, lsl #2]	@ the firmware's command dispatch (0x1ec)
jtab:	.word	j0, j1, j2, j3
j0:	mov	r1, #0xa0
	b	jdone
j1:	mov	r1, #0xa1
	b	jdone
j2:	mov	r1, #0xa2
	b	jdone
j3:	mov	r1, #0xa3
jdone:	SIG	r1
	mov	r0, #10
	mov	r1, #0
loop:	add	r1, r1, r0
	subs	r0, r0, #1
	bne	loop
	SIG	r1
	cmp	r1, #55
	moveq	r2, #1
	movne	r2, #2
	addgt	r2, r2, #4
	addle	r2, r2, #8
	SIG	r2

	@ ---- done: signature length, then the FAULT register as the end marker
	ldr	r0, =__sig_start
	sub	r0, r11, r0
	ldr	r1, =0xE0009000
	str	r0, [r1, #0x10]		@ PCM push: harmless, logs the length
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.

triple:	add	r0, r0, r0, lsl #1
	bx	lr

	.ltorg

	.bss
	.align	4
scratch: .space	64
