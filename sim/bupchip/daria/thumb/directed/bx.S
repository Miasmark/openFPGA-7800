@ Format 5 BX, both ways, through every register that can hold a target:
@   to Thumb (bit 0 set) through r0-r7, r8-r12, SP and LR, to the low and
@   the high half of a word, from both halves;
@   to ARM (bit 0 clear, bit 1 clear) through low and high registers, from
@   both halves; the ARM code returns with BX to Thumb;
@   BX PC from a word-aligned address: ARM at the address + 4 (the halfword
@   after the BX is never run);
@   targets written by the instruction just before (the bypass; LATE_RF),
@   by a load (W) and by a MOV (E).
@ T changes in the BX's own retire, and the lockstep compares it at every
@ retire. BX to ARM with bit 1 set, BX PC at 2 mod 4, and the encodings
@ with H1 or bits 2:0 set halt (halt_thumb.py).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	@ BX \reg to the code right after it, at a low (half 0) or high
	@ (half 1) halfword; the halfwords skipped are 0xDE00.
	.macro BXT reg, half
	ldr	r0, =bxt\@ + 1
	.ifnc \reg, r0
	mov	\reg, r0
	.endif
	bx	\reg
	.hword	0xde00
	.balign 4
	.hword	0xde00
	.if \half
	.hword	0xde00
	.endif
bxt\@:
	.endm

	@ ---- to Thumb, through each register, both target halves
	.irp r, r0, r8, r9, r10, r12, lr
	BXT	\r, 0
	BXT	\r, 1
	.endr
	POOL
	@ the low registers: a load straight into the register, then BX
	.irp r, r1, r2, r3, r4, r5, r6, r7
	ldr	\r, =1f + 1
	bx	\r
	.hword	0xde00
	.balign 4
	.hword	0xde00
1:	ldr	\r, =1f + 1
	bx	\r
	.hword	0xde00
	.hword	0xde00
	.balign 4
1:
	.endr
	POOL
	@ through r11 (the signature pointer, kept in r10 meanwhile)
	mov	r10, r11
	BXT	r11, 0
	BXT	r11, 1
	mov	r11, r10
	@ through SP
	mov	r12, sp
	ldr	r0, =1f + 1
	mov	sp, r0
	bx	sp
	.hword	0xde00
	.balign 4
1:	mov	sp, r12
	@ from the high half of a word, to both halves
	.balign 4
	nop
	ldr	r1, =1f + 1
	nop
	bx	r1			@ 2 mod 4
	.hword	0xde00
	.balign 4
1:	ldr	r1, =1f + 1
	bx	r1			@ 2 mod 4
	.hword	0xde00
	.balign 4
	.hword	0xde00
1:	POOL

	@ ---- to ARM and back, through low and high registers
	.macro BXA reg, hi
	.if \hi
	ldr	r0, =bxa\@
	mov	\reg, r0
	.else
	ldr	\reg, =bxa\@
	.endif
	bx	\reg
	.hword	0xde00
	.balign 4
bxa\@:	.arm
	add	r1, r1, #1
	add	r0, pc, #1		@ the Thumb code after the next ARM instruction
	bx	r0
	.thumb
	.endm

	movs	r1, #0
	.irp r, r0, r3, r7
	BXA	\r, 0
	.endr
	.irp r, r8, r10, r12, lr
	BXA	\r, 1
	.endr
	POOL
	@ from the high half
	.balign 4
	ldr	r2, =1f
	bx	r2			@ 2 mod 4
	.hword	0xde00
	.balign 4
1:	.arm
	add	r1, r1, #1
	add	r2, pc, #1
	bx	r2
	.thumb

	@ ---- BX PC from a word-aligned address: ARM at the address + 4
	.irp n, 1, 2, 3
	.balign 4
	bx	pc
	.hword	0xde00			@ never run
	.arm
	add	r1, r1, #\n
	orr	r3, pc, #1		@ Thumb at the next instruction but one
	bx	r3
	.thumb
	.endr

	@ ---- flags and registers across the switches
	SETF	9
	ldr	r0, =1f
	bx	r0
	.balign 4
1:	.arm
	addvs	r1, r1, #0x100		@ V set, C clear
	addcs	r1, r1, #0x200
	movs	r2, #0x80000000		@ N, and C = bit 31 (a rotated immediate)
	adr	r0, 2f + 1
	bx	r0
	.thumb
2:	bmi	3f
	.hword	0xde00
3:	bcs	4f
	.hword	0xde00
4:	END
