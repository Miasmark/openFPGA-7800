@ Format 4 MUL and the C flag (docs/DARIA_CORE.md, "MUL and the C flag").
@ The product, N and Z are exact and V is kept; C is left unknown, and the
@ lockstep skips it while the core reports it so (rt_cunk), until an
@ instruction defines it. Nothing here reads C while it is unknown: that
@ halts (code 8), which halt_thumb.py checks.
@   Products on corner operands, every register as Rd and Rs, Rd = Rm (a
@   square; UNPREDICTABLE in ARMv4T, the product on the reference), the
@   product used at once and an operand written just before (the bypass).
@   MULA (C = 0 before, the reference's C = 1 after) and MULB (C = 1
@   before, 0 after), so the core's kept C differs from the reference's
@   either way (both with V = 1 before, which MUL keeps), each followed by every kind of C writer (ADDS, SUBS, CMP,
@   CMN, NEG in F2-F5; shifts by non-zero amounts in F1, including LSR and
@   ASR #32, and F4, including ROR by 32), then the readers (B CS, CC, HI,
@   LS, ADC, SBC).
@   The same MULs followed by pass-through instructions, which keep C and
@   so keep it unknown (MOVS #imm8, LSL #0, AND, EOR, ORR, BIC, MVN, TST,
@   shifts by a register holding 0 or 256, and instructions that set no
@   flags), then a writer, then the readers: a core that cleared c_unk on
@   one of them would compare its C and fail.
@   In ARM state after a Thumb MUL: ARM pass-throughs (MOVS without a
@   shift, logical operations, an immediate with rotation 0), then ARM
@   writers (ADDS, a shift by a non-zero amount, an immediate with a
@   rotation, MSR CPSR_f) and ARM readers (conditions on C, ADC, SBC, RSC,
@   RRX, MRS).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	@ ---- products: corner pairs, Rd = Rm, each followed by a C writer
	ldr	r7, =pairs
	movs	r6, #(pairs_end - pairs) / 8
1:	ldmia	r7!, {r1, r2}
	movs	r3, r1
	muls	r3, r2
	movs	r4, r2
	muls	r4, r1
	movs	r5, r1
	muls	r5, r5			@ Rd = Rm
	adds	r4, r3, #0		@ the product at once; writes C
	SIG	r5
	subs	r6, #1
	bne	1b
	@ every register as Rd and as Rs; the operand just written
	movs	r0, #3
	movs	r1, #5
	movs	r2, #7
	movs	r3, #11
	movs	r4, #13
	movs	r5, #17
	movs	r6, #19
	movs	r7, #23
	muls	r0, r7
	muls	r1, r6
	muls	r2, r5
	muls	r3, r4
	muls	r4, r3
	muls	r5, r2
	muls	r6, r1
	muls	r7, r0
	muls	r0, r0
	muls	r7, r7
	adds	r0, r7			@ writes C
	POOL

	@ ---- MUL, a C writer, the readers
	.macro MULA			@ C = 0, V = 1 before; the reference's C after is 1
	movs	r3, #1
	lsls	r3, r3, #31
	movs	r4, #0
	SETF	1
	muls	r3, r4
	.endm
	.macro MULB			@ C = 1, V = 1 before; the reference's C after is 0
	movs	r3, #3
	movs	r4, #5
	SETF	3
	muls	r3, r4
	.endm
	.macro INS ins:vararg
	\ins
	.endm
	.macro READERS
	bcs	1f
	nop
1:	bcc	1f
	nop
1:	bhi	1f
	nop
1:	bls	1f
	nop
