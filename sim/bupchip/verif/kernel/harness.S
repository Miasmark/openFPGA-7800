@ Mixer harness: runs CoreTone's own voice mixer (bupchip.hex 0xa04-0xd4c,
@ 93% of Misery_F's working instructions) on 16 fabricated looping voices,
@ with no game assets and no CMUS decoding. 24 batches of 200 frames, pushed
@ to the PCM FIFO the way main does, then a FAULT write of 0xAA as the end
@ marker. make_kernel.py builds the image: bupchip.hex with word 0 patched to
@ "b 0x2000" and this code at 0x2000, plus 4 KiB of samples in the asset
@ window. run_kernel.sh runs it.
@ Voice record (28 bytes, as 0xa04 reads it): +0 mode (1 one-shot, 2 loop),
@ +4 sample pointer (s8 PCM), +8 u16 length, +10 s8 volume, +11/+12 s8 pan,
@ +16 u32 position 16.16, +20 s32 step 16.16, +24 s16 loop start, +26 s16 loop end.
	.syntax unified
	.arm
	.cpu arm7tdmi
	.equ	MIXER,	0xa04
	.equ	MMIO,	0xE0009000
	.equ	VOICES,	0x40003000		@ above the firmware's BSS (ends 0x40002080)
	.equ	BUF,	0x40003400		@ 200 frames x {s16 L, s16 R}
	.equ	NVOICE,	16
	.equ	NBATCH,	24			@ 24 x 200 frames = 100 ms of audio

	.section .text
	.global	_start
_start:
	mrs	r0, cpsr			@ the firmware's exact sequence (0x20-0x2c)
	bic	r0, r0, #31
	orr	r0, r0, #0xd3
	msr	cpsr_c, r0
	ldr	sp, =0x40003f00
	@ the firmware's own start-up: .data copy and BSS clear (0x30-0x64)
	ldr	r0, =0x1e3c
	ldr	r1, =0x40000000
	ldr	r2, =0x40000054
1:	cmp	r1, r2
	ldrcc	r3, [r0], #4
	strcc	r3, [r1], #4
	bcc	1b
	ldr	r0, =0x40000058
	ldr	r1, =0x40002080
	mov	r2, #0
2:	cmp	r0, r1
	strcc	r2, [r0], #4
	bcc	2b
	@ PCM on, watermark 3896, as main does at 0x120
	ldr	r5, =MMIO
	ldr	r0, =0x0f380003
	str	r0, [r5, #0x18]

	@ build NVOICE looping voices from the table below
	ldr	r0, =VOICES
	adr	r1, vtab
	mov	r2, #0
3:	ldmia	r1!, {r3, r4, r6, r7, r8, r9, r10}	@ 7 words = 28 bytes
	stmia	r0!, {r3, r4, r6, r7, r8, r9, r10}
	add	r2, r2, #1
	cmp	r2, #NVOICE
	bne	3b

	mov	r9, #NBATCH
batch:
	ldr	r4, =VOICES
	mov	r8, #1				@ first voice overwrites, the rest accumulate
	mov	r7, #0
4:	mov	r0, r4
	ldr	r1, =BUF
	mov	r2, r8
	ldr	r3, [r4]
	cmp	r3, #0
	beq	5f
	bl	MIXER
	mov	r8, #0
5:	add	r4, r4, #28
	add	r7, r7, #1
	cmp	r7, #NVOICE
	bne	4b
	@ push the 200 frames the way main does (0x1ac-0x1cc)
	ldr	r4, =BUF
	mov	r0, #0
6:	add	r1, r4, r0
	add	r0, r0, #4
	ldrh	r2, [r1, #2]
	ldrh	r1, [r1]
	cmp	r0, #800
	orr	r1, r1, r2, lsl #16
	str	r1, [r5, #0x10]
	bne	6b
	subs	r9, r9, #1
	bne	batch

	mov	r0, #0xaa			@ end marker for the testbench
	str	r0, [r5, #0x1c]
	b	.

	.ltorg
	.align	2
	@ mode, sample pointer, {u16 len, s8 vol, s8 panL}, {s8 panR, pad...}, pos, step, {loop start, loop end}
	.macro	VOICE n, step, vol
	.word	2, 0x02000000 + ((\n & 3) << 10)
	.hword	1000
	.byte	\vol, 0x60
	.word	0x70
	.word	(\n * 37) << 16
	.word	\step
	.hword	16, 1000
	.endm
vtab:
	VOICE	0,  0x00010000, 0x40
	VOICE	1,  0x00008000, 0x30
	VOICE	2,  0x00011234, 0x50
	VOICE	3,  0x0000c000, 0x20
	VOICE	4,  0x00018000, 0x40
	VOICE	5,  0x00007000, 0x7f
	VOICE	6,  0x00013333, 0x10
	VOICE	7,  0x0000e000, 0x40
	VOICE	8,  0x00020000, 0x30
	VOICE	9,  0x00009abc, 0x60
	VOICE	10, 0x00012000, 0x40
	VOICE	11, 0x0000f000, 0x40
	VOICE	12, 0x00016000, 0x20
	VOICE	13, 0x0000a000, 0x50
	VOICE	14, 0x00010800, 0x40
	VOICE	15, 0x0001c000, 0x40
