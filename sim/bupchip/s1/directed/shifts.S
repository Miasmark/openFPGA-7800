@ The barrel shifter: shift by register with amounts 0/1/31/32/33/224/255,
@ each type, with and without S, carry in 0 and 1, on values with both end
@ bits set and clear; immediate amounts 1 and 31; the immediate encodings of
@ amount 0 (LSR #32, ASR #32, RRX) with and without S, in data processing
@ and as scaled register offsets; rotated immediates with rotation 0 and
@ not 0 (C from bit 31 or unchanged); logical and arithmetic S operations
@ with every operand-2 form.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r4, =0x80000001
	ldr	r5, =0x7ffffffe
	ldr	r6, =0x40000000

	@ ---- shift by register
	.macro RSH amt
	mov	r2, #\amt
	.irp sh, lsl, lsr, asr, ror
	.irp cin, 0, 2
	.irp src, r4, r5, r6
	SETF	\cin
	movs	r0, \src, \sh r2
	SIG	r0
	SIGF
	mov	r0, \src, \sh r2		@ no S: NZCV as left by movs
	SIG	r0
	.endr
	SETF	\cin
	ands	r0, r4, r5, \sh r2
	SIGF
	SETF	\cin
	eors	r0, r6, r4, \sh r2
	SIG	r0
	SIGF
	SETF	\cin
	adds	r0, r6, r4, \sh r2
	SIG	r0
	SIGF
	SETF	\cin
	tst	r4, r4, \sh r2
	SIGF
	.endr
	.endr
	.endm
	RSH	0
	RSH	1
	RSH	31
	POOL
	RSH	32
	RSH	33
	RSH	224
	RSH	255
	POOL

	@ ---- shift by immediate, including the amount-0 encodings
	.macro ISH sh, amt
	.irp cin, 0, 2
	.irp src, r4, r5, r6
	SETF	\cin
	movs	r0, \src, \sh #\amt
	SIG	r0
	SIGF
	SETF	\cin
	mvn	r0, \src, \sh #\amt
	SIG	r0
	SETF	\cin
	bics	r0, r4, \src, \sh #\amt
	SIG	r0
	SIGF
	SETF	\cin
	rsbs	r0, r6, \src, \sh #\amt
	SIG	r0
	SIGF
	.endr
	.endr
	.endm
	ISH	lsl, 0
	ISH	lsl, 1
	ISH	lsl, 31
	ISH	lsr, 1
	ISH	lsr, 31
	ISH	lsr, 32
	ISH	asr, 1
	ISH	asr, 31
	ISH	asr, 32
	ISH	ror, 1
	ISH	ror, 31
	.irp cin, 0, 2
	.irp src, r4, r5, r6
	SETF	\cin
	movs	r0, \src, rrx
	SIG	r0
	SIGF
	SETF	\cin
	mov	r0, \src, rrx
	SIG	r0
	SIGF
	SETF	\cin
	teq	r4, \src, rrx
	SIGF
	SETF	\cin
	adcs	r0, r5, \src, rrx
	SIG	r0
	SIGF
	.endr
	.endr

	@ ---- rotated immediates: C = bit 31 when the rotation is not 0
	.irp cin, 0, 2
	SETF	\cin
	movs	r0, #0x80000000
	SIGF
	SETF	\cin
	movs	r0, #0x40000000
	SIGF
	SETF	\cin
	movs	r0, #0xff
	SIGF
	SETF	\cin
	ands	r0, r4, #0xc0000003
	SIG	r0
	SIGF
	SETF	\cin
	tst	r4, #0x40000
	SIGF
	SETF	\cin
	orrs	r0, r5, #0x3f0
	SIG	r0
	SIGF
	.endr

	POOL
	@ ---- scaled register offsets with the amount-0 encodings (C clear for RRX)
	mov	r3, #8
	mvn	r7, #0				@ -1
	ldr	r0, [r12, r3, lsr #32]		@ offset 0
	SIG	r0
	ldr	r0, [r12, -r7, asr #32]		@ offset -(-1) = +1: unaligned
	SIG	r0
	ldr	r0, [r12, r7, lsr #30]		@ +3
	SIG	r0
	SETF	0
	ldr	r0, [r12, r3, rrx]		@ +4
	SIG	r0
	SETF	2
	ldr	r8, =0xc0001ffc
	ldr	r0, [r8, r3, rrx]		@ C set: 0xc0001ffc + 0x80000004 = DATA
	SIG	r0
	ldrb	r0, [r12, r3, lsl #2]
	SIG	r0
	str	r4, [r12, r3, asr #1]
	ldr	r0, [r12, #4]
	SIG	r0
	END
