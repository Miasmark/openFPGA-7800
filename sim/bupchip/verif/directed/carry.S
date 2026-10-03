@ Every shifter carry-out position: MOVS with each shift type by immediate
@ amounts 1, 2, 16, 31 and the amount-0 encodings (LSL #0, LSR #32, ASR
@ #32, RRX), and by register amounts 0, 1, 2, 16, 31, 32, 33, 64, 255 and
@ 0x100, on values whose neighbouring bits differ (0x55555555, 0xaaaaaaaa)
@ and whose end bits differ (0x00000001, 0x80000000, 0x7ffffffe,
@ 0xfffffffe), with C in 0 and 1. s1/directed/shifts.S uses values whose
@ bit 0 equals bit 31, so it cannot tell RRX's carry (bit 0) from bit 31;
@ a core with that bug passed it. Ends by summing the signature.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	.macro VALS
	.word	0x55555555, 0xaaaaaaaa, 0x00000001, 0x80000000, 0x7ffffffe, 0xfffffffe
	.endm

	.macro IMM sh, amt
	ldr	r9, =vals
	mov	r8, #6
1:	ldr	r4, [r9], #4
	.irp cin, 0, 2
	SETF	\cin
	movs	r0, r4, \sh #\amt
	SIG	r0
	SIGF
	.endr
	subs	r8, r8, #1
	bne	1b
	.endm
	.irp amt, 1, 2, 16, 31
	IMM	lsl, \amt
	IMM	lsr, \amt
	IMM	asr, \amt
	IMM	ror, \amt
	.endr
	IMM	lsl, 0
	IMM	lsr, 32
	IMM	asr, 32
	POOL

	@ RRX
	ldr	r9, =vals
	mov	r8, #6
2:	ldr	r4, [r9], #4
	.irp cin, 0, 2
	SETF	\cin
	movs	r0, r4, rrx
	SIG	r0
	SIGF
	SETF	\cin
	ands	r0, r4, r4, rrx			@ a logical op: C from the shifter
	SIGF
	.endr
	subs	r8, r8, #1
	bne	2b

	@ by register
	.irp sh, lsl, lsr, asr, ror
	ldr	r7, =amts
3:	ldr	r2, [r7], #4
	cmp	r2, #0x200			@ the list ends with 0x200
	beq	5f
	ldr	r9, =vals
	mov	r8, #6
4:	ldr	r4, [r9], #4
	.irp cin, 0, 2
	SETF	\cin
	movs	r0, r4, \sh r2
	SIG	r0
	SIGF
	.endr
	subs	r8, r8, #1
	bne	4b
	b	3b
5:
	.endr

	ldr	r1, =__sig_start
	mov	r0, #0
6:	ldr	r2, [r1], #4
	add	r0, r0, r2
	cmp	r1, r11
	bne	6b
	SIG	r0
	b	7f
vals:
	VALS
amts:
	.word	0, 1, 2, 16, 31, 32, 33, 64, 255, 0x100, 0x200
7:
	END
