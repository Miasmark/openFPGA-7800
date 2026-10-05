@ Shared frame of the Thumb directed tests (../run_directed.sh) and of the
@ halt tests (../halt_thumb.py): the ARM vectors and start-up (SVC mode with
@ IRQ and FIQ masked, as the core leaves reset), sp at the top of RAM, r11 =
@ signature pointer (RAM 0x40000000, 8 KiB), a known pattern in the data
@ area (RAM 0x40002000, 256 bytes: word i = 0x83828180 + 0x04040404 * i),
@ then BX into Thumb at thumb_main. END returns to ARM, writes the signature
@ length to the PCM push register and 0xAA to FAULT (0xE000901C), where both
@ cores stop.
@
@ The exception vectors write 0xE1 (undefined), 0xE2 (SWI), 0xE3 (prefetch
@ abort) or 0xE4 (data abort) to FAULT instead, so a reference run that
@ takes one stops at once; the halt tests rely on that, and a directed test
@ that takes one fails (run_directed.sh wants fault=aa and no exception).
@
@ Every retire (PC, encoding, r0-r14, NZCV and T), every RAM store and
@ every peripheral access is compared in lockstep, so results need not be
@ stored; SIG stores one anyway where a value would otherwise be overwritten
@ unseen, and adds RAM stores to the comparison.
@
@ Thumb has no MSR, so SETF goes through ARM: BL to a Thumb veneer at a
@ word-aligned address, BX PC into ARM, MSR CPSR_f, BX LR back. That is
@ also a BL, a BX PC from an aligned address and a BX to Thumb each time.
@ SPDX-License-Identifier: MIT
	.syntax unified
	.cpu arm7tdmi

	.equ	MMIO, 0xE0009000
	.equ	FAULT, 0xE000901C
	.equ	DATA, 0x40002000
	.equ	ASSET, 0x02000000

	.macro SETF nzcv			@ NZCV from a 4-bit constant (Thumb; clobbers r0, lr)
	movs	r0, #\nzcv
	lsls	r0, r0, #28
	bl	setf_helper
	.endm

	.macro SIG reg				@ store a low register to the signature (Thumb; clobbers r8)
	mov	r8, sp
	mov	sp, r11
	str	\reg, [sp, #0]
	add	sp, #4
	mov	r11, sp
	mov	sp, r8
	.endm

	.macro POOL				@ a literal pool here, jumped over (Thumb)
	b	9f
	.ltorg
9:
	.endm

	.macro START
	.section .vectors, "ax"
	.arm
	.global _start
_start:
	b	reset
	b	exc_und
	b	exc_swi
	b	exc_pabt
	b	exc_dabt
	b	.
	b	.
	b	.
	.text
	.arm
exc_und:
	mov	r10, #0xe1
	b	exc_end
exc_swi:
	mov	r10, #0xe2
	b	exc_end
exc_pabt:
	mov	r10, #0xe3
	b	exc_end
exc_dabt:
	mov	r10, #0xe4
exc_end:
	ldr	r9, =FAULT
	str	r10, [r9]
	b	.
reset:
	ldr	sp, =__stack_top
	ldr	r11, =__sig_start
	ldr	r0, =DATA
	ldr	r1, =0x83828180
	ldr	r2, =0x04040404
	mov	r3, #64
1:	str	r1, [r0], #4
	add	r1, r1, r2
	subs	r3, r3, #1
	bne	1b
	ldr	r0, =thumb_main + 1
	bx	r0
arm_end:
	ldr	r0, =__sig_start
	sub	r0, r11, r0
	ldr	r1, =MMIO
	str	r0, [r1, #0x10]
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.
	.ltorg
	.thumb
	.balign 4
setf_helper:
	bx	pc				@ word-aligned: ARM at setf_helper + 4
	nop
	.arm
	msr	cpsr_f, r0
	bx	lr
	.thumb
	.balign 4
	.endm

	.macro END				@ back to ARM and the end marker (Thumb)
	ldr	r0, =arm_end
	bx	r0
	.ltorg
	.endm