1:	adcs	r0, r1
	sbcs	r0, r2
	.endm

	ldr	r1, =0x80000001
	movs	r2, #7
	movs	r5, #33
	movs	r6, #0
	ldr	r7, =0x100
	movs	r0, #5
	mov	r8, r0
	movs	r0, #32
	mov	r9, r0
	POOL
	@ the writers (r7 = 0x100 is a ROM address for the pass-throughs' load)
	.irp w, "adds r0, r1, r2", "subs r0, r1, r2", "subs r0, r2, r1", "adds r0, r1, #3", "subs r0, r1, #0", "adds r0, r2, #0", "adds r0, #1", "subs r0, #1", "cmp r1, #5", "cmp r2, #7", "cmp r1, r2", "cmn r1, r2", "negs r0, r1", "negs r0, r6", "cmp r1, r8", "cmp r8, r2", "lsls r0, r1, #1", "lsls r0, r2, #31", "lsrs r0, r1, #1", "asrs r0, r1, #31", "lsrs r0, r1, #32", "asrs r0, r1, #32"
	MULA
	INS	\w
	READERS
	MULB
	INS	\w
	READERS
	.endr
	POOL
	@ F4 shifts by a non-zero register amount (the amount in r5, r9, r2)
	.irp w, "lsls r0, r5", "lsrs r0, r5", "asrs r0, r5", "rors r0, r5", "lsls r0, r2", "lsrs r0, r2", "asrs r0, r2", "rors r0, r2", "rors r0, r1"
	MULA
	movs	r0, r1
	INS	\w
	READERS
	MULB
	movs	r0, r1
	INS	\w
	READERS
	.endr
	@ ROR by 32: C = bit 31, the value kept
	movs	r2, #32
	MULA
	movs	r0, r1
	rors	r0, r2
	READERS
	MULB
	movs	r0, r1
	rors	r0, r2
	READERS
	movs	r2, #7
	POOL

	@ ---- MUL, pass-throughs (C still unknown), a writer, the readers
	.irp p, "movs r0, #5", "movs r0, #0", "movs r0, #200", "lsls r0, r1, #0", "movs r0, r2", "ands r0, r1", "eors r0, r1", "orrs r0, r1", "bics r0, r1", "mvns r0, r1", "tst r0, r1", "lsls r0, r6", "lsrs r0, r6", "asrs r0, r6", "rors r0, r6", "lsls r0, r7", "rors r0, r7", "mov r8, r0", "add r0, r8", "mov r0, r9", "ldr r0, [r7, #0]"
	MULA
	movs	r0, r1
	INS	\p
	INS	\p
	adds	r0, r0, #0		@ the writer: C = 0
	READERS
	MULB
	movs	r0, r1
	INS	\p
	cmp	r0, r0			@ the writer: C = 1
	READERS
	.endr
	POOL
	@ more pass-throughs: loads, stores, branches, BL, stack and PC forms
	movs	r0, #5
	mov	r8, r0
	MULA
	ldr	r0, =DATA
	ldr	r1, [r0, #4]
	ldrb	r2, [r0, #5]
	str	r1, [r0, #0x40]
	strh	r2, [r0, #0x3e]
	push	{r1, r2}
	pop	{r1, r2}
	add	sp, #8
	sub	sp, #8
	add	r3, sp, #4
	adr	r4, 2f
	b	1f
	nop
1:	bl	3f
	ldr	r5, =0x12345678
	beq	1f			@ Z is known: not a C reader
	nop
1:	bmi	1f
	nop
1:	bvs	1f
	nop
1:	bge	1f
	nop
1:	cmp	r1, r1
	READERS
	b	4f
	.balign 4
2:	.word	0
3:	mov	r6, lr
	bx	lr
4:	POOL

	@ ---- in ARM state after a Thumb MUL
	.macro TOARM
	ldr	r0, =8f
	bx	r0
	.balign 4
8:	.arm
	.endm
	.macro TOTHUMB
	add	r0, pc, #1
	bx	r0
	.thumb
	.endm

	ldr	r1, =0x80000001
	movs	r2, #3
	@ the ARM writers, each followed by the ARM readers
	.irp w, "adds r0, r1, r2", "subs r0, r1, r2", "cmp r1, r2", "cmn r1, r2", "rsbs r0, r1, #0", "movs r0, r1, lsl #1", "movs r0, r1, lsr #1", "movs r0, r1, asr #32", "movs r0, r1, ror #4", "ands r0, r1, r2, lsl #31", "tst r1, r2, lsr #1", "teq r1, r2, ror #1", "movs r0, #0x80000000", "ands r0, r1, #0xf0000000", "msr cpsr_f, #0x20000000", "msr cpsr_f, #0", "movs r0, r1, lsl r2"
	MULA
	TOARM
	INS	\w
	addcs	r0, r0, #1
	addcc	r0, r0, #2
	addhi	r0, r0, #4
	addls	r0, r0, #8
	adc	r4, r1, r2
	sbc	r4, r1, r2
	rsc	r4, r1, r2
	mov	r4, r1, rrx
	adds	r4, r1, r1, rrx
	mrs	r4, cpsr
	TOTHUMB
	MULB
	TOARM
	INS	\w
	adccs	r0, r0, #1
	sbcls	r0, r0, #2
	mrs	r4, cpsr
	TOTHUMB
	POOL
	.endr
	@ ARM pass-throughs after a Thumb MUL, then a writer, then readers
	.irp p, "movs r0, r1", "movs r0, #1", "ands r0, r1, r2", "orrs r0, r1, #0xff", "eors r0, r1, r2", "bics r0, r1, r2", "mvns r0, r1", "tst r1, #1", "teq r1, r2", "movs r0, r1, lsl r6", "mov r0, r1", "add r0, r1, r2", "ldr r0, [sp, #-4]", "mul r0, r1, r2"
	movs	r6, #0
	MULA
	TOARM
	INS	\p
	INS	\p
	cmp	r1, r1			@ the writer
	adc	r4, r1, r2
	rsccs	r4, r1, r2
	mrs	r4, cpsr
	TOTHUMB
	POOL
	.endr
	END

	.balign 4
pairs:	.word	0x00000000, 0x80000000
	.word	0x80000000, 0x00000000
	.word	0x00000003, 0x00000005
	.word	0xffffffff, 0xffffffff
	.word	0x12345678, 0x9abcdef0
	.word	0x00010000, 0x00010000
	.word	0x7fffffff, 0x00000002
	.word	0x0000ffff, 0xffff0001
	.word	0x00000001, 0x00000001
	.word	0x000000ff, 0x00ffffff
	.word	0xff000000, 0x00000100
	.word	0x80000001, 0x80000001
	.word	0xfffffffe, 0x00000002
	.word	0x00000000, 0x00000000
pairs_end:
