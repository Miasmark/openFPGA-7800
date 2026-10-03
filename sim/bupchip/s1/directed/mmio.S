@ Peripheral accesses: one access per instruction, in order; a
@ condition-failed read or write must not happen at all (a read of 0x04
@ would pop a command, a write of 0x10 push a frame); byte and halfword
@ reads (the peripheral decodes the full byte address); register offsets
@ and write-back; reads of unused registers.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r5, =MMIO
	ldr	r0, [r5]			@ IDENT
	SIG	r0
	ldrb	r0, [r5]
	SIG	r0
	ldrb	r0, [r5, #1]
	SIG	r0
	ldrh	r0, [r5, #2]
	SIG	r0
	ldr	r0, [r5, #0x14]
	SIG	r0
	movs	r0, #0
	ldrne	r0, [r5, #4]			@ fails: must not pop
	strne	r0, [r5, #0x10]			@ fails: must not push
	ldreq	r1, [r5, #0x08]
	SIG	r1
	mov	r6, #0x14
	ldr	r0, [r5, r6]
	SIG	r0
	ldr	r1, =0x01234567
	str	r1, [r5, #0x10]			@ push
	strb	r1, [r5, #0x10]			@ push, byte on every lane
	mov	r6, #0x10
	str	r1, [r5, r6]			@ push, register offset
	ldr	r0, [r5, #0x14]
	SIG	r0
	ldr	r0, [r5, #0x20]			@ unused: reads 0
	SIG	r0
	add	r4, r5, #0
	ldr	r0, [r4, #0x14]!
	SIG	r4
	mov	r0, #3
	str	r0, [r5, #0x0c]			@ clear the command FIFO
	END
