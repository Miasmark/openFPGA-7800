@ Addressing modes and write-back: pre and post index, immediate and
@ register offsets, up and down, for word, byte, halfword and signed loads
@ and stores; Rd == Rn with write-back (a load keeps the loaded value, a
@ store stores the old base: ARM7TDMI), including register-offset stores,
@ whose data the core reads in W; LDRT/STRT/LDRBT/STRBT (post-index with W,
@ one privilege level here); Rm == Rn; the firmware's "ldrh r7,[r3,-r2]!".
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	mov	r3, #12
	.macro AM ld, st, off
	add	r2, r12, #64
	\ld	r0, [r2, \off]
	SIG	r0
	SIG	r2
	\ld	r0, [r2, \off]!
	SIG	r0
	SIG	r2
	\ld	r0, [r2], \off
	SIG	r0
	SIG	r2
	add	r2, r12, #128
	mvn	r0, r2
	\st	r0, [r2, \off]
	\st	r0, [r2, \off]!
	\st	r0, [r2], \off
	SIG	r2
	.endm
	.irp off, #4, #-4, r3, -r3
	AM	ldr, str, \off
	AM	ldrb, strb, \off
	AM	ldrh, strh, \off
	AM	ldrsb, strb, \off
	AM	ldrsh, strh, \off
	.endr
	AM	ldr, str, "r3, lsl #2"
	AM	ldrb, strb, "-r3, asr #1"
	POOL

	@ Rd == Rn with write-back
	.macro SAME ld, st, off
	add	r2, r12, #160
	\ld	r2, [r2, \off]!
	SIG	r2
	add	r2, r12, #160
	\ld	r2, [r2], \off
	SIG	r2
	add	r2, r12, #192
	\st	r2, [r2, \off]!
	SIG	r2
	add	r2, r12, #192
	\st	r2, [r2], \off
	SIG	r2
	ldr	r0, [r12, #192]
	SIG	r0
	ldr	r0, [r12, #196]
	SIG	r0
	ldr	r0, [r12, #188]
	SIG	r0
	.endm
	.irp off, #4, #-4, r3, -r3
	SAME	ldr, str, \off
	SAME	ldrb, strb, \off
	SAME	ldrh, strh, \off
	SAME	ldrsh, strh, \off
	.endr
	POOL

	@ T forms
	add	r2, r12, #64
	ldrt	r0, [r2], #4
	SIG	r0
	SIG	r2
	ldrbt	r0, [r2], #-1
	SIG	r0
	SIG	r2
	strt	r0, [r2], r3
	SIG	r2
	strbt	r0, [r2], -r3
	SIG	r2
	ldr	r0, [r12, #64]
	SIG	r0
	@ Rm == Rn, Rd == Rm
	ldr	r2, =0x20001000
	ldr	r0, [r2, r2]			@ DATA
	SIG	r0
	ldr	r0, [r2, r2]!
	SIG	r0
	SIG	r2
	mov	r2, #8
	ldr	r2, [r12, r2]
	SIG	r2
	mov	r2, #8
	add	r4, r12, #0
	str	r2, [r4, r2]!
	SIG	r4
	mov	r2, #2
	add	r4, r12, #16
	ldrh	r2, [r4, -r2]!			@ like the firmware's ldrh r7,[r3,-r2]!
	SIG	r2
	SIG	r4
	END
