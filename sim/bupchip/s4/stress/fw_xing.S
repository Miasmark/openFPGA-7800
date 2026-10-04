@ The wrapper's crossings under stress (run_xing.sh, tb_xing.sv): loaded as
@ the firmware slot's bupchip.bin, it enables PCM with watermark 0, then
@ loops: pop the $8007 command FIFO; for each command k = 1, 2, ... load the
@ asset byte at offset (k - 1) x 37 mod 4,096 (through the cache: misses,
@ prefetches and late hits) and push the frame
@   [31:24] the command byte  [23:16] the asset byte  [15:0] k
@ into the PCM FIFO, mostly an empty one (the bench sends about one command
@ per 48 kHz tick), so pushes land at every phase of the pop. Every command
@ must come back once, in order, on clk_sys.
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi
	.equ	MMIO, 0xE0009000
	.equ	ASSETS, 0x02000000
	.section .vectors, "ax"
	.global	_start
_start:
	ldr	r1, =MMIO
	mov	r0, #1			@ PCM enable, watermark 0
	str	r0, [r1, #0x18]
	ldr	r7, =ASSETS
	mov	r2, #1			@ k
	mov	r6, #0			@ asset offset
1:	ldr	r0, [r1, #0x04]		@ CMD_POP: bit 8 valid, [7:0] the byte
	tst	r0, #0x100
	beq	1b
	ldrb	r3, [r7, r6]
	and	r0, r0, #0xFF
	orr	r4, r2, r3, lsl #16
	orr	r4, r4, r0, lsl #24
	str	r4, [r1, #0x10]		@ push
	add	r2, r2, #1
	add	r6, r6, #37
	bic	r6, r6, #0xF000		@ mod 4,096
	b	1b
	.ltorg
