@ ARM <-> Thumb interworking in both directions:
@   ARM calls Thumb (MOV LR, PC; BX Rn: LR holds an ARM address) and the
@   Thumb function returns to ARM with BX LR, in a loop;
@   Thumb calls ARM through a veneer (BL to a Thumb BX PC stub; the ARM
@   function returns with BX LR, LR odd);
@   three levels nested: Thumb -> ARM -> Thumb -> ARM, each returning;
@   flags carried across every switch (ARM conditions on flags a Thumb
@   instruction set, Thumb B<cond> on flags ARM set);
@   ARM work in between: STM/LDM (no PC in the list, which halts), MLA,
@   UMULL, MRS (T reads 0 in ARM state), MSR CPSR_f, a shift by register;
@   Thumb in FIQ mode (MSR CPSR_c from ARM, then BX): F5 on the banked
@   r8-r12, PUSH/POP on FIQ's SP, BL writing FIQ's LR; and in SYS mode
@   (the user SP and LR); then back to SVC with every bank intact.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	ldr	r0, =arm_main
	bx	r0
	.ltorg

	@ ---- ARM calls Thumb, four times round
	.arm
	.balign 4
arm_main:
	mov	r4, #4
	mov	r7, #0
1:	ldr	r5, =t_add + 1
	mov	lr, pc			@ the instruction after the BX
	bx	r5
	addcs	r7, r7, #0x100		@ C from the Thumb ADDS
	addvs	r7, r7, #0x200
	subs	r4, r4, #1
	bne	1b
	@ ARM work, with a Thumb call in the middle
	stmfd	sp!, {r4-r7, lr}
	ldr	r0, =0x12345678
	ldr	r1, =0x9abcdef0
	mla	r2, r0, r1, r7
	umull	r3, r4, r0, r1
	mov	r5, #5
	mov	r6, r0, ror r5
	ldr	r5, =t_add + 1
	mov	lr, pc
	bx	r5
	mrs	r8, cpsr		@ T = 0 here
	msr	cpsr_f, #0x90000000	@ N and V
	ldmfd	sp!, {r4-r7, lr}
	@ ---- back to Thumb for the Thumb-driven part
	ldr	r0, =t_part + 1
	bx	r0
	.ltorg

	.thumb
	.balign 4
t_add:	@ r7 += r4 and a flag result; returns to ARM (LR even)
	adds	r7, r4
	ldr	r0, =0x7fffffff
	adds	r0, r4			@ V
	lsrs	r1, r0, #1		@ C = bit 0
	bx	lr
	.ltorg

	.balign 4
t_part:
	bmi	1f			@ N and V from the ARM MSR
	.hword	0xde00
1:	bvs	1f
	.hword	0xde00
1:	movs	r6, #3
1:	bl	a_veneer		@ Thumb -> ARM -> Thumb -> ARM, nested
	subs	r6, #1
	bne	1b
	b	t_modes

	.balign 4
a_veneer:
	bx	pc
	nop
	.arm
	@ ARM level: r5 counts, calls a Thumb function, returns to Thumb
	stmfd	sp!, {r4, lr}
	add	r5, r5, #1
	ldr	r4, =t_mid + 1
	mov	lr, pc
	bx	r4
	movs	r0, r5, lsl #31		@ C and N for the Thumb caller
	ldmfd	sp!, {r4, lr}
	bx	lr
	.ltorg

	.thumb
	.balign 4
t_mid:	@ Thumb level: calls an ARM leaf, returns to ARM
	push	{r4, lr}
	ldr	r4, =a_leaf
	mov	r12, r4
	ldr	r4, =t_mid_ret + 1
	mov	lr, r4
	bx	r12
	.balign 4
t_mid_ret:
	bcs	1f			@ C from the ARM leaf
	adds	r5, #0x10
1:	pop	{r4}
	pop	{r0}
	bx	r0			@ LR was even: back to ARM
	.ltorg

	.arm
	.balign 4
a_leaf:	cmp	r5, #2			@ C = (r5 >= 2)
	mrs	r9, cpsr
	bx	lr

	@ ---- Thumb in FIQ and SYS mode
	.thumb
	.balign 4
t_modes:
	ldr	r0, =a_modes
	bx	r0
	.ltorg
	.arm
	.balign 4
a_modes:
	mov	r8, #8			@ SVC's (user) r8-r12
	mov	r9, #9
	mov	r10, #10
	mov	r12, #12
	msr	cpsr_c, #0xd1		@ FIQ, I and F masked
	ldr	sp, =0x40003800		@ FIQ's SP
	mov	r8, #0x80		@ FIQ's r8-r12
	mov	r9, #0x90
	mov	r10, #0xa0
	mov	r11, #0xb0
	mov	r12, #0xc0
	ldr	r0, =t_fiq + 1
	bx	r0
a_fiq_ret:
	msr	cpsr_c, #0xdf		@ SYS: the user SP and LR
	ldr	sp, =0x40003400
	ldr	r0, =t_sys + 1
	bx	r0
a_sys_ret:
	msr	cpsr_c, #0xd3		@ back to SVC
	mov	r0, r8			@ SVC sees the user r8-r12 again
	add	r0, r0, r9
	add	r0, r0, r10
	add	r0, r0, r12
	ldr	r1, =t_end + 1
	bx	r1
	.ltorg

	.thumb
	.balign 4
t_fiq:	@ FIQ mode: the banked r8-r14
	mov	r0, r8
	add	r0, r9
	add	r10, r0
	mov	r1, r11
	mov	r11, r12
	cmp	r10, r1
	mov	r2, sp
	push	{r0-r2, lr}
	bl	t_leaf			@ FIQ's LR
	pop	{r0-r2}
	pop	{r3}
	add	r8, r3			@ FIQ's r8 += the old FIQ LR
	ldr	r0, =a_fiq_ret
	bx	r0
t_sys:	@ SYS mode: the user r8-r14
	mov	r0, r8
	add	r0, r9
	add	r12, r0
	mov	r2, sp
	push	{r0, r2, lr}
	bl	t_leaf
	pop	{r0, r2, r3}
	mov	r1, lr
	ldr	r0, =a_sys_ret
	bx	r0
t_leaf:	mov	r3, lr
	movs	r4, #1
	add	r4, sp
	bx	lr
	.ltorg

	.balign 4
t_end:	mov	r1, r8
	mov	r2, r12
	END
