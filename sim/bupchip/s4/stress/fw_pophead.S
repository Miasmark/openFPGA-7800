@ The PCM FIFO's head race through the whole step 4 wrapper (run_pophead.sh):
@ loaded as the firmware slot's bupchip.bin, it enables PCM with an empty
@ FIFO, then N times waits for the FIFO to be empty (the 48 kHz pop has
@ drained it), waits 2 x d clocks more, d = 0, 1, ... 299 and round again,
@ and pushes one frame, the count 1, 2, ... N. The pushes so land at every
@ phase of the pop tick, the clock straight before a tick included: the
@ peripheral raises pcm_available in the clock after a push into an empty
@ FIFO, one clock before its M10K presents the frame, and the wrapper's tick
@ must wait that clock. Every count must come out once, in order.
@ With FAULTAT = M it also writes FAULT (0x1C, code 0x5A) straight after
@ pushing frame M: the peripheral mutes, and every frame ticked from then on
@ must come out 0, while the pushes go on.
@   N        frames to push
@   FAULTAT  optional: the frame after whose push FAULT is written
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi
	.equ	MMIO, 0xE0009000
	.section .vectors, "ax"
	.global	_start
_start:
	ldr	r1, =MMIO
	mov	r0, #1			@ PCM enable, watermark 0
	str	r0, [r1, #0x18]
	mov	r2, #1			@ the next frame
	mov	r3, #0			@ d
	ldr	r5, =N
1:	ldr	r0, [r1, #0x14]		@ PCM status: bit 16 empty
	tst	r0, #0x10000
	beq	1b
	movs	r4, r3
2:	subs	r4, r4, #1		@ 2 clocks per d
	bpl	2b
	str	r2, [r1, #0x10]		@ push
.ifdef FAULTAT
	ldr	r6, =FAULTAT
	cmp	r2, r6
	moveq	r0, #0x5A
	streq	r0, [r1, #0x1C]		@ FAULT: muted from here on
.endif
	add	r2, r2, #1
	add	r3, r3, #1
	cmp	r3, #300
	movge	r3, #0
	cmp	r2, r5
	ble	1b
	b	.
	.ltorg
