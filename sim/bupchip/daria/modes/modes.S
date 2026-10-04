@ bup_cpu.sv with MODES 1 (DARIA's ARM-state additions): SVC, SYS and FIQ
@ switched by MSR, FIQ's r8-r14 and SVC's r13-r14 banked, the I and F bits
@ read back by MRS. Covers:
@   - every banked register read and written in each mode, and read again
@     after switching away and back, straight after the MSR;
@   - the 2600 drivers' music-helper pattern (MRS, MSR to FIQ, conditional
@     moves into r8-r13 or out of them, MSR back from a register, BX), called
@     from SYS mode with I and F clear, so the restore clears them again;
@   - flags across MSR: MSR of the f field, of f and c together, and an MSR
@     whose condition fails;
@   - banked registers as LDM/STM lists, load destinations (port W), store
@     data (one- and two-clock), multiply operands and destinations, and a
@     shift-by-register amount.
@ It runs on tb_ref_trace and in lockstep (run_modes.sh); with MODES 0 the
@ core must halt with code 1 (UNDEF) at the first MSR to SYS.
@ r6 is the signature pointer here (r11 is banked in FIQ mode), r5 the data
@ area.
@ SPDX-License-Identifier: MIT
#include "common.inc"

	.macro S reg
	str	\reg, [r6], #4
	.endm
	.macro SF				@ the whole CPSR, as MRS reads it
	mrs	r0, cpsr
	str	r0, [r6], #4
	.endm
	.macro SBANK				@ r8-r14 of the current mode
	S	r8
	S	r9
	S	r10
	S	r11
	S	r12
	S	r13
	S	r14
	.endm

	START
	mov	r6, r11
	mov	r5, r12
	SF					@ SVC, I and F masked: 0xd3

	@ ---- SVC and SYS: r13 and r14 -----------------------------------------
	ldr	lr, =0x5e1414e5
	mov	r7, sp
	.global	first_sys
