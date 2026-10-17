@ Format 19, BL, as two instructions (the reference retires two):
@   forward and backward, near and far (a function at 0x3800); backward
@   from below 0x1000, where the prefix's LR (address + 4 - 4096) wraps
@   to 0xFFFFFxxx and the suffix's 32-bit sum wraps back; the pair within
@   one word and across a word boundary; targets in either half of a word;
@   returns by BX LR, MOV pc, lr (bit 0 dropped, still Thumb) and POP {pc};
@   nested calls (a recursive function);
@   a lone prefix (0xF000, 0xF7FF, 0xF400, 0xF3FF): LR = address + 4 +
@   (sext(imm11) << 12), and the next instruction is not a suffix;
@   a lone suffix with a prepared LR (odd and even; bit 0 of the target
@   is dropped), with offsets 0, 1 and 0x7FF: PC = LR + (imm11 << 1), LR =
@   (address + 2) | 1;
@   a prefix and its suffix with other instructions between them (LR from
@   the register file instead of the bypass; LATE_RF).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	.balign 4
back_near:				@ a backward target below 0x1000
	adds	r7, #1
	bx	lr
	.balign 4
	nop
back_hi:				@ a backward target in the high half
	adds	r7, #2
	mov	pc, lr			@ LR is odd: bit 0 dropped, still Thumb
thumb_main:
	movs	r7, #0
	@ ---- backward, from below 0x1000: LR wraps
	bl	back_near		@ pair in one word or not, see below
	bl	back_hi
	.balign 4
	bl	back_near		@ pair at 0 and 2 mod 4
	nop
	bl	back_hi			@ pair at 2 mod 4 and the next word
	@ ---- forward, near
	bl	fwd_near
	.balign 4
	nop
	bl	fwd_near		@ across a word boundary
	@ ---- far: a function at 0x3800, and back from there
	bl	far_func
	@ ---- nested: depth 6, push {lr} / pop {pc}
	movs	r0, #6
	bl	recurse
	@ ---- a lone prefix: only LR changes
	.balign 4
	.hword	0xf000			@ LR = address + 4
	mov	r1, lr
	.hword	0xf7ff			@ LR = address + 4 - 0x1000: wraps
	mov	r2, lr
	.hword	0xf400			@ LR = address + 4 - 0x400000
	mov	r3, lr
	.hword	0xf3ff			@ LR = address + 4 + 0x3FF000
	mov	r4, lr
	.hword	0xf000			@ a prefix, then another one
	.hword	0xf001
	mov	r5, lr
	@ ---- a lone suffix with a prepared LR
	ldr	r0, =ls1 + 1		@ odd: bit 0 dropped
	mov	lr, r0
	.hword	0xf800			@ offset 0
	.hword	0xde00
	.balign 4
ls1:	mov	r1, lr			@ (suffix address + 2) | 1
	ldr	r0, =ls2 - 2		@ even, offset 1 (2 bytes)
	mov	lr, r0
	.hword	0xf801
	.hword	0xde00
	.balign 4
	.hword	0xde00
ls2:	mov	r2, lr
	ldr	r0, =ls3 - 0xffe + 1	@ offset 0x7FF (0xFFE bytes), odd
	mov	lr, r0
	.hword	0xffff
	.hword	0xde00
	.balign 4
ls3:	mov	r3, lr
	POOL
	@ ---- a prefix, then other instructions, then its suffix
	.balign 4
	movs	r6, #0
pre1:	.hword	0xf000			@ LR = pre1 + 4
	movs	r6, #1
	ldr	r0, =0x13579bdf		@ a load in between (two clocks)
	.equ	off1, (sufx1 - (pre1 + 4)) / 2
	.hword	0xf800 | off1		@ to LR + (off1 << 1) = sufx1
	.hword	0xde00
	.balign 4
sufx1:	mov	r4, lr
	b	after
	POOL

	.balign 4
fwd_near:
	adds	r7, #4
	bx	lr
	nop
recurse:				@ r0 levels deep, r7 += 1 per level
	push	{lr}
	adds	r7, #1
	subs	r0, #1
	beq	1f
	bl	recurse
1:	pop	{pc}

after:	movs	r0, r7
	END

	@ ---- far: at 0x3800, and from there backward to below 0x100
	.org	0x3800 - 0x20
far_func:
	push	{r4, lr}
	adds	r7, #8
	bl	back_near
	pop	{r4, pc}
