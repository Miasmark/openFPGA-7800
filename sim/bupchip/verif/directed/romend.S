@ Running off the end of the ROM: the last word (0x3FFC) is an ordinary
@ instruction, and the next fetch, at 0x4000, is outside the ROM window.
@ MiSTer aborts it (bupchip_memory.sv: dec_rom is mem_addr < 16 KiB), so
@ the core must halt (FETCH, docs/BUPCHIP_CORE.md: exact or halt) and not
@ wrap to 0. run.sh runs this on tb_s1.sv only and expects halt code 4.
@ The end marker after the wrap would only be reached by a core that
@ wrapped (r5 counts the passes).
@ SPDX-License-Identifier: MIT
	.syntax unified
	.arm
	.cpu arm7tdmi
	.section .vectors, "ax"
	.global _start
_start:
	b	reset
	.rept 7
	b	.
	.endr
reset:
	cmp	r5, #0				@ second pass: we wrapped to 0
	bne	wrapped
	mov	r5, #1
	ldr	r0, =0x3ff8
	bx	r0
wrapped:
	ldr	r1, =0xE0009000
	mov	r0, #0xaa
	str	r0, [r1, #0x1c]
	b	.
	.ltorg
	.org	0x3ff8
	mov	r1, r1
expect_halt:
	mov	r2, r2				@ 0x3FFC, the last ROM word
