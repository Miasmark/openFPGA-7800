@ Code that ends exactly at the halfword boundary of a word: Thumb code
@ whose last instruction is the high half of a word, so that the next
@ sequential fetch would be the next word, which holds data (a literal
@ pool, a table, 0xFFFFFFFF) or ARM code; and code that ends at the low
@ half, with a halfword that is never run (0xDE00) after it. The last
@ instruction is each kind of transfer: BX LR (to Thumb and to ARM),
@ POP {pc}, B, B<cond> taken, MOV pc, ADD pc, LDMIA-free tail calls with a
@ BL whose suffix is the high half. Then the end of the code space: the
@ last halfword, 0x3FFE, holds BX LR, reached in sequence from 0x3FFC and
@ by a jump straight to it; the reference's fetch beyond the ROM is
@ discarded and the core must not halt (running on past 0x3FFE halts,
@ halt_thumb.py).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	movs	r7, #0
	bl	f_bx_hi
	bl	f_bx_lo
	bl	f_pop_hi
	bl	f_b_hi
	bl	f_bcc_hi
	bl	f_movpc_hi
	bl	f_addpc_hi
	bl	f_tail_hi
f_tail_back:
	ldr	r0, =a_func		@ ARM, returns with BX LR
	ldr	r1, =1f + 1
	mov	lr, r1
	bx	r0
	.balign 4
1:	bl	f_toarm_hi		@ ends in BX to the ARM word after it
	@ ---- the last halfword of the code space
	bl	last_word		@ 0x3FFC, then BX LR at 0x3FFE
	ldr	r0, =1f + 1
	mov	lr, r0
	ldr	r0, =0x3ffe		@ straight to 0x3FFE
	mov	pc, r0
	.balign 4
1:	ldr	r0, =1f + 1
	mov	lr, r0
	ldr	r0, =0x3fff		@ BX to 0x3FFE, Thumb
	bx	r0
	.balign 4
1:	movs	r0, r7
	END

	@ ---- functions ending at the high half, data after
	.balign 4
f_bx_hi:
	adds	r7, #1
	bx	lr			@ 2 mod 4
	.word	0xffffffff

	.balign 4
	nop
f_bx_lo:
	adds	r7, #2
	bx	lr			@ 0 mod 4
	.hword	0xde00
	.word	0xdeaddead

	.balign 4
f_pop_hi:
	push	{r4, lr}
	adds	r7, #4
	nop
	pop	{r4, pc}		@ 2 mod 4
	.word	0xe7f000f0		@ an ARM undefined instruction, as data

	.balign 4
f_b_hi:	push	{lr}
	b	1f			@ 2 mod 4
	.word	0x00000000
1:	adds	r7, #8
	pop	{pc}
	.hword	0xde00

	.balign 4
f_bcc_hi:
	movs	r0, #0
	beq	1f			@ 2 mod 4, taken
	.word	0xffffffff
1:	adds	r7, #16
	bx	lr
	.hword	0xde00

	.balign 4
	nop
f_movpc_hi:
	mov	pc, lr			@ 2 mod 4
	.word	0x12345678

	.balign 4
f_addpc_hi:
	movs	r0, #2
	add	pc, r0			@ 2 mod 4: to address + 4 + 2
	.word	0xffffffff
	adds	r7, #32
	bx	lr
	.hword	0xde00

	.balign 4
f_tail_hi:				@ a tail call: the BL suffix is the high half
	nop
	nop
	bl	f_tail_target		@ prefix 0 mod 4, suffix 2 mod 4
	.word	0xffffffff
f_tail_target:
	adds	r7, #64
	ldr	r0, =f_tail_back + 1
	bx	r0
	.ltorg

	.balign 4
	nop
f_toarm_hi:
	adds	r7, #128
	ldr	r0, =1f
	bx	r0			@ 2 mod 4, to the ARM word after it
	.arm
	.balign 4
1:	add	r7, r7, #256
	bx	lr			@ back to Thumb (LR odd)

	.arm
	.balign 4
a_func:	add	r7, r7, #512
	bx	lr
	.ltorg

	.thumb
	.org	0x3ffc - 0x20
last_word:
	adds	r7, #1			@ 0x3FFC
	bx	lr			@ 0x3FFE, the last halfword
