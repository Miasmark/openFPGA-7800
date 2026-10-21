@ Directed hazards of L1F/L1W/L3 (one-clock Thumb loads whose data
@ arrives with the next instruction, a one-entry write-behind register lb, LDMIA/POP's last
@ register handed over the same way). Every retire is compared in lockstep with the reference.
@ SPDX-License-Identifier: MIT
#include "common.inc"
	START
thumb_main:
	ldr	r7, =DATA		@ word i = 0x83828180 + 0x04040404 * i
	ldr	r6, =DATA + 0x100	@ a work area
	@ 1. forward into port A and port B of the next instruction
	ldr	r0, [r7, #0]
	adds	r1, r0, #1		@ port A
	ldr	r0, [r7, #4]
	adds	r2, r1, r0		@ port B
	ldr	r0, [r7, #8]
	cmp	r0, r1			@ compare, flags
	ldr	r0, [r7, #12]
	mvns	r3, r0			@ logic op through the shifter on port B
	ldr	r0, [r7, #16]
	lsls	r4, r0, #3		@ F1: port B, shifter
	ldr	r0, [r7, #20]
	rors	r4, r0			@ F4 register shift: amount on port B (rs_amt)
	SIG	r1
	SIG	r2
	SIG	r3
	SIG	r4
	@ 2. the next instruction writes another register: the data waits in lb
	ldr	r0, [r7, #24]
	movs	r1, #5			@ writes r1 (lb holds r0)
	adds	r2, r0, r1		@ reads r0 from lb, r1 from the bypass
	ldr	r0, [r7, #28]
	movs	r1, #6
	movs	r2, #7			@ lb still holds r0
	adds	r3, r0, r2
	ldr	r0, [r7, #32]
	movs	r1, #8
	movs	r0, #9			@ a younger write of r0: lb is dropped
	adds	r3, r0, r1		@ must read 9
	ldr	r0, [r7, #36]
	adds	r0, r0, #1		@ reads the arriving r0 and writes r0 (same register)
	adds	r1, r0, #0
	SIG	r2
	SIG	r3
	SIG	r1
	@ 3. address base and store data
	ldr	r0, =DATA + 0x40
	str	r0, [r6, #0]
	ldr	r1, [r6, #0]		@ r1 = DATA + 0x40
	ldr	r2, [r1, #4]		@ base forwarded
	ldr	r3, [r7, #44]
	str	r3, [r6, #4]		@ store data forwarded (one-clock store)
	ldr	r3, [r7, #48]
	movs	r0, #24
	ldr	r3, [r7, #52]
	str	r3, [r6, r0]		@ two-clock store (register offset): data in W
	ldr	r4, [r7, #52]
	strb	r4, [r6, #9]
	ldr	r4, [r7, #56]
	strh	r4, [r6, #10]
	ldr	r5, [r6, #4]
	SIG	r2
	SIG	r5
	@ 4. load after load, and chains
	ldr	r0, [r7, #0]
	ldr	r1, [r7, #4]
	ldr	r2, [r7, #8]
	adds	r3, r0, r1
	adds	r3, r3, r2
	ldr	r0, [r6, #0]		@ DATA + 0x40
	ldr	r0, [r0, #0]		@ into its own base
	movs	r2, #8
	ldr	r1, [r7, r2]		@ [Rb, Ro]
	adds	r3, r3, r1
	SIG	r3
	SIG	r0
	@ 5. byte and halfword loads, every sign
	ldrb	r0, [r7, #1]
	adds	r1, r0, #0
	movs	r2, #6
	ldrsb	r0, [r7, r2]
	subs	r1, r1, r0
	ldrh	r0, [r7, #2]
	adds	r1, r1, r0
	movs	r2, #3
	ldrsh	r0, [r7, r2]		@ odd LDRSH: the sign-extended byte
	adds	r1, r1, r0
	ldrh	r0, [r7, r2]		@ odd LDRH: rotated
	eors	r1, r0
	SIG	r1
	@ 6. multiply, branch and jump on loaded data
	ldr	r0, [r7, #4]
	muls	r0, r1, r0		@ Thumb MUL: Rd = Rm (port A and B)
	SIG	r0
	ldr	r0, [r7, #0]
	cmp	r0, #0
	bne	1f
	movs	r1, #1
1:	ldr	r0, =2f + 1
	str	r0, [r6, #12]
	ldr	r1, [r6, #12]
	bx	r1			@ BX on the arriving value
	nop
2:	ldr	r0, =3f + 1
	str	r0, [r6, #16]
	ldr	r1, [r6, #16]
	mov	pc, r1			@ MOV pc on the arriving value
	nop
	.balign 4
3:	ldr	r0, [r6, #0]
	mov	r8, r0			@ F5 hi-register move from the arriving value
	add	r8, r0			@ F5 add
	mov	r1, r8
	SIG	r1
	@ 7. SP-relative, ADD SP and PUSH/POP after a load
	sub	sp, #16
	ldr	r0, [r7, #8]
	str	r0, [sp, #4]
	ldr	r1, [sp, #4]
	add	sp, #8			@ writes SP: lb holds r1
	adds	r2, r1, #0
	ldr	r0, [r7, #12]
	push	{r0, r1}		@ STM data of the arriving register
	ldr	r3, [r7, #16]
	adds	r4, r4, #1		@ lb holds r3
	push	{r3}			@ lb drains in PUSH's first clock
	pop	{r0, r1, r2}		@ L3: r2 arrives with the next instruction
	adds	r3, r2, r1
	ldr	r4, [r7, #20]
	push	{r4}
	pop	{r4}
	adds	r4, r4, #1		@ L3 then write of the same register
	add	sp, #8
	SIG	r3
	SIG	r4
	@ 8. LDMIA with write-back, the base in the list, and a use of the last register
	ldr	r0, =DATA + 0x20
	ldmia	r0!, {r1, r2}
	adds	r3, r2, r0
	ldr	r0, =DATA + 0x20
	.hword	0xC801			@ LDMIA r0!, {r0}: the base alone in the list
	adds	r3, r3, r0
	ldr	r1, =DATA + 0x24
	.hword	0xC906			@ LDMIA r1!, {r1, r2}: the base first
	adds	r3, r3, r2
	adds	r3, r3, r1
	ldr	r2, =DATA + 0x28
	.hword	0xCA06			@ LDMIA r2!, {r1, r2}: the base last
	adds	r3, r3, r2
	SIG	r3
	@ 9. loads from the assets (beyond the window: two clocks, +await delays them) and ROM
	ldr	r5, =ASSET
	ldr	r0, [r5, #0]
	adds	r1, r0, #0
	ldrb	r0, [r5, #7]
	adds	r1, r1, r0
	ldr	r0, [r5, #8]
	movs	r2, #1			@ asset load followed by a write
	adds	r1, r1, r0
	ldr	r0, rtab
	adds	r1, r1, r0
	SIG	r1
	@ 10. a load followed by a BL (the prefix writes LR) and the peripheral page
	ldr	r0, [r7, #0]
	bl	leaf
	adds	r1, r0, #0
	SIG	r1
	ldr	r5, =MMIO
	ldr	r0, [r5, #0]		@ IDENT: two clocks (io_guess)
	adds	r1, r0, #0
	SIG	r1
	END
leaf:	adds	r0, r0, #3
	bx	lr
	.balign 4
rtab:	.word	0x89abcdef
	POOL
