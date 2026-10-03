@ LDM/STM beyond s1/directed/ldmstm.S: the full list r0-r14 (n = 15, the
@ largest the core allows) in all four modes, with and without write-back
@ and with the base in the list; sp and lr as the base, the base highest in
@ the list with DA/DB write-back; an STM of registers written in the clock
@ before (by an ALU result, a load and UMULL), and an LDM straight after it
@ over the same words. Ends by summing the signature and the areas written
@ into a register, so that a store the core missed or added shows up in
@ lockstep (tb_lockstep.sv does not check that both store queues are empty
@ at the end).
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
	ldr	r0, =0x10101010
	.macro FILL				@ r0-r10, r13, r14 from r0; r11 and r12 kept
	add	r1, r0, #1
	add	r2, r0, #2
	add	r3, r0, #3
	add	r4, r0, #4
	add	r5, r0, #5
	add	r6, r0, #6
	add	r7, r0, #7
	add	r8, r0, #8
	add	r9, r0, #9
	add	r10, r0, #10
	add	sp, r0, #13
	add	lr, r0, #14
	.endm

	@ r12 is the base, at DATA + 0x800; r11 (the signature pointer) is in the
	@ list too, so it is saved at DATA + 0xff0 and restored after the loads
	.irp mode, ia, ib, da, db
	FILL
	ldr	r12, =DATA + 0x800
	stm\mode	r12, {r0-r14}
	SIG	r12
	FILL
	ldr	r12, =DATA + 0x800
	stm\mode	r12!, {r0-r14}		@ r12 not the lowest: the new base is stored
	SIG	r12
	ldr	r12, =DATA + 0x800
	ldm\mode	r12, {r0-r10}
	SIG	r0
	SIG	r10
	ldr	r12, =DATA + 0x800
	ldm\mode	r12!, {r0-r10, lr}
	SIG	r12
	SIG	lr
	ldr	r0, =DATA + 0xff0
	str	r11, [r0]
	ldr	r12, =DATA + 0x800
	ldm\mode	r12!, {r0-r14}		@ base in the list, write-back: the loaded value
	mov	r0, r11
	mov	r1, r12
	mov	r2, sp
	ldr	r11, =DATA + 0xff0
	ldr	r11, [r11]
	SIG	r0
	SIG	r1
	SIG	r2
	ldr	r12, =DATA
	ldr	sp, =__stack_top
	ldr	r0, =0x20202020
	.endr
	POOL

	@ sp and lr as the base, the base highest in the list
	ldr	r0, =0x30303030
	FILL
	add	sp, r12, #0x200
	stmdb	sp!, {r0-r3, sp}		@ base highest, DB, write-back: new base? (not first)
	SIG	sp
	ldmia	sp!, {r4-r8}
	SIG	r8
	SIG	sp
	add	lr, r12, #0x240
	stmda	lr!, {r1, r2, lr}
	SIG	lr
	add	lr, r12, #0x240
	ldmda	lr!, {r1, r2, lr}		@ lr loaded
	SIG	lr
	SIG	r1
	add	lr, r12, #0x240
	stmib	lr, {r0, lr}
	ldr	r0, [r12, #0x248]
	SIG	r0
	ldr	sp, =__stack_top

	@ STM of registers written just before
	mov	r1, #0x11
	mov	r2, #0x22
	add	r3, r12, #0x300
	stmia	r3!, {r1, r2}
	ldr	r4, [r12]
	stmia	r3!, {r4}			@ loaded the clock before
	ldr	r5, [r12, #4]
	ldr	r6, [r12, #8]
	stmdb	r3, {r5, r6}
	umull	r7, r8, r5, r6
	stmia	r3!, {r7, r8}			@ UMULL's halves
	ldmdb	r3, {r1, r2, r4, r5}		@ straight back
	SIG	r1
	SIG	r2
	SIG	r4
	SIG	r5
	SIG	r3

	@ sums
	ldr	r1, =__sig_start
	mov	r0, #0
1:	ldr	r2, [r1], #4
	add	r0, r0, r2
	cmp	r1, r11
	bne	1b
	add	r1, r12, #0x800 - 64
	add	r3, r12, #0x800 + 64
2:	ldr	r2, [r1], #4
	add	r0, r0, r2, ror #3
	cmp	r1, r3
	bne	2b
	add	r1, r12, #0x180
	add	r3, r12, #0x340
3:	ldr	r2, [r1], #4
	eor	r0, r2, r0, ror #1
	cmp	r1, r3
	bne	3b
	SIG	r0
	END