first_sys:
	msr	cpsr_c, #0xdf			@ SYS, I and F masked
	S	sp				@ the user r13 and r14, 0 since reset
	S	lr
	SF
	ldr	sp, =0x40003c00			@ a user stack, used at the end
	ldr	lr, =0x14141414
	msr	cpsr_c, #0xd3			@ back to SVC
	S	sp				@ SVC's again
	S	lr
	cmp	sp, r7
	SF
	msr	cpsr_c, #0x1f			@ SYS, I and F clear
	S	sp
	S	lr
	SF

	@ ---- FIQ: r8-r14 -------------------------------------------------------
	ldr	r8, =0x08080808
	ldr	r9, =0x09090909
	ldr	r10, =0x0a0a0a0a
	ldr	r11, =0x0b0b0b0b
	ldr	r12, =0x0c0c0c0c
	msr	cpsr_c, #0xd1			@ FIQ, I and F masked
	SBANK					@ all 0 since reset
	SF
	mov	r8, #0x81
	mov	r9, #0x91
	add	r0, r8, r9			@ read the write of the clock before
	S	r0
	mov	r10, #0xa1
	mov	r11, #0xb1
	mov	r12, #0xc1
	ldr	r13, =0xd1d1d1d1
	ldr	r14, =0xe1e1e1e1
	msr	cpsr_c, #0xdf			@ SYS: the user registers, straight after
	SBANK
	mov	r8, #0x80			@ a user write just before the switch
	msr	cpsr_c, #0xd1
	S	r8				@ FIQ's 0x81
	mov	r8, #0x82			@ a FIQ write just before the switch
	msr	cpsr_c, #0x1f
	S	r8				@ the user 0x80
	msr	cpsr_c, #0xd1
	msr	cpsr_c, #0xd1			@ the same mode again
	SBANK
	msr	cpsr_c, #0xd3			@ FIQ straight to SVC
	SBANK					@ user r8-r12, SVC r13-r14
	msr	cpsr_c, #0xd1			@ SVC straight to FIQ
	SBANK
	POOL

	@ ---- the music helpers, from SYS with I and F clear -------------------
	msr	cpsr_c, #0x1f
	mov	r2, #0
	ldr	r3, =0x00012345
	bl	set_note
	SF					@ the helper's CMP r2, #1 and the mode back
	mov	r2, #1
	ldr	r3, =0x00067890
	bl	set_note
	SF
	mov	r2, #2
	ldr	r3, =0x000abcde
	bl	set_note
	SF
	S	sp				@ the user r13, untouched
	msr	cpsr_c, #0xd1
	mov	r8, #0x18			@ counters to read back
	mov	r9, #0x19
	mov	r10, #0x1a
	msr	cpsr_c, #0x1f
	mov	r2, #1
	bl	get_wave
	S	r2
	mov	r2, #1
	bl	reset_wave
	mov	r2, #1
	bl	get_wave
	S	r2
	mov	r2, #2
	bl	get_wave
	S	r2
	mov	r2, #0
	bl	reset_wave
	msr	cpsr_c, #0xd1
	SBANK					@ r8 = 0, r9 = 0, r11-r13 the notes
	SF

	@ ---- flags across MSR ----------------------------------------------------
	SETF	0
	ldr	r0, =0x600000df			@ Z and C, and SYS, in one MSR
	msr	cpsr_fc, r0
	SF
	S	r8				@ the user r8
	msr	cpsr_f, #0x90000000		@ flags only: the mode stays
	SF
	SETF	4				@ Z set
	msrne	cpsr_c, #0xd1			@ fails: still SYS
	SF
	S	r8
	msreq	cpsr_c, #0xd1			@ passes
	SF
	S	r8
	POOL

	@ ---- banked registers in other instructions (in FIQ mode) -------------
	add	r0, r5, #0x40
	ldmia	r0, {r8-r14}			@ seven loads into the bank
	SBANK
	add	r0, r5, #0x100
	stmia	r0!, {r8-r14}			@ STM of the bank, with write-back
	S	r0
	ldr	r8, [r5, #4]			@ load data into a banked register
	ldr	r9, [r5, #8]!			@ with a write-back base
	ldrb	r10, [r5, #3]
	sub	r5, r5, #8
	S	r8
	S	r9
	S	r10
	str	r13, [r5, #0x180]		@ one-clock store of a banked register
	mov	r1, #0x1c0
	str	r14, [r5, r1]			@ two-clock store (register offset)
	ldr	r0, [r5, #0x180]
	S	r0
	ldr	r0, [r5, r1]
	S	r0
	mov	r11, #3
	mov	r12, #7
	mul	r8, r11, r12			@ multiply in and out of the bank
	mla	r9, r8, r12, r11
	umull	r10, r11, r9, r12
	S	r8
	S	r9
	S	r10
	S	r11
	mov	r12, #5
	mov	r13, r9, lsl r12		@ shift amount from a banked register
	S	r13
	msr	cpsr_c, #0xdf
	SBANK					@ the user bank is unchanged
	stmdb	sp!, {r8-r12}			@ the user sp as a base
	S	sp

	@ ---- end, in SVC --------------------------------------------------------
	msr	cpsr_c, #0xd3
	SF
	mov	r11, r6
	END

@ The helpers. r2 is the voice (0-2); r8-r10 are the counters and r11-r13
@ the frequencies, in FIQ mode.
set_note:					@ frequency r2 = r3
	mrs	r4, cpsr
	msr	cpsr_c, #0xd1
	cmp	r2, #1
	movlt	r11, r3
	moveq	r12, r3
	movgt	r13, r3
	msr	cpsr_c, r4
	bx	lr
reset_wave:					@ counter r2 = 0
	mrs	r4, cpsr
	msr	cpsr_c, #0xd1
	cmp	r2, #1
	movlt	r8, #0
	moveq	r9, #0
	movgt	r10, #0
	msr	cpsr_c, r4
	bx	lr
get_wave:					@ r2 = counter r2
	mrs	r4, cpsr
	msr	cpsr_c, #0xd1
	cmp	r2, #1
	movlt	r2, r8
	moveq	r2, r9
	movgt	r2, r10
	msr	cpsr_c, r4
	bx	lr
