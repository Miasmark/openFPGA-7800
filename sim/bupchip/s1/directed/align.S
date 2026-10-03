@ Unaligned and odd accesses, as the ARM7TDMI does them: LDR at offsets 1-3
@ rotates the aligned word; LDRH at an odd address returns the aligned
@ halfword rotated right by 8; LDRSH at an odd address is LDRSB; LDRB and
@ LDRSB on every lane; STR to an unaligned address writes the aligned
@ word, STRH to an odd one the aligned halfword. From RAM, ROM and the
@ asset window (whose bytes have both signs).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r5, =ASSET
	ldr	r6, =rodata
	.macro LANES base
	.irp off, 0, 1, 2, 3, 4, 5, 6, 7
	ldr	r0, [\base, #\off]
	SIG	r0
	ldrh	r0, [\base, #\off]
	SIG	r0
	ldrsh	r0, [\base, #\off]
	SIG	r0
	ldrb	r0, [\base, #\off]
	SIG	r0
	ldrsb	r0, [\base, #\off]
	SIG	r0
	.endr
	.endm
	LANES	r12
	LANES	r5
	LANES	r6
	@ asset bytes further in, with register offsets
	mov	r1, #0x300
	.irp off, 1, 2, 3, 0x81, 0xc3
	add	r2, r5, #\off
	ldr	r0, [r2, r1]
	SIG	r0
	ldrsh	r0, [r2, r1]
	SIG	r0
	.endr
	@ stores
	ldr	r0, =0xa1b2c3d4
	str	r0, [r12, #33]
	strh	r0, [r12, #43]
	strh	r0, [r12, #49]
	strb	r0, [r12, #55]
	str	r0, [r12, #62]
	.irp off, 32, 40, 48, 52, 60
	ldr	r1, [r12, #\off]
	SIG	r1
	.endr
	@ write-back keeps the unaligned address
	add	r2, r12, #1
	ldr	r0, [r2, #4]!
	SIG	r0
	SIG	r2
	ldrh	r0, [r2], #2
	SIG	r0
	SIG	r2
	b	1f
rodata:
	.word	0x8899aabb, 0xccddeeff
1:
	END
